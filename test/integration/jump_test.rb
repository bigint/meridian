require "test_helper"

class JumpTest < ActionDispatch::IntegrationTest
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
    sign_in_as users(:viewer)
  end

  test "type to go finds apps, servers and projects, best match first" do
    get jump_path(q: "web")

    names = css_select("#jump_results a").map { it.css("span.kind").text + ": " + it.text.sub(it.css("span.kind").text, "").squish }
    assert_equal "App: web · staging", names.first, "names starting with the query come first, shortest first"
    assert_includes names, "App: web · production"
    assert_includes names, "Server: web-1.example.com"
    assert_operator names.size, :<=, JumpsController::LIMIT
  end

  test "says so when nothing matches" do
    get jump_path(q: "zzz")
    assert_select "#jump_results", text: /Nothing called “zzz”/
  end

  test "every page carries the search box and the main places" do
    get root_path
    assert_select "#topbar form[action=?] input[type=search][name=q]", jump_path
    assert_select "#sidebar nav[aria-label=Main] a", 6
    assert_select "#sidebar nav[aria-label=Main] a[aria-current=page]", text: /Board/
    assert_select "#sidebar nav a", text: /Map/
    assert_select "#sidebar nav a", text: /Settings/, count: 0, message: "viewers don't see admin places"
    assert_select "[data-controller~=shortcuts]", 0
  end
end
