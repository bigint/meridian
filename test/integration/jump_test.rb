require "test_helper"

class JumpTest < ActionDispatch::IntegrationTest
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
    sign_in_as users(:ada)
  end

  test "type to go finds apps, servers and projects, best match first" do
    get jump_path(q: "web")

    names = css_select("#jump_results a").map { it.css("span.kind").text + ": " + it.text.sub(it.css("span.kind").text, "").squish }
    assert_equal "App: web · staging", names.first, "names starting with the query come first, shortest first"
    assert_includes names, "App: web · production"
    assert_includes names, "Server: web-1.example.com"
    assert_operator names.size, :<=, JumpsController::LIMIT
  end

  test "underscores and percent signs are matched as themselves" do
    app = projects(:infra).apps.create!(service: "my_app", config_path: "deploy/my_app.yml")
    projects(:infra).apps.create!(service: "myxapp", config_path: "deploy/myxapp.yml")
    Server.create!(name: "db_1", hostname: "db_1")

    get jump_path(q: "my_app")
    assert_equal [ "my_app" ], css_select("#jump_results a span.truncate").map(&:text)

    get apps_path(q: "my_app")
    assert_select "table tbody th a", text: "my_app"
    assert_select "table tbody th a", text: "myxapp", count: 0

    get servers_path(q: "db_1")
    assert_select "table tbody th a", text: "db_1"

    assert_equal [ app ], Board.new(app: "my_app").apps.values, "the board's app filter"

    Event.record("agent_token.created", summary: "Created a token")
    get events_path(action_name: "agent_token")
    assert_select ".row__title", text: "Created a token"
  end

  test "the best match survives the limit, however many names sort before it" do
    JumpsController::LIMIT.times { |i| Server.create!(name: "a#{i}-db-1.example.com", hostname: "a#{i}-db-1.example.com") }
    Server.create!(name: "db-1", hostname: "db-1")

    get jump_path(q: "db-1")
    assert_equal "db-1", css_select("#jump_results a span.truncate").first.text
  end

  test "says so when nothing matches" do
    get jump_path(q: "zzz")
    assert_select "#jump_results", text: /Nothing called “zzz”/
  end

  test "every page carries the search box and the main places" do
    get root_path
    assert_select "#topbar form[action=?] input[type=search][name=q]", jump_path
    assert_select "#sidebar nav[aria-label=Main] a", 5
    assert_select "#sidebar nav[aria-label=Main] a[aria-current=page]", text: /Board/
    assert_select "#sidebar nav[aria-label=Manage] a", text: /Secrets/
    assert_select "#sidebar nav[aria-label=System] a", text: /Settings/
    assert_select "[data-controller~=shortcuts]", 0
  end
end
