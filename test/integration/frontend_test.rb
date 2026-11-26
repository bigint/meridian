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

  test "list pages take a repeated parameter as text, not an error" do
    [ "/events?action_name[]=app", "/events?page[]=2", "/apps?q[]=web", "/servers?q[]=web" ].each do |path|
      get path
      assert_response :success, path
    end
  end

  test "a secret set by someone since removed says so" do
    SecretName.create!(project: @project, name: "API_KEY", last_set_at: 1.day.ago, last_set_by: nil)

    get secrets_path

    assert_select "tr", text: /API_KEY.*1 day ago by a removed user/m
  end

  test "search results say which query they answer, as it was typed" do
    get jump_path(q: " blog ")
    assert_select "turbo-frame#jump_results ul.results[data-query=?]", " blog "

    get jump_path(q: "nothing-like-this")
    assert_select "turbo-frame#jump_results p.results__none[data-query=?]", "nothing-like-this"
  end

  test "the too-old-browser page is styled under the CSP it is served with" do
    get root_path, headers: { "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15" }

    assert_response :not_acceptable
    assert_match(/style-src 'self'/, response.headers["Content-Security-Policy"])
    assert_no_match(/<style|style=/, response.body)
    assert_select "link[rel=stylesheet][href='/error-pages.css']"

    get "/error-pages.css"
    assert_response :success
    assert_match(/prefers-color-scheme: dark/, response.body)
  end
end
