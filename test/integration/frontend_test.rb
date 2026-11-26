require "test_helper"

class FrontendTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
    sign_in_as users(:viewer)
  end

  test "the board's links stay on Meridian whatever the query string says" do
    get "/?host=evil.example&protocol=https&script_name=//evil.example&state=drifted"
    assert_response :success

    hrefs = css_select(".chips a, nav.segmented a, .pagination a").map { it["href"] }
    assert_not_empty hrefs
    assert hrefs.all? { it.start_with?("/") && !it.start_with?("//") }, hrefs.inspect
    assert_includes hrefs, "/?host=evil.example&protocol=https&script_name=%2F%2Fevil.example#everything", "All drops the state filter"
  end

  test "routing words in the board's query string don't break it" do
    get "/?controller=nope&action=nope"
    assert_response :success
  end

  test "the activity page's links stay on Meridian whatever the query string says" do
    51.times { Event.record("app.deploy", actor: nil, summary: "Deployed") }

    get "/events?host=evil.example&controller=nope"
    assert_response :success
    assert_equal [ "/events?controller=nope&host=evil.example&page=2" ], css_select(".pagination a").map { it["href"] }
  end
end
