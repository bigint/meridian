require "test_helper"

class LogsTest < ActionDispatch::IntegrationTest
  setup do
    project = projects(:infra)
    @app = App.create!(project: project, service: "web", destination: "production", config_path: "deploy/web.production.yml", kind: "rails")
    @web_1, @web_2 = server_named("web-1.example.com"), server_named("web-2.example.com")
    @web = place(@web_1, WEB, app: @app)
    @worker = place(@web_2, WORKER, app: @app, name: "web-web-production-v41", state: "exited")
    @other = place(@web_1, "c" * 64, name: "blog-web-1a2b3c4d")
    sign_in_as users(:ada)
  end

  # Reading logs is not an event: Activity is for changes, not page views.
  test "one container's logs open without writing to Activity" do
    assert_no_difference -> { Event.count } do
      get placement_log_path(@web)
    end

    assert_response :success
    assert_channel users(:ada), { "placement_ids" => [ @web.id ] }, "logs", @web.id
    assert_select ".logs__chip", count: 0
  end

  test "an app's logs merge every server it runs on, running containers first" do
    get app_log_path(@app)

    assert_response :success
    assert_channel users(:ada), { "placement_ids" => [ @web.id, @worker.id ] }, "logs", @web.id, @worker.id
    assert_select ".logs__chip", count: 2
    assert_select ".logs__chip", text: "web-1"
    assert_select ".logs__chip", text: "web-2"
  end

  # Each role is its own current container, so one role per container.
  test "an app's logs stop at the most containers a page follows, running ones kept" do
    LiveLogs::MAX_PLACEMENTS.times { |i| place(@web_1, i.to_s(16).rjust(64, "d"), app: @app, name: "web-job#{i}-production-v42", role: "job#{i}", state: "exited") }

    get app_log_path(@app)

    ids = JSON.parse(css_select(".logs").first["data-logs-channel-value"])["placement_ids"]
    assert_equal LiveLogs::MAX_PLACEMENTS, ids.size
    assert_equal @web.id, ids.first
  end

  test "containers that only share a server are told apart by role" do
    place(@web_1, "e" * 64, app: @app, name: "web-job-production-v42", role: "job")

    get app_log_path(@app)

    assert_select ".logs__chip", text: "web-1 · web"
    assert_select ".logs__chip", text: "web-1 · job"
    assert_select ".logs__chip[data-tooltip=?]", "web-job-production-v42 on web-1.example.com"
  end

  test "an app with no containers says so and opens no subscription" do
    @app.placements.delete_all

    get app_log_path(@app)

    assert_response :success
    assert_select ".logs", count: 0
    assert_select ".empty__title", text: /No containers reported/
  end

  test "logs need signing in" do
    delete session_path

    get placement_log_path(@web)
    assert_redirected_to new_session_path

    get app_log_path(@app)
    assert_redirected_to new_session_path
  end

  test "a container that is gone is a 404" do
    get placement_log_path(0)
    assert_response :not_found
  end

  test "the logs are linked from the server page and the app page" do
    get server_path(@web_1)
    assert_select "a[href=?][aria-label=?]", placement_log_path(@web), "Logs of web-web-production-v42"
    assert_select "a[href=?]", placement_log_path(@other)

    get app_path(@app)
    assert_select ".page-header a[href=?]", app_log_path(@app), text: "Logs"
  end

  private
    # The page subscribes with a grant for exactly what it recorded as viewed.
    def assert_channel(reader, params, *subject)
      channel = JSON.parse(css_select(".logs").first["data-logs-channel-value"])
      assert_equal({ "channel" => "LogsChannel", **params }, channel.except("grant"))
      assert LiveGrant.granted?(channel["grant"], reader, *subject)
    end
end
