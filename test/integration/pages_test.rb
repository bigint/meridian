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

  test "an app page shows its accessories with server and state" do
    server = Server.create!(name: "db-1.example.com", hostname: "db-1.example.com", last_seen_at: 1.second.ago)
    app = projects(:infra).apps.create!(service: "umami", config_path: "deploy/umami.yml",
      accessories: [ { "name" => "db", "service" => "umami-db", "image" => "postgres:17-alpine", "hosts" => [ "db-1.example.com" ] } ])

    get app_path(app)

    assert_select "h2", text: /Accessories/
    assert_select "th", text: "db"
    assert_select "td", text: "postgres:17-alpine"
    assert_select "a[href=?]", server_path(server), text: "db-1.example.com"
    assert_select ".badge", text: "not started"
    assert_select ".copyable code", text: "kamal accessory boot db -c deploy/umami.yml"
  end

  test "an accessories-only config's page offers no deploy" do
    sign_in_as users(:deployer)
    app = @project.apps.find_by!(service: "blog")
    app.update!(kind: App::ACCESSORIES)

    get app_path(app)

    assert_select "form[action=?]", app_deploys_path(app), count: 0
    assert_select "form[action=?]", app_redeploy_path(app), count: 0
    assert_select "code", text: "kamal accessory boot all -c deploy/blog.yml"
  end

  test "an app runs its release everywhere only when no server runs another version too" do
    server = Server.create!(name: "shop-1.example.com", hostname: "shop-1.example.com", last_seen_at: Time.current)
    app = @project.apps.create!(service: "shop", config_path: "deploy/shop.yml", version_path: "deploy/shop.version")
    app.releases.create!(version: "v2", commit_sha: "c" * 40, committed_at: 1.hour.ago)
    app.assignments.create!(server: server, role: "web")
    %w[ v2 v1 ].each { |version| server.placements.create!(app: app, container_id: version, name: "shop-web-#{version}", service: "shop", role: "web", version: version, state: "running", observed_at: Time.current) }

    get app_path(app)
    assert_select "td [data-cell][data-state=drifted]", 1
    assert_select ".page-header", text: /0 of 1 server run v2/
    assert_select ".page-header", text: /everywhere/, count: 0
  end

  test "a server page lists every app on the server, past one board page" do
    server = Server.create!(name: "big-1.example.com", hostname: "big-1.example.com", last_seen_at: Time.current)
    (Board::PER_PAGE + 5).times { |i| @project.apps.create!(service: "app-#{i}", config_path: "deploy/app-#{i}.yml").assignments.create!(server: server, role: "web") }

    get server_path(server)
    assert_select "section table tbody th a[href^='/apps/']", Board::PER_PAGE + 5
  end

  test "the apps page reads every app's newest release in one query" do
    20.times { |i| @project.apps.create!(service: "app-#{i}", config_path: "deploy/app-#{i}.yml").releases.create!(version: "v#{i}", commit_sha: i.to_s * 40, committed_at: 1.hour.ago) }

    queries = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { queries << payload[:sql] if payload[:sql].include?('"releases".*') }, "sql.active_record") { get apps_path }
    assert_select "table tbody code", text: "v19"
    assert_equal 1, queries.size, queries.join("\n")
  end

  test "the board says everything matches Git only when every cell was compared" do
    get root_path
    assert_select "[data-board-grid] [data-cell][data-state=unknown]", minimum: 1
    assert_select ".page-header__meta", text: /compared with Git/

    Server.update_all(last_seen_at: Time.current)
    App.where.not(version_path: nil).find_each do |app|
      app.assignments.each { server_placement(app, it.server, it.role, app.latest_release.version) }
    end
    App.where(version_path: nil).destroy_all
    get root_path
    assert_select "[data-board-grid] [data-cell]:not([data-state=in_sync])", 0
    assert_select ".page-header__meta", text: /all matching Git/
  end

  test "the CSP allows nonced scripts and styles, and nothing inline" do
    get root_path
    policy = response.headers["Content-Security-Policy"]
    assert_match(/script-src 'self' 'nonce-[^']+'/, policy)
    assert_match(/style-src 'self' 'nonce-[^']+'/, policy)
    assert_no_match(/unsafe-inline/, policy)
  end

  private
    def server_placement(app, server, role, version)
      server.placements.create!(app: app, container_id: "#{app.id}-#{role}", name: "#{app.service}-#{role}-#{version}", service: app.service, role: role,
        destination: app.destination, version: version, state: "running", observed_at: Time.current)
    end
end
