require "test_helper"

class AgentChannelTest < ActionCable::Channel::TestCase
  include MemoryCacheHelper

  setup do
    @server = Server.create!(name: "web-1.example.com", hostname: "web-1.example.com", machine_id: "m-web-1", last_seen_at: Time.current)
    stub_connection current_user: nil, agent_token: agent_tokens(:web_1)
    @closed = closed = []
    connection.define_singleton_method(:close) { |**options| closed << options }
  end

  test "an agent subscribes to the server with its machine id" do
    subscribe machine_id: "m-web-1"

    assert subscription.confirmed?
    assert_has_stream_for @server
  end

  test "a fleet token finds its server by machine id too" do
    stub_connection current_user: nil, agent_token: agent_tokens(:fleet)
    subscribe machine_id: "m-web-1"

    assert_has_stream_for @server
  end

  test "a token bound to a server follows that server's machine id" do
    agent_tokens(:web_1).update!(server: @server)

    subscribe machine_id: "m-web-1"
    assert subscription.confirmed?

    subscribe machine_id: "someone-else"
    assert subscription.rejected?
  end

  test "a token bound to another machine is rejected" do
    other = Server.create!(name: "db-1", hostname: "db-1", machine_id: "m-db-1")
    agent_tokens(:web_1).update!(server: other)

    subscribe machine_id: "m-web-1"

    assert subscription.rejected?
  end

  test "an unknown machine is rejected and nothing is created" do
    assert_no_difference -> { Server.count } do
      subscribe machine_id: "never-reported"
    end

    assert subscription.rejected?
  end

  test "a missing machine id is rejected" do
    subscribe

    assert subscription.rejected?
  end

  test "a signed-in browser is rejected" do
    stub_connection current_user: users(:admin), agent_token: nil
    subscribe machine_id: "m-web-1"

    assert subscription.rejected?
  end

  test "an active lease is passed on when the agent subscribes" do
    LiveStats.watch(@server)

    subscribe machine_id: "m-web-1"

    assert_equal [ { "type" => "watch", "seconds" => LiveStats::LEASE.to_i } ], transmissions
  end

  test "no lease, no watch message" do
    subscribe machine_id: "m-web-1"

    assert_empty transmissions
  end

  test "a frame is cleaned and relayed to the watching browsers" do
    subscribe machine_id: "m-web-1"
    id = "a" * 64

    perform :stats, { host: { cpu_cores: 0.5, cores: 2, secret: "x" }, containers: [ { id: id, cpu_cores: 0.1, env: "x" } ], extra: "x" }.deep_stringify_keys

    assert_broadcast_on ServerStatsChannel.broadcasting_for(@server),
      { "host" => { "cpu_cores" => 0.5, "cores" => 2 }, "containers" => [ { "id" => id, "cpu_cores" => 0.1 } ] }
  end

  test "a frame that arrives too soon after the last is dropped" do
    subscribe machine_id: "m-web-1"
    frame = { "host" => { "cpu_cores" => 0.5 } }

    start = Time.current
    [ 0, 0.1, 0.4, 0.6, 0.7, 1.2 ].each do |seconds|
      travel_to start + seconds, with_usec: true
      perform :stats, frame
    end

    assert_broadcasts ServerStatsChannel.broadcasting_for(@server), 3
  end

  test "a token revoked while connected is closed within the minute" do
    subscribe machine_id: "m-web-1"
    run_periodic_checks
    assert_empty @closed

    agent_tokens(:web_1).revoke
    run_periodic_checks

    assert_equal [ { reason: "unauthorized", reconnect: false } ], @closed
  end

  private
    def run_periodic_checks
      AgentChannel.periodic_timers.each { |callback, _| subscription.instance_exec(&callback) }
    end
end
