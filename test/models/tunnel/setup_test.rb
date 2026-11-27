require "test_helper"

class Tunnel::SetupTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    @a, @b = %w[ a b ].map { Server.create!(name: "#{it}.example.com", hostname: "#{it}.example.com", last_seen_at: 1.second.ago) }
    @shop = make_app("shop", hostnames: [ "shop.example.com" ], on: [ @a, @b ])
    @blog = make_app("blog", hostnames: [ "blog.example.com" ], on: [ @a ])
  end

  test "generates an accessories-only edge config that Kamal accepts, one connector per server" do
    setup = Tunnel::Setup.for(@project, hosts: [ "a.example.com", "b.example.com" ])

    result = KamalConfig.parse({ setup.config_path => setup.edge_config }, [ { "path" => setup.config_path, "destination" => nil } ]).sole

    assert_nil result["error"]
    assert_equal "deploy/edge.yml", setup.config_path
    assert_equal "accessories", result.dig("labels", "meridian.kind")
    assert_equal [ [ "cloudflared-a", [ "a.example.com" ] ], [ "cloudflared-b", [ "b.example.com" ] ] ], result["accessories"].map { [ it["name"], it["hosts"] ] }
    assert_equal [ "CLOUDFLARE_TUNNEL_TOKEN" ], result["secrets"]
    assert_equal "kamal accessory boot all -c deploy/edge.yml", setup.boot_command
  end

  test "leaves out picks that aren't host names" do
    setup = Tunnel::Setup.for(@project, hosts: [ "a.example.com", "b<%= `id` %>", "c\n  evil: 1" ])

    assert_equal [ "a.example.com" ], setup.hosts
    assert_no_match(/<%|evil/, setup.edge_config)
  end

  test "names every connector apart, for servers known by IP or by clashing short names" do
    { %w[ 10.0.0.1 10.0.0.2 10.0.0.3 ] => %w[ cloudflared-10-0-0-1 cloudflared-10-0-0-2 cloudflared-10-0-0-3 ],
      %w[ web.sgp.example.com web.fra.example.com db.example.com ] => %w[ cloudflared-web-sgp-example-com cloudflared-web-fra-example-com cloudflared-db ] }.each do |hosts, names|
      setup = Tunnel::Setup.for(@project, hosts: hosts)
      result = KamalConfig.parse({ setup.config_path => setup.edge_config }, [ { "path" => setup.config_path, "destination" => nil } ]).sole

      assert_equal names.zip(hosts.map { [ it ] }), result["accessories"].map { [ it["name"], it["hosts"] ] }
    end
  end

  test "says which apps the picked servers can serve" do
    both = Tunnel::Setup.for(@project, hosts: [ "a.example.com", "b.example.com" ])
    assert_equal [ @shop ], both.served.map(&:app)
    assert_equal [ [ @blog, [ "b.example.com" ] ] ], both.gaps.map { [ it.app, it.missing ] }

    one = Tunnel::Setup.for(@project, hosts: [ "a.example.com" ])
    assert_equal [ @blog, @shop ], one.served.map(&:app)
  end

  test "picks every server that runs an app until told otherwise" do
    assert_equal [ "a.example.com", "b.example.com" ], Tunnel::Setup.for(@project).hosts
  end

  test "ticks off what Meridian can see" do
    setup = Tunnel::Setup.for(@project)
    assert_not setup.token_saved?
    assert_not setup.in_config?

    @project.secret_names.create!(name: "CLOUDFLARE_TUNNEL_TOKEN", last_set_at: 1.minute.ago)
    make_app("edge", kind: App::ACCESSORIES, accessories: [ { "name" => "cloudflared-a", "service" => "edge-cloudflared-a", "image" => "cloudflare/cloudflared:2026.11.2", "hosts" => [ "a.example.com" ], "secrets" => [ "CLOUDFLARE_TUNNEL_TOKEN" ] } ])
    @a.placements.create!(container_id: "c1", name: "edge-cloudflared-a", kind: "accessory", service: "edge-cloudflared-a", state: "running", observed_at: Time.current)

    setup = Tunnel::Setup.for(@project)
    assert setup.token_saved?
    assert setup.in_config?
    assert setup.running?
    assert_equal [ "a.example.com" ], setup.hosts
  end

  private
    def make_app(service, kind: "other", hostnames: [], on: [], accessories: [])
      app = @project.apps.create!(service: service, kind: kind, config_path: "deploy/#{service}.yml", hostnames: hostnames, accessories: accessories)
      on.each { app.assignments.create!(server: it, role: "web") }
      app
    end
end
