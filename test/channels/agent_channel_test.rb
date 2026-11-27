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

  test "a fleet token can't open the line of a server with a token of its own" do
    agent_tokens(:web_1).update!(server: @server)
    stub_connection current_user: nil, agent_token: agent_tokens(:fleet)
    subscribe machine_id: "m-web-1"

    assert subscription.rejected?

    agent_tokens(:web_1).revoke
    subscribe machine_id: "m-web-1"
    assert subscription.confirmed?, "a revoked token no longer holds the server"
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
    stub_connection current_user: users(:ada), agent_token: nil
    subscribe machine_id: "m-web-1"

    assert subscription.rejected?
  end

  test "an active lease is passed on when the agent subscribes" do
    LiveStats.watch(@server)

    subscribe machine_id: "m-web-1"

    assert_equal [ { "type" => "watch", "seconds" => LiveStats::LEASE.to_i } ], transmissions
  end

  test "a container someone is still reading is tailed again, with history, when its agent reconnects" do
    read = place(@server, WEB)
    place(@server, "b" * 64, name: "nobody-reads-this")
    LiveLogs.tail(read, backlog: LiveLogs::BACKLOG)

    subscribe machine_id: "m-web-1"

    assert_equal [ { "type" => "tail", "container" => WEB, "seconds" => LiveLogs::LEASE.to_i, "backlog" => LiveLogs::BACKLOG } ], transmissions
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

  test "a log batch is relayed to the browsers reading that container, with its placement as the source" do
    placement = place(@server, WEB)
    subscribe machine_id: "m-web-1"

    assert_broadcast_on LogsChannel.broadcasting_for(placement), batch(WEB, secret: "x").except("action", "secret").merge("source" => placement.id) do
      perform :logs, batch(WEB, secret: "x")
    end
  end

  test "a kamal-proxy batch also reaches the readers of each app's traffic, only that app's requests" do
    app = App.create!(project: projects(:infra), service: "web", destination: "production", config_path: "deploy/web.yml", kind: "rails",
      roles: [ { "name" => "web", "hosts" => [ @server.hostname ], "proxy" => true } ])
    place(@server, WEB, app: app)
    proxy = place(@server, "f" * 64, name: "kamal-proxy", kind: "proxy", service: nil, role: nil)
    LiveTraffic.watch(app, [ proxy ])
    mine = { "t" => "2026-11-26T12:00:01.000Z", "s" => "out", "m" => { msg: "Request", status: 200, path: "/", service: "web-web-production" }.to_json }
    theirs = { "t" => "2026-11-26T12:00:02.000Z", "s" => "out", "m" => { msg: "Request", status: 200, path: "/", service: "blog-web" }.to_json }
    subscribe machine_id: "m-web-1"

    assert_broadcast_on TrafficChannel.broadcasting_for(app), { "container" => "f" * 64, "source" => proxy.id, "lines" => [ mine ] } do
      perform :logs, batch("f" * 64, lines: [ mine, theirs ])
    end
  end

  test "a batch for a container that is not on this server is ignored" do
    other = server_named("web-2.example.com")
    elsewhere = place(other, WEB)
    here = place(@server, "c" * 64, name: "blog-web-1a2b3c4d")
    subscribe machine_id: "m-web-1"

    perform :logs, batch(WEB)
    perform :logs, batch(WORKER)

    assert_no_broadcasts LogsChannel.broadcasting_for(elsewhere)
    assert_no_broadcasts LogsChannel.broadcasting_for(here)
  end

  test "a batch that breaks the contract is ignored" do
    placement = place(@server, WEB)
    subscribe machine_id: "m-web-1"

    perform :logs, batch("../etc", lines: [ { "t" => "x", "s" => "out", "m" => "hi" } ])
    perform :logs, batch(WEB, lines: [])
    perform :logs, { "container" => WEB, "lines" => "nonsense" }

    assert_no_broadcasts LogsChannel.broadcasting_for(placement)
  end

  test "an agent that has logs off, refuses a container or sees it stop is relayed too" do
    placement = place(@server, WEB)
    subscribe machine_id: "m-web-1"
    stream = LogsChannel.broadcasting_for(placement)

    assert_broadcast_on(stream, { "container" => WEB, "off" => true, "source" => placement.id }) { perform :logs, { "action" => "logs", "container" => WEB, "off" => true } }
    assert_broadcast_on(stream, { "container" => WEB, "refused" => "not found", "source" => placement.id }) { perform :logs, { "action" => "logs", "container" => WEB, "refused" => "not found" } }
    assert_broadcast_on(stream, { "container" => WEB, "ended" => true, "source" => placement.id }) { perform :logs, { "action" => "logs", "container" => WEB, "ended" => true, "lines" => [] } }
  end

  test "frames past the per-second budget are dropped, and the budget comes back" do
    placement = place(@server, WEB)
    subscribe machine_id: "m-web-1"
    budget = AgentChannel::MAX_LOG_FRAMES_PER_SECOND

    start = Time.current
    travel_to start, with_usec: true
    assert_broadcasts LogsChannel.broadcasting_for(placement), budget do
      (budget + 5).times { perform :logs, batch(WEB) }
    end

    travel_to start + 1.1, with_usec: true
    assert_broadcasts LogsChannel.broadcasting_for(placement), 5 do
      5.times { perform :logs, batch(WEB) }
    end
  end

  test "the budget is per subscription" do
    placement = place(@server, WEB)
    subscribe machine_id: "m-web-1"
    25.times { perform :logs, batch(WEB) }

    subscribe machine_id: "m-web-1"
    assert_broadcasts LogsChannel.broadcasting_for(placement), 1 do
      perform :logs, batch(WEB)
    end
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

  test "a token revoked since the cable opened can't subscribe again" do
    agent_tokens(:web_1).revoke

    subscribe machine_id: "m-web-1"

    assert subscription.rejected?
  end

  test "revoking a token hangs up its agents for good" do
    assert_broadcast_on "action_cable/#{agent_tokens(:web_1).to_gid_param}", { type: "disconnect", reconnect: false } do
      AgentChannel.disconnect(agent_tokens(:web_1))
    end
  end
end
