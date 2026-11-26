require "test_helper"

class LogsTest < ActionDispatch::IntegrationTest
  setup do
    project = projects(:infra)
    @app = App.create!(project: project, service: "web", destination: "production", config_path: "deploy/web.production.yml", kind: "rails")
    @web_1, @web_2 = server_named("web-1.example.com"), server_named("web-2.example.com")
    @web = place(@web_1, WEB, app: @app)
    @worker = place(@web_2, WORKER, app: @app, name: "web-web-production-v41", state: "exited")
    @other = place(@web_1, "c" * 64, name: "blog-web-1a2b3c4d")
  end

  test "a deployer opens one container's logs, and it is recorded" do
    sign_in_as users(:deployer)

    assert_difference -> { Event.where(action: "logs.viewed").count }, 1 do
      get placement_log_path(@web)
    end

    assert_response :success
    assert_select ".logs[data-logs-channel-value=?]", { channel: "LogsChannel", placement_ids: [ @web.id ] }.to_json
    assert_select ".logs__chip", count: 0
    event = Event.find_by!(action: "logs.viewed")
    assert_equal users(:deployer), event.actor
    assert_equal @web_1, event.subject
    assert_equal "Viewed the logs of web-web-production-v42 on web-1.example.com", event.summary
  end

  test "an app's logs merge every server it runs on, running containers first" do
    sign_in_as users(:admin)

    assert_difference -> { Event.where(action: "logs.viewed").count }, 1 do
      get app_log_path(@app)
    end

    assert_response :success
    assert_select ".logs[data-logs-channel-value=?]", { channel: "LogsChannel", placement_ids: [ @web.id, @worker.id ] }.to_json
    assert_select ".logs__chip", count: 2
    assert_select ".logs__chip", text: "web-1"
    assert_select ".logs__chip", text: "web-2"
    event = Event.find_by!(action: "logs.viewed")
    assert_equal @app, event.subject
    assert_equal "Viewed the logs of web · production (2 containers on 2 servers)", event.summary
  end

  test "an app's logs stop at twenty containers, running ones kept" do
    21.times { |i| place(@web_1, i.to_s(16).rjust(64, "d"), app: @app, name: "web-old-#{i}", state: "exited") }
    sign_in_as users(:deployer)

    get app_log_path(@app)

    ids = JSON.parse(css_select(".logs").first["data-logs-channel-value"])["placement_ids"]
    assert_equal 20, ids.size
    assert_equal @web.id, ids.first
  end

  test "containers that only share a server are told apart by role" do
    sibling = place(@web_1, "e" * 64, app: @app, name: "web-job-production-v42", role: "job")
    sign_in_as users(:deployer)

    get app_log_path(@app)

    assert_select ".logs__chip", text: "web-1 · web"
    assert_select ".logs__chip", text: "web-1 · job"
    assert_select ".logs__chip[data-tooltip=?]", "web-job-production-v42 on web-1.example.com"
    assert sibling
  end

  test "an app with no containers says so and opens no subscription" do
    @app.placements.delete_all
    sign_in_as users(:deployer)

    get app_log_path(@app)

    assert_response :success
    assert_select ".logs", count: 0
    assert_select ".empty__title", text: /No containers reported/
  end

  test "a viewer is turned away and nothing is recorded" do
    sign_in_as users(:viewer)

    assert_no_difference -> { Event.count } do
      get placement_log_path(@web)
      assert_redirected_to root_path
      get app_log_path(@app)
      assert_redirected_to root_path
    end
  end

  test "logs need signing in" do
    get placement_log_path(@web)
    assert_redirected_to new_session_path

    get app_log_path(@app)
    assert_redirected_to new_session_path
  end

  test "a container that is gone is a 404" do
    sign_in_as users(:deployer)

    get placement_log_path(0)
    assert_response :not_found
  end

  test "the viewing shows on the Activity page in plain words" do
    sign_in_as users(:deployer)
    get placement_log_path(@web)

    get events_path
    assert_select ".row__title", text: "Viewed the logs of web-web-production-v42 on web-1.example.com"
    assert_select ".row__meta", text: /Dee Deployer · logs.viewed/
  end

  test "a deployer finds the logs from the server page and the app page" do
    sign_in_as users(:deployer)

    get server_path(@web_1)
    assert_select "a[href=?][aria-label=?]", placement_log_path(@web), "Logs of web-web-production-v42"
    assert_select "a[href=?]", placement_log_path(@other)

    get app_path(@app)
    assert_select ".page-header a[href=?]", app_log_path(@app), text: "Logs"
  end

  test "a viewer sees neither link" do
    sign_in_as users(:viewer)

    get server_path(@web_1)
    assert_response :success
    assert_select "a[href=?]", placement_log_path(@web), count: 0
    assert_select "a[href*=?]", "/log", count: 0

    get app_path(@app)
    assert_response :success
    assert_select "a[href=?]", app_log_path(@app), count: 0
  end
end
