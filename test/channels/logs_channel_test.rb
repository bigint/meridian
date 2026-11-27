require "test_helper"

class LogsChannelTest < ActionCable::Channel::TestCase
  include MemoryCacheHelper

  setup do
    @web_1, @web_2 = server_named("web-1.example.com"), server_named("web-2.example.com")
    @web = place(@web_1, WEB)
    @worker = place(@web_2, WORKER, name: "web-worker")
    stub_connection current_user: users(:ada), agent_token: nil
  end

  # Subscribes as a page would, with the grant the page hands over.
  def subscribe(placement_ids: nil, grant: :page, **params)
    grant = (LiveGrant.grant(connection.current_user, "logs", *placement_ids) if connection.current_user) if grant == :page
    super(placement_ids: placement_ids, grant: grant, **params)
  end

  # The channel streams only what a page granted: these containers, for logs, for this person.
  test "a subscription no page granted is refused" do
    stranger = User.create!(name: "Lee", email_address: "lee@example.com", password: "a long enough password")
    [ nil, "forged", LiveGrant.grant(users(:ada), "logs", @worker.id), LiveGrant.grant(users(:ada), "traffic", @web.id),
      LiveGrant.grant(stranger, "logs", @web.id) ].each do |grant|
      subscribe placement_ids: [ @web.id ], grant: grant
      assert subscription.rejected?, grant.inspect
    end
    assert_no_broadcasts AgentChannel.broadcasting_for(@web_1)
  end

  # A page open past the grant's life is turned down when it next
  # reconnects, and asks for a reload, which grants afresh.
  test "a grant lapses after twelve hours, so one page load doesn't stream for good" do
    grant = LiveGrant.grant(users(:ada), "logs", @web.id)

    travel 12.hours - 1.minute do
      subscribe placement_ids: [ @web.id ], grant: grant
      assert subscription.confirmed?
    end
    travel 12.hours + 1.minute do
      subscribe placement_ids: [ @web.id ], grant: grant
      assert subscription.rejected?
    end
  end

  test "the signed-in person streams each container's lines" do
    subscribe placement_ids: [ @web.id, @worker.id ]

    assert subscription.confirmed?
    assert_has_stream_for @web
    assert_has_stream_for @worker
  end

  test "an agent and a stranger are rejected, and nothing is tailed" do
    stub_connection current_user: nil, agent_token: nil
    subscribe placement_ids: [ @web.id ]
    assert subscription.rejected?

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

  # A laptop asleep keeps its socket open for minutes, and ActionCable never
  # times it out: only a page that says it is still there keeps the lease.
  test "a page that stops renewing lets the lease lapse, and one that renews keeps it" do
    subscribe placement_ids: [ @web.id ]
    renew = -> { LogsChannel.periodic_timers.each { |callback, _| subscription.instance_exec(&callback) } }

    travel ApplicationCable::Renewal::SILENCE + 1.second
    assert_no_broadcasts(AgentChannel.broadcasting_for(@web_1)) { renew.call }

    perform :renew
    travel LiveLogs::RENEW_EVERY + 1.second
    assert_broadcasts(AgentChannel.broadcasting_for(@web_1), 1) { renew.call }
  end
end
