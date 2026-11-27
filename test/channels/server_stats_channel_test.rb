require "test_helper"

class ServerStatsChannelTest < ActionCable::Channel::TestCase
  include MemoryCacheHelper

  setup do
    @server = Server.create!(name: "web-1.example.com", hostname: "web-1.example.com", machine_id: "m-web-1", last_seen_at: Time.current)
    stub_connection current_user: users(:ada), agent_token: nil
  end

  test "a signed-in user streams a server's frames" do
    subscribe server_id: @server.id

    assert subscription.confirmed?
    assert_has_stream_for @server
  end

  test "watching tells the server's agent to stream" do
    assert_broadcast_on AgentChannel.broadcasting_for(@server), { type: "watch", seconds: 30 } do
      subscribe server_id: @server.id
    end
  end

  test "watchers are told to renew at most every few seconds, however many there are" do
    agent_stream = AgentChannel.broadcasting_for(@server)

    assert_broadcasts agent_stream, 1 do
      3.times { subscribe server_id: @server.id }
    end

    travel LiveStats::RENEW_EVERY + 1.second
    assert_broadcasts agent_stream, 1 do
      subscribe server_id: @server.id
    end
  end

  test "a watcher keeps the lease alive while it stays" do
    subscribe server_id: @server.id
    travel LiveStats::RENEW_EVERY + 1.second

    assert_broadcasts AgentChannel.broadcasting_for(@server), 1 do
      ServerStatsChannel.periodic_timers.each { |callback, _| subscription.instance_exec(&callback) }
    end
  end

  # Run again as an action, subscribed added a pubsub listener each time that
  # unsubscribing never removed, so any viewer could pile them up.
  test "a client can't run subscribed again as an action" do
    subscribe server_id: @server.id
    3.times { perform :subscribed }

    assert_equal [ ServerStatsChannel.broadcasting_for(@server) ], subscription.streams
    [ AgentChannel, LogsChannel, ServerStatsChannel, TrafficChannel ].each do |channel|
      assert_not_includes channel.action_methods, "subscribed", channel.name
    end
  end

  test "a page that stops renewing lets the lease lapse" do
    subscribe server_id: @server.id
    travel ApplicationCable::Renewal::SILENCE + 1.second

    assert_no_broadcasts AgentChannel.broadcasting_for(@server) do
      ServerStatsChannel.periodic_timers.each { |callback, _| subscription.instance_exec(&callback) }
    end
  end

  test "an agent is rejected" do
    stub_connection current_user: nil, agent_token: agent_tokens(:web_1)
    subscribe server_id: @server.id

    assert subscription.rejected?
    assert_no_broadcasts AgentChannel.broadcasting_for(@server)
  end

  test "an unknown server is rejected" do
    subscribe server_id: 0

    assert subscription.rejected?
  end
end
