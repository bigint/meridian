require "test_helper"

class TrafficTest < ActionDispatch::IntegrationTest
  setup do
    @app = App.create!(project: projects(:infra), service: "web", destination: "production", config_path: "deploy/web.production.yml", kind: "rails")
    @web_1, @web_2 = server_named("web-1.example.com"), server_named("web-2.example.com")
    place(@web_1, WEB, app: @app, version: "1a2b3c4d5e6f7a8b", name: "web-web-production-1a2b3c4d5e6f7a8b")
    place(@web_2, WORKER, app: @app)
    @proxy_1 = place(@web_1, "c" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
    @proxy_2 = place(@web_2, "d" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
  end

  test "a deployer opens an app's traffic: kamal-proxy on each of its servers, and it is recorded" do
    sign_in_as users(:deployer)

    assert_difference -> { Event.where(action: "traffic.viewed").count }, 1 do
      get app_traffic_path(@app)
    end

    assert_response :success
    channel = JSON.parse(css_select(".logs").first["data-logs-channel-value"])
    assert_equal({ "channel" => "TrafficChannel", "app_id" => @app.id }, channel.except("grant"))
    assert LiveLogs.granted?(channel["grant"], users(:deployer), "traffic", @app.id)
    assert_select ".logs__chip", text: "web-1"
    assert_select ".logs__chip", text: "web-2"
    targets = JSON.parse(css_select(".logs").first["data-logs-targets-value"])
    assert_equal "web-web-production-1a2b3c4d5e6f", targets[WEB.first(12)]
    assert_equal "Viewed the traffic of web · production (kamal-proxy on 2 servers)", Event.find_by!(action: "traffic.viewed").summary
  end

  test "an app whose servers report no kamal-proxy says so" do
    Placement.where(kind: "proxy").delete_all
    sign_in_as users(:deployer)

    get app_traffic_path(@app)

    assert_select ".logs", count: 0
    assert_select ".empty__title", text: /No kamal-proxy reported/
  end

  test "the app page links to its traffic, for deployers only" do
    sign_in_as users(:deployer)
    get app_path(@app)
    assert_select ".page-header a[href=?]", app_traffic_path(@app), text: "Traffic"

    sign_in_as users(:viewer)
    get app_path(@app)
    assert_select "a[href=?]", app_traffic_path(@app), count: 0
    get app_traffic_path(@app)
    assert_redirected_to root_path
  end
end
