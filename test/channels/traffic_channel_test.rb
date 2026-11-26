require "test_helper"

class TrafficChannelTest < ActionCable::Channel::TestCase
  include MemoryCacheHelper

  setup do
    @web_1, @web_2 = server_named("web-1.example.com"), server_named("web-2.example.com")
    @app = App.create!(project: projects(:infra), service: "web", destination: "production", config_path: "deploy/web.yml", kind: "rails")
    place(@web_1, WEB, app: @app)
    place(@web_2, WORKER, app: @app)
    @proxy_1 = place(@web_1, "c" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
    @proxy_2 = place(@web_2, "d" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
    stub_connection current_user: users(:deployer), agent_token: nil
  end

  # kamal-proxy lines run to a kilobyte, and the agent sends at most 512 KB a
  # second of one container, history included, dropping the newest lines past
  # that. 200 lines fit; 1,000 lost the most recent requests.
  test "a deployer streams the app's traffic and every kamal-proxy is asked for the last 200 lines" do
    assert_broadcast_on AgentChannel.broadcasting_for(@web_1), { type: "tail", container: "c" * 64, seconds: 30, backlog: 200 } do
      assert_broadcast_on AgentChannel.broadcasting_for(@web_2), { type: "tail", container: "d" * 64, seconds: 30, backlog: 200 } do
        subscribe app_id: @app.id
      end
    end

    assert subscription.confirmed?
    assert_has_stream_for @app
  end

  test "a reader keeps the leases alive without asking for history again" do
    subscribe app_id: @app.id
    travel LiveLogs::RENEW_EVERY + 1.second

    assert_broadcast_on AgentChannel.broadcasting_for(@web_1), { type: "tail", container: "c" * 64, seconds: 30, backlog: 0 } do
      TrafficChannel.periodic_timers.each { |callback, _| subscription.instance_exec(&callback) }
    end
  end

  test "a viewer, a stranger, an unknown app and an app with no kamal-proxy are rejected" do
    [ users(:viewer), nil ].each do |user|
      stub_connection current_user: user, agent_token: nil
      subscribe app_id: @app.id
      assert subscription.rejected?, user.inspect
    end

    stub_connection current_user: users(:deployer), agent_token: nil
    [ nil, 0, "#{@app.id}", [ @app.id ] ].each do |id|
      subscribe app_id: id
      assert subscription.rejected?, id.inspect
    end

    Placement.where(kind: "proxy").delete_all
    subscribe app_id: @app.id
    assert subscription.rejected?
  end

  test "a reader removed mid-stream is hung up instead of renewed" do
    subscribe app_id: @app.id
    closed = []
    connection.define_singleton_method(:close) { |**options| closed << options }
    users(:deployer).destroy!
    travel LiveLogs::RENEW_EVERY + 1.second

    assert_no_broadcasts AgentChannel.broadcasting_for(@web_1) do
      TrafficChannel.periodic_timers.each { |callback, _| subscription.instance_exec(&callback) }
    end
    assert_equal [ { reason: "unauthorized" } ], closed
  end
end
