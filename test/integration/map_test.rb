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
    assert_select ".world__links path title", text: /api/
    assert_select "table tbody th", 2
    assert_select ".world__flows", 0, "no flows until Meridian's location is set"
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
