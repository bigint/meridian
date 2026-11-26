require "test_helper"

class TunnelsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:viewer)
    @project = projects(:infra)
    @a, @b = %w[ a b ].map { Server.create!(name: "#{it}.example.com", hostname: "#{it}.example.com", last_seen_at: 1.second.ago) }
  end

  test "shows the shared tunnel, its connectors and which apps it can serve" do
    make_app("edge", kind: App::ACCESSORIES, accessories: %w[ a b ].map { connector(it) })
    @a.placements.create!(container_id: "c1", name: "edge-cloudflared-a", kind: "accessory", service: "edge-cloudflared-a", state: "running", observed_at: Time.current)
    make_app("shop", hostnames: [ "shop.example.com" ], on: [ @a, @b ])
    make_app("blog", hostnames: [ "blog.example.com" ], on: [ @a ])

    get tunnels_path

    assert_response :success
    assert_select ".page-header__meta", text: /1 Cloudflare Tunnel. 1 needs attention/
    assert_select ".card__header", text: /edge/
    assert_select ".badge", text: "running"
    assert_select ".badge", text: "not started"
    assert_select ".copyable code", text: "kamal accessory boot cloudflared-b -c deploy/edge.yml"
    assert_select "li", text: /shop.*shop\.example\.com/m
    assert_select ".alert", text: /Don't route blog through this tunnel yet.*b\.example\.com/m
  end

  test "spells out the setup for the picked servers, with the edge config to commit" do
    make_app("shop", hostnames: [ "shop.example.com" ], on: [ @a, @b ])
    make_app("blog", hostnames: [ "blog.example.com" ], on: [ @a ])

    get new_tunnel_path(hosts: [ "a.example.com", "b.example.com" ])

    assert_response :success
    assert_select "input[type=checkbox][name='hosts[]'][checked]", 2
    assert_select ".walk__step", 7
    assert_select ".copyable code", text: "CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TUNNEL_TOKEN"
    assert_select ".code-block__bar", text: /deploy\/edge\.yml/
    assert_select ".code-block code", text: /cloudflared-a:.*host: a\.example\.com.*cloudflared-b:.*host: b\.example\.com/m
    assert_select ".code-block code", text: "kamal accessory boot all -c deploy/edge.yml"
    assert_select ".copyable code", text: "shop.example.com"
    assert_select ".copyable code", { text: "blog.example.com", count: 0 }
    assert_select ".alert", text: /blog isn't on every one of these servers/
  end

  test "picking one server makes every app on it ready to route" do
    make_app("blog", hostnames: [ "blog.example.com" ], on: [ @a ])

    get new_tunnel_path(hosts: [ "a.example.com" ])

    assert_select ".copyable code", text: "blog.example.com"
    assert_select ".alert", count: 0
  end

  test "says so when there is no tunnel" do
    get tunnels_path

    assert_response :success
    assert_select ".empty__title", text: "No tunnels yet"
    assert_select ".page-header a.btn--primary[href=?]", new_tunnel_path, text: /Set up a tunnel/
  end

  test "warns about nested preview hostnames and links admins to settings" do
    Account.current.update!(preview_domain: "preview.example.com", preview_hostnames: "nested")

    get tunnels_path
    assert_select "code", text: "pr-12.shop.preview.example.com"
    assert_select ".alert", text: /two levels below the domain/
    assert_select ".alert a[href=?]", settings_account_path, count: 0

    sign_in_as users(:admin)
    get tunnels_path
    assert_select ".alert a[href=?]", settings_account_path
  end

  test "flat preview hostnames need no warning" do
    Account.current.update!(preview_domain: "preview.example.com", preview_hostnames: "flat")

    get tunnels_path
    assert_select "code", text: "pr-12-shop.preview.example.com"
    assert_select ".alert", count: 0
  end

  test "the sidebar links to the page" do
    get tunnels_path
    assert_select "nav[aria-label=Manage] a[href=?]", tunnels_path, text: "Tunnels"
  end

  private
    def make_app(service, kind: "other", hostnames: [], on: [], accessories: [])
      app = @project.apps.create!(service: service, kind: kind, config_path: "deploy/#{service}.yml", hostnames: hostnames,
        accessories: accessories.map { it.merge("service" => "#{service}-#{it["name"]}") })
      on.each { app.assignments.create!(server: it, role: "web") }
      app
    end

    def connector(server)
      { "name" => "cloudflared-#{server}", "image" => "cloudflare/cloudflared:2026.11.2", "hosts" => [ "#{server}.example.com" ], "secrets" => [ "CLOUDFLARE_TUNNEL_TOKEN" ] }
    end
end
