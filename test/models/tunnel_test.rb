require "test_helper"

class TunnelTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    @counter = 0
  end

  test "connectors that read the same token are one tunnel, named after their config" do
    edge = make_app("edge", kind: App::ACCESSORIES, accessories: [ connector("cloudflared-a", "a.example.com"), connector("cloudflared-b", "b.example.com") ])

    tunnel = Tunnel.all.sole
    assert_equal "edge", tunnel.name
    assert_equal [ edge ], tunnel.configs
    assert_equal %w[ a.example.com b.example.com ], tunnel.connector_hosts
    assert_equal "CLOUDFLARE_TUNNEL_TOKEN", tunnel.secret_name
  end

  test "different tokens are different tunnels" do
    make_app("edge", accessories: [ connector("cloudflared-a", "a.example.com") ])
    make_app("other", accessories: [ connector("cloudflared-b", "b.example.com", secret: "OTHER_TUNNEL_TOKEN") ])

    assert_equal %w[ CLOUDFLARE_TUNNEL_TOKEN OTHER_TUNNEL_TOKEN ], Tunnel.all.map(&:secret_name).sort
  end

  test "an accessory synced before images were reported is a connector by the name cloudflared" do
    make_app("shop", accessories: [ { "name" => "cloudflared", "hosts" => [ "a.example.com" ] }, { "name" => "db", "hosts" => [ "a.example.com" ] } ])

    assert_equal [ "cloudflared" ], Tunnel.all.sole.connectors.map(&:name)
  end

  test "apps without a connector are no tunnel" do
    make_app("blog", accessories: [ { "name" => "db", "image" => "postgres:17", "service" => "blog-db", "hosts" => [ "a.example.com" ] } ])

    assert_empty Tunnel.all
  end

  test "a connector is running, stopped, missing or unknown" do
    running, stopped, missing, quiet = %w[ a b c d ].map { server("#{it}.example.com", last_seen_at: 5.seconds.ago) }
    quiet.update!(last_seen_at: 1.hour.ago)
    make_app("edge", accessories: %w[ a b c d e ].map { connector("cloudflared-#{it}", "#{it}.example.com") })
    place(running, "edge-cloudflared-a", "running")
    place(stopped, "edge-cloudflared-b", "exited")
    place(quiet, "edge-cloudflared-d", "running")

    states = Tunnel.all.sole.connectors.to_h { [ it.host, it.state ] }

    assert_equal({ "a.example.com" => :running, "b.example.com" => :stopped, "c.example.com" => :missing, "d.example.com" => :unknown, "e.example.com" => :unknown }, states,
      "a quiet agent's last report says nothing about now")
  end

  test "a missing connector has the command that starts it" do
    server("a.example.com", last_seen_at: 1.second.ago)
    make_app("edge", accessories: [ connector("cloudflared-a", "a.example.com") ])

    tunnel = Tunnel.all.sole
    assert_equal "kamal accessory boot cloudflared-a -c deploy/edge.yml", tunnel.boot_command(tunnel.missing.sole)
  end

  test "an app is safe to serve only if it runs on every connector's server" do
    a, b = server("a.example.com", last_seen_at: 1.second.ago), server("b.example.com", last_seen_at: 1.second.ago)
    make_app("edge", kind: App::ACCESSORIES, accessories: [ connector("cloudflared-a", "a.example.com"), connector("cloudflared-b", "b.example.com") ])
    everywhere = make_app("shop", hostnames: [ "shop.example.com" ], on: [ a, b ])
    partly = make_app("blog", hostnames: [ "blog.example.com" ], on: [ a ])
    make_app("api", hostnames: [ "api.example.com" ], on: [ server("c.example.com", last_seen_at: 1.second.ago) ])
    make_app("worker", on: [ a, b ])

    tunnel = Tunnel.all.sole

    assert_equal [ everywhere ], tunnel.served.map(&:app)
    assert_equal [ [ partly, [ "b.example.com" ] ] ], tunnel.gaps.map { [ it.app, it.missing ] }
    assert_equal [ "api" ], tunnel.elsewhere.map { it.app.service }
  end

  test "a server that runs only an app's workers doesn't serve it" do
    a, b = server("a", last_seen_at: 1.second.ago), server("b", last_seen_at: 1.second.ago)
    make_app("edge", kind: App::ACCESSORIES, accessories: [ connector("cloudflared-a", "a"), connector("cloudflared-b", "b") ])
    shop = @project.apps.create!(service: "shop", config_path: "deploy/shop.yml", hostnames: [ "shop.example.com" ],
      roles: [ { "name" => "web", "hosts" => [ "a" ], "proxy" => true }, { "name" => "job", "hosts" => [ "b" ], "proxy" => false } ])
    shop.assignments.create!(server: a, role: "web")
    shop.assignments.create!(server: b, role: "job")

    assert_equal [ [ shop, [ "b" ] ] ], Tunnel.all.sole.gaps.map { [ it.app, it.missing ] }
  end

  test "only connector trouble needs attention, not an app missing from a server" do
    a = server("a.example.com", last_seen_at: 1.second.ago)
    make_app("edge", accessories: [ connector("cloudflared-a", "a.example.com"), connector("cloudflared-b", "b.example.com") ])
    make_app("blog", hostnames: [ "blog.example.com" ], on: [ a ])
    place(a, "edge-cloudflared-a", "running")
    place(server("b.example.com", last_seen_at: 1.second.ago), "edge-cloudflared-b", "running")

    tunnel = Tunnel.all.sole
    assert tunnel.gaps.any?
    assert_not tunnel.problems?
  end

  test "the token's secret says whether Meridian set it" do
    make_app("edge", accessories: [ connector("cloudflared-a", "a.example.com") ])
    @project.secret_names.create!(name: "CLOUDFLARE_TUNNEL_TOKEN", last_set_at: 1.hour.ago)

    assert Tunnel.all.sole.token_set?
  end

  test "servers are found by hostname or name, never created" do
    server("web-1", hostname: "10.0.0.1", last_seen_at: 1.second.ago)
    make_app("edge", accessories: [ connector("cloudflared-a", "web-1"), connector("cloudflared-b", "nowhere.example.com") ])

    assert_no_difference -> { Server.count } do
      assert_equal [ "web-1", nil ], Tunnel.all.sole.connectors.map { it.server&.name }
    end
  end

  test "queries stay constant however many tunnels there are" do
    make_app("edge", accessories: [ connector("cloudflared-a", "a.example.com") ])
    few = count_queries { Tunnel.all.each(&:coverage) }

    5.times { |i| make_app("edge-#{i}", accessories: [ connector("cloudflared-#{i}", "s#{i}.example.com", secret: "T#{i}_TUNNEL_TOKEN") ]) }

    assert_equal few, count_queries { Tunnel.all.each(&:coverage) }
  end

  private
    def make_app(service, kind: "other", hostnames: [], on: [], accessories: [])
      app = @project.apps.create!(service: service, kind: kind, config_path: "deploy/#{service}.yml", hostnames: hostnames,
        accessories: accessories.map { it.merge("service" => "#{service}-#{it["name"]}") })
      on.each { app.assignments.create!(server: it, role: "web") }
      app
    end

    def connector(name, host, secret: "CLOUDFLARE_TUNNEL_TOKEN")
      { "name" => name, "image" => "cloudflare/cloudflared:2026.11.2", "hosts" => [ host ], "secrets" => [ secret ] }
    end

    def server(name, hostname: name, last_seen_at:)
      Server.create!(name: name, hostname: hostname, last_seen_at: last_seen_at)
    end

    def place(server, service, state)
      server.placements.create!(container_id: "c#{@counter += 1}", name: service, kind: "accessory", service: service, state: state, observed_at: Time.current)
    end

    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
