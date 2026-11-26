require "test_helper"

class LogsChannelTest < ActionCable::Channel::TestCase
  include MemoryCacheHelper

  setup do
    @web_1, @web_2 = server_named("web-1.example.com"), server_named("web-2.example.com")
    @web = place(@web_1, WEB)
    @worker = place(@web_2, WORKER, name: "web-worker")
    stub_connection current_user: users(:deployer), agent_token: nil
  end

  test "a deployer streams each container's lines" do
    subscribe placement_ids: [ @web.id, @worker.id ]

    assert subscription.confirmed?
    assert_has_stream_for @web
    assert_has_stream_for @worker
  end

  test "an admin can too" do
    stub_connection current_user: users(:admin), agent_token: nil
    subscribe placement_ids: [ @web.id ]

    assert_has_stream_for @web
  end

  test "a viewer, an agent and a stranger are rejected, and nothing is tailed" do
    [ users(:viewer), nil ].each do |user|
      stub_connection current_user: user, agent_token: nil
      subscribe placement_ids: [ @web.id ]
      assert subscription.rejected?, user.inspect
    end

    stub_connection current_user: nil, agent_token: agent_tokens(:web_1)
    subscribe placement_ids: [ @web.id ]
    assert subscription.rejected?

    assert_no_broadcasts AgentChannel.broadcasting_for(@web_1)
  end

  test "more than twenty containers is too many" do
    ids = Array.new(21) { |i| place(@web_1, i.to_s(16).rjust(64, "c"), name: "extra-#{i}").id }

    subscribe placement_ids: ids
    assert subscription.rejected?

    subscribe placement_ids: ids.first(20)
    assert subscription.confirmed?
  end

  test "ids that are missing, unknown or not ids are rejected" do
    [ nil, [], [ 0 ], "all", { "1" => 1 }, [ "#{@web.id}" ], [ nil ] ].each do |ids|
      subscribe placement_ids: ids
      assert subscription.rejected?, ids.inspect
    end
  end

  test "a container that is gone is skipped, the rest still stream" do
    subscribe placement_ids: [ @web.id, 0 ]

    assert subscription.confirmed?
    assert_has_stream_for @web
  end

  test "subscribing asks each container's agent for its last 200 lines" do
    assert_broadcast_on AgentChannel.broadcasting_for(@web_1), { type: "tail", container: WEB, seconds: 30, backlog: 200 } do
      assert_broadcast_on AgentChannel.broadcasting_for(@web_2), { type: "tail", container: WORKER, seconds: 30, backlog: 200 } do
        subscribe placement_ids: [ @web.id, @worker.id ]
      end
    end
  end

  test "a reader keeps the lease alive without asking for the backlog again" do
    subscribe placement_ids: [ @web.id ]
    travel LiveLogs::RENEW_EVERY + 1.second

    assert_broadcast_on AgentChannel.broadcasting_for(@web_1), { type: "tail", container: WEB, seconds: 30, backlog: 0 } do
      LogsChannel.periodic_timers.each { |callback, _| subscription.instance_exec(&callback) }
    end
  end
end
