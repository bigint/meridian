require "test_helper"

class TunnelsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:viewer) }

  test "lists apps behind a tunnel with each connector's state and the boot command" do
    project = projects(:infra)
    running = Server.create!(name: "a.example.com", hostname: "a.example.com", last_seen_at: 1.second.ago)
    Server.create!(name: "b.example.com", hostname: "b.example.com", last_seen_at: 1.second.ago)
    running.placements.create!(container_id: "c1", name: "shop-cloudflared", kind: "accessory", service: "shop-cloudflared", state: "running", observed_at: Time.current)
    project.apps.create!(service: "shop", destination: "production", config_path: "deploy/shop.yml", hostnames: [ "shop.example.com" ],
      accessories: [ { "name" => "cloudflared", "service" => "shop-cloudflared", "image" => "cloudflare/cloudflared:2026", "hosts" => %w[ a.example.com b.example.com ] } ])

    get tunnels_path

    assert_response :success
    assert_select "tbody th a", text: "shop · production"
    assert_select "tbody td", text: /shop\.example\.com/
    assert_select ".badge", text: "running"
    assert_select ".badge", text: "not started"
    assert_select ".copyable code", text: "kamal accessory boot cloudflared -c deploy/shop.yml -d production"
    assert_select ".page-header__meta", text: /1 app behind a Cloudflare Tunnel. 1 needs attention/
    assert_select "a[href=?]", new_tunnel_path(app: project.apps.find_by!(service: "shop").id), text: "Steps"
  end

  test "spells out the steps for the chosen app, in its own names" do
    app = projects(:infra).apps.create!(service: "occasions", config_path: "deploy/occasions.yml", hostnames: [ "occasions.example.net" ])

    get new_tunnel_path(app: app.id)

    assert_response :success
    assert_select "select[name=app] option[selected]", text: "occasions"
    assert_select ".walk__step", 7
    assert_select ".walk__step--done", 0
    assert_select ".walk__text", text: /Networking → Tunnels/
    assert_select ".copyable code", text: "occasions"
    assert_select ".copyable code", text: "occasions.example.net"
    assert_select ".copyable code", text: "http://kamal-proxy:80"
    assert_select ".copyable code", text: "OCCASIONS_TUNNEL_TOKEN=$OCCASIONS_TUNNEL_TOKEN"
    assert_select ".code-block code", text: /TUNNEL_TOKEN:OCCASIONS_TUNNEL_TOKEN/
    assert_select ".code-block code", text: "kamal accessory boot cloudflared -c deploy/occasions.yml"
  end

  test "ticks off the steps Meridian can see are done" do
    project = projects(:infra)
    server = Server.create!(name: "a.example.com", hostname: "a.example.com", last_seen_at: 1.second.ago)
    server.placements.create!(container_id: "c1", name: "shop-cloudflared", kind: "accessory", service: "shop-cloudflared", state: "running", observed_at: Time.current)
    app = project.apps.create!(service: "shop", config_path: "deploy/shop.yml", hostnames: [ "shop.example.com" ],
      accessories: [ { "name" => "cloudflared", "service" => "shop-cloudflared", "image" => "cloudflare/cloudflared:2026", "hosts" => [ "a.example.com" ], "secrets" => [ "SHOP_TUNNEL_TOKEN" ] } ])
    project.secret_names.create!(name: "SHOP_TUNNEL_TOKEN", last_set_at: 1.minute.ago)

    get new_tunnel_path(app: app.id)

    assert_select ".walk__step--done .walk__title", text: /Save the token/
    assert_select ".walk__step--done .walk__title", text: /Add the connector/
    assert_select ".walk__step--done .walk__title", text: /Start the connector/
    assert_select ".walk__step--done", 4
    assert_select ".badge", text: "1 of 1 running"
  end

  test "the overview links to the setup" do
    get tunnels_path
    assert_select ".page-header a.btn--primary[href=?]", new_tunnel_path, text: /Set up a tunnel/
  end

  test "says so when no app runs behind a tunnel" do
    get tunnels_path

    assert_response :success
    assert_select ".empty__title", text: "No tunnels yet"
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
end
