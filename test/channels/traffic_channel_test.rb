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
    stub_connection current_user: users(:ada), agent_token: nil
  end

  # Subscribes as the Traffic page would, with the grant it hands over.
  def subscribe(app_id: nil, grant: :page, **params)
    grant = (LiveGrant.grant(connection.current_user, "traffic", app_id) if connection.current_user) if grant == :page
    super(app_id: app_id, grant: grant, **params)
  end

  test "a subscription the Traffic page didn't grant is refused" do
    stranger = User.create!(name: "Lee", email_address: "lee@example.com", password: "a long enough password")
    [ nil, "forged", LiveGrant.grant(stranger, "traffic", @app.id), LiveGrant.grant(users(:ada), "logs", @app.id) ].each do |grant|
      subscribe app_id: @app.id, grant: grant
      assert subscription.rejected?, grant.inspect
    end
  end

  # One page load isn't a way to read for good: a page open past the
  # grant's life is turned down when it reconnects, and asks for a reload.
  test "a grant lapses after twelve hours" do
    grant = LiveGrant.grant(users(:ada), "traffic", @app.id)

    travel 12.hours - 1.minute do
      subscribe app_id: @app.id, grant: grant
      assert subscription.confirmed?
    end
    travel 12.hours + 1.minute do
      subscribe app_id: @app.id, grant: grant
      assert subscription.rejected?
    end
  end

  # Traffic is live only, so no kamal-proxy is asked for its history.
  test "the app's traffic streams, and every kamal-proxy is tailed from now on" do
    assert_broadcast_on AgentChannel.broadcasting_for(@web_1), { type: "tail", container: "c" * 64, seconds: 30, backlog: 0 } do
      assert_broadcast_on AgentChannel.broadcasting_for(@web_2), { type: "tail", container: "d" * 64, seconds: 30, backlog: 0 } do
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

  test "a stranger, an unknown app and an app with no kamal-proxy are rejected" do
    stub_connection current_user: nil, agent_token: nil
    subscribe app_id: @app.id
    assert subscription.rejected?

    stub_connection current_user: users(:ada), agent_token: nil
    [ nil, 0, "#{@app.id}", [ @app.id ] ].each do |id|
      subscribe app_id: id
      assert subscription.rejected?, id.inspect
    end

    Placement.where(kind: "proxy").delete_all
    subscribe app_id: @app.id
    assert subscription.rejected?
  end

  test "the fleet's traffic streams from kamal-proxy on every server" do
    grant = LiveGrant.grant(users(:ada), "traffic", LiveTraffic::FLEET)

    assert_broadcast_on AgentChannel.broadcasting_for(@web_1), { type: "tail", container: "c" * 64, seconds: 30, backlog: 0 } do
      assert_broadcast_on AgentChannel.broadcasting_for(@web_2), { type: "tail", container: "d" * 64, seconds: 30, backlog: 0 } do
        subscribe fleet: true, grant: grant
      end
    end

    assert subscription.confirmed?
    assert_has_stream TrafficChannel.broadcasting_for(LiveTraffic::FLEET)
  end

  test "the fleet's traffic needs the fleet's grant" do
    [ nil, LiveGrant.grant(users(:ada), "traffic", @app.id), LiveGrant.grant(users(:ada), "logs", LiveTraffic::FLEET) ].each do |grant|
      subscribe fleet: true, grant: grant
      assert subscription.rejected?, grant.inspect
    end

    subscribe fleet: "true", grant: LiveGrant.grant(users(:ada), "traffic", LiveTraffic::FLEET)
    assert subscription.rejected?
  end

  test "a page that stops renewing lets the leases lapse" do
    subscribe app_id: @app.id
    travel ApplicationCable::Renewal::SILENCE + 1.second

    assert_no_broadcasts AgentChannel.broadcasting_for(@web_1) do
      TrafficChannel.periodic_timers.each { |callback, _| subscription.instance_exec(&callback) }
    end
  end
end
