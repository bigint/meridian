require "test_helper"

class MapTest < ActionDispatch::IntegrationTest
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
    Server.find_by!(name: "web-2.example.com").update!(latitude: 1.35, longitude: 103.82, last_seen_at: Time.current)
    Server.find_by!(name: "api-1.example.com").update!(latitude: 50.11, longitude: 8.68, last_seen_at: Time.current)
  end

  test "the map draws places, links and a table anyone can read" do
    sign_in_as users(:viewer)
    get map_path

    assert_response :success
    assert_select "svg[role=img] use[href*='world'][href$='#land']"
    assert_select ".world__sites a.site", 2
    assert_select ".world__links path[data-tooltip*=api]"
    assert_select "table tbody th", 2
    assert_select ".world__flows", 0, "no flows until Meridian's location is set"
  end

  test "a place opens in the side panel, and the map names only places that need you" do
    sign_in_as users(:viewer)
    singapore = WorldMap.new.sites.find { it.servers.map(&:name) == [ "web-2.example.com" ] }

    get map_path(place: singapore.key)
    assert_select "#place [data-place-inspector] h2", text: singapore.name
    assert_select "#place [data-cell]", minimum: 1
    assert_select ".world__sites a.site.selected[aria-current=true]", 1
    assert_select ".world__sites a.site[href*='place=']", 2
    assert_select "table tbody th a[href*='place=']", 2
    assert_select ".world__labels text", WorldMap.new.named_keys(singapore).size
  end

  test "an app chip shows that app only, not every app whose name contains it" do
    sign_in_as users(:viewer)
    projects(:infra).apps.create!(service: "webhooks", config_path: "deploy/webhooks.yml").assignments.create!(server: Server.find_by!(name: "web-2.example.com"), role: "web")
    projects(:infra).apps.create!(service: "edge", kind: App::ACCESSORIES, config_path: "deploy/edge.yml")

    get map_path
    assert_select ".chips a", text: /edge/, count: 0, message: "accessories-only configs are off the map"
    assert_select ".chips a[href*='service=webhooks']"

    get map_path(service: "web")
    assert_response :success
    assert_equal [ "web" ], WorldMap.new(service: "web").sites.flat_map(&:apps).map(&:service).uniq
    assert_equal %w[ web webhooks ], Board.new(app: "web").apps.values.map(&:service).uniq.sort, "the free-text filter still matches part of a name"
  end

  test "admins place a server by hand" do
    sign_in_as users(:admin)
    server = Server.find_by!(name: "jobs-1.example.com")
    patch server_path(server), params: { server: { latitude: 40.71, longitude: -74.01 } }
    assert_equal [ 40.71, -74.01 ], server.reload.then { [ it.latitude, it.longitude ] }

    sign_in_as users(:viewer)
    patch server_path(server), params: { server: { latitude: 0, longitude: 0 } }
    assert_equal 40.71, server.reload.latitude
  end
end
