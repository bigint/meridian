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

    assert_select "table.grid tbody th", text: "web · production"
    assert_select "table.grid thead th a[title=?]", "web-1.example.com", text: "web-1"
    assert_select "table.grid td.cell .state", count: 7
  end

  test "board filters live in the URL" do
    get root_path(app: "blog")
    assert_select "table.grid tbody th", count: 1
    assert_select "table.grid tbody th", text: "blog"
  end

  test "servers × apps toggle" do
    get root_path(view: "servers")
    assert_select "table.grid tbody th", text: "web-1.example.com"
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
    assert_select ".error-list code", text: "deploy/broken.yml:6"
  end
end
