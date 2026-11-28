require "test_helper"

class TrafficTest < ActionDispatch::IntegrationTest
  setup do
    @app = App.create!(project: projects(:infra), service: "web", destination: "production", config_path: "deploy/web.production.yml", kind: "rails")
    @web_1, @web_2 = server_named("web-1.example.com"), server_named("web-2.example.com")
    place(@web_1, WEB, app: @app, version: "1a2b3c4d5e6f7a8b", name: "web-web-production-1a2b3c4d5e6f7a8b")
    place(@web_2, WORKER, app: @app)
    @proxy_1 = place(@web_1, "c" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
    @proxy_2 = place(@web_2, "d" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
    sign_in_as users(:ada)
  end

  test "an app's traffic reads kamal-proxy on each of its servers, without writing to Activity" do
    assert_no_difference -> { Event.count } do
      get app_traffic_path(@app)
    end

    assert_response :success
    channel = JSON.parse(css_select(".logs").first["data-logs-channel-value"])
    assert_equal({ "channel" => "TrafficChannel", "app_id" => @app.id }, channel.except("grant"))
    assert LiveGrant.granted?(channel["grant"], users(:ada), "traffic", @app.id)
    assert_select ".logs__chip", text: "web-1"
    assert_select ".logs__chip", text: "web-2"
    targets = JSON.parse(css_select(".logs").first["data-logs-targets-value"])
    assert_equal "web-web-production-1a2b3c4d5e6f", targets[WEB.first(12)]
  end

  test "the fleet's traffic reads kamal-proxy on every server" do
    elsewhere = server_named("db-1.example.com")
    place(elsewhere, "e" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)

    get traffic_path

    assert_response :success
    channel = JSON.parse(css_select(".logs").first["data-logs-channel-value"])
    assert_equal({ "channel" => "TrafficChannel", "fleet" => true }, channel.except("grant"))
    assert LiveGrant.granted?(channel["grant"], users(:ada), "traffic", LiveTraffic::FLEET)
    assert_select ".page-header__meta", text: /on 3 servers/
    %w[ web-1 web-2 db-1 ].each { assert_select ".logs__chip", text: it }
    assert_select "#sidebar a[aria-current=page]", text: "Traffic"
  end

  test "the fleet's traffic says when it reads only the first servers" do
    (LiveTraffic::MAX_PROXIES - 1).times do |index|
      place(server_named("edge-#{index}.example.com"), format("%064x", index), name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
    end

    get traffic_path

    assert_select ".page-header__meta", text: /the first #{LiveTraffic::MAX_PROXIES} of #{LiveTraffic::MAX_PROXIES + 1} servers/
  end

  test "a fleet with no kamal-proxy says so" do
    Placement.where(kind: "proxy").delete_all

    get traffic_path

    assert_select ".logs", count: 0
    assert_select ".empty__title", text: "No kamal-proxy reported"
  end

  test "an app whose servers report no kamal-proxy says so" do
    Placement.where(kind: "proxy").delete_all

    get app_traffic_path(@app)

    assert_select ".logs", count: 0
    assert_select ".empty__title", text: /No kamal-proxy reported/
  end
end
