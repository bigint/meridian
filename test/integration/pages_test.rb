require "test_helper"

class PagesTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
    sign_in_as users(:viewer)
  end

  test "board shows every app on every server with its latest release" do
    get root_path
    assert_response :success

    assert_select "[data-board-grid] tbody th", text: "web · production"
    assert_select "[data-board-grid] thead th a[data-tooltip=?]", "web-1.example.com", text: "web-1"
    assert_select "[data-board-grid] [data-cell][data-state]", count: 7
  end

  test "the board's side panel inspects an app" do
    app = @project.apps.find_by!(service: "web", destination: "production")

    get root_path(inspect: app.id)
    assert_select "turbo-frame#inspector[target=_top] [data-inspector] h2", text: "web · production"
    assert_select "turbo-frame#inspector li [data-cell]", minimum: 1
    assert_select "[data-board-grid] th a[data-turbo-frame=inspector][href*=?]", "inspect=#{app.id}"
  end

  test "board filters live in the URL" do
    get root_path(app: "blog")
    assert_select "[data-board-grid] tbody th", count: 1
    assert_select "[data-board-grid] tbody th", text: "blog"
  end

  test "servers × apps toggle" do
    get root_path(view: "servers")
    assert_select "[data-board-grid] tbody th a[data-tooltip=?]", "web-1.example.com"
  end

  test "app, server and project pages render" do
    app = @project.apps.find_by!(service: "web", destination: "production")
    get app_path(app)
    assert_response :success
    assert_select "h1", "web · production"

    get server_path(Server.find_by!(name: "web-1.example.com"))
    assert_response :success
    assert_select "section table tbody th", text: "web · production"
    assert_select "section table tbody th", text: "blog"

    get project_path(@project)
    assert_select "[data-config-errors] code", text: "deploy/broken.yml:6"
  end

  test "the CSP allows nonced scripts and styles, and nothing inline" do
    get root_path
    policy = response.headers["Content-Security-Policy"]
    assert_match(/script-src 'self' 'nonce-[^']+'/, policy)
    assert_match(/style-src 'self' 'nonce-[^']+'/, policy)
    assert_no_match(/unsafe-inline/, policy)
  end
end
