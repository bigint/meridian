require "test_helper"

class SnapshotTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ] ] })
    @project.sync
    @payload = JSON.parse(file_fixture("snapshots/web-1.json").read)
  end

  test "claims the Git server by short hostname and binds a per-server token" do
    server = ingest

    assert_equal Server.find_by!(name: "web-1.example.com"), server
    assert_equal @payload["machine_id"], server.machine_id
    assert_equal({ "region" => "sgp", "provider" => "example" }, server.labels)
    assert_equal server, agent_tokens(:web_1).reload.server
  end

  test "placements are upserted, never appended, and gone containers are deleted" do
    server = ingest
    assert_equal 5, server.placements.count

    @payload["containers"].reject! { it["id"] == "aaa111" }
    ingest
    assert_equal 4, server.placements.count
    assert_nil server.placements.find_by(container_id: "aaa111")
  end

  test "a truncated snapshot keeps placements it didn't mention" do
    server = ingest
    @payload["containers"] = @payload["containers"].first(1)
    @payload["truncated"] = true
    ingest
    assert_equal 5, server.placements.count
  end

  test "containers map to apps by service and destination" do
    server = ingest
    web = @project.apps.find_by!(service: "web", destination: "production")

    assert_equal web, server.placements.find_by!(container_id: "aaa111").app
    assert_nil server.placements.find_by!(container_id: "ccc333").app
    assert_equal "proxy", server.placements.find_by!(container_id: "ddd444").kind
  end

  test "drift on the board" do
    server = ingest
    cells = Board.new(server_id: server.id).cells.index_by { it.app.service }

    assert_equal "in_sync", cells["web"].state
    assert_equal "unknown", cells["blog"].state, "blog has no version file to compare with"

    @payload["containers"].find { it["id"] == "aaa111" }["state"] = "exited"
    ingest
    assert_equal "missing", Board.new(server_id: server.id).cells.find { it.app.service == "web" }.state
  end

  test "needs attention lists missing before drifted, in plain order" do
    ingest
    @payload["containers"].find { it["id"] == "aaa111" }["state"] = "exited"
    @payload["containers"] << { "id" => "eee", "name" => "api-web-v1", "service" => "api", "role" => "web", "destination" => "", "version" => "v1", "kind" => "app", "state" => "running" }
    ingest

    attention = Board.new.attention
    assert_equal %w[ missing stray ], attention.map(&:state)
    assert_equal [ "web · production", "api" ], attention.map { it.app.name }
  end

  test "changed? is true only when a page would draw differently" do
    assert snapshot.tap(&:ingest).changed?, "first report"
    assert_not snapshot.tap(&:ingest).changed?, "same report again"

    { "health" => ->(p) { p["containers"].first["health"] = "unhealthy" },
      "removal" => ->(p) { p["containers"].pop },
      "labels" => ->(p) { p["labels"]["region"] = "ams" } }.each do |what, change|
      change.(@payload)
      assert snapshot.tap(&:ingest).changed?, what
      assert_not snapshot.tap(&:ingest).changed?, "#{what}, reported again"
    end
  end

  test "a per-server token can't report for another machine" do
    ingest
    assert_raises(Snapshot::Rejected) { ingest(@payload.merge("machine_id" => "other")) }
  end

  test "a fleet token identifies servers by machine id" do
    a = ingest(@payload, token: agent_tokens(:fleet))
    b = ingest(@payload.merge("machine_id" => "m2", "hostname" => "web-2"), token: agent_tokens(:fleet))

    assert_not_equal a, b
    assert_equal "web-2.example.com", b.name
    assert_nil agent_tokens(:fleet).reload.server
  end

  test "a hostname that isn't a host name is refused, since configs are written from it" do
    [ "web-9<%= `id` %>", "web-9\nenv: {}", "web 9" ].each do |hostname|
      assert_not snapshot(@payload.merge("hostname" => hostname)).valid?, hostname.inspect
    end
    assert snapshot(@payload.merge("hostname" => "ip-10-0-0-5.ec2.internal")).valid?
  end

  test "the job payload never carries env, commands or mounts" do
    @payload["containers"].first.merge!("env" => [ "SECRET=x" ], "cmd" => "bin/rails s", "mounts" => [ "/a" ])
    job = Snapshot.new(@payload, token: agent_tokens(:web_1)).to_job

    assert_no_match(/SECRET|bin\/rails|mounts/, job.to_json)
  end

  test "an agent at an IP Git doesn't list never claims another IP's server" do
    git = Server.create!(name: "10.0.0.5", hostname: "10.0.0.5")
    server = ingest(@payload.merge("machine_id" => "m-9", "hostname" => "10.0.0.9"), token: agent_tokens(:fleet))

    assert_not_equal git, server
    assert_nil git.reload.machine_id
  end

  test "a rebuilt machine takes back the server Git places once the old one has been silent long enough" do
    old = ingest(@payload, token: agent_tokens(:fleet))
    rebuilt = @payload.merge("machine_id" => "rebuilt", "hostname" => "web-1.example.com")

    travel 2.minutes
    early = ingest(rebuilt, token: agent_tokens(:fleet))
    assert_not_equal old, early, "a short silence is not a rebuild"
    early.destroy

    travel Server::RECLAIM_AFTER
    assert_equal old, ingest(rebuilt, token: agent_tokens(:fleet))
    assert_equal "rebuilt", old.reload.machine_id
    assert_equal "in_sync", Board.new(server_id: old.id).cells.find { it.app.service == "web" }.state
  end

  test "a new machine that only shares a silent server's first DNS label never takes it over" do
    old = ingest(@payload, token: agent_tokens(:fleet))
    travel 1.hour

    stranger = ingest(@payload.merge("machine_id" => "stranger"), token: agent_tokens(:fleet))
    assert_not_equal old, stranger
    assert_equal @payload["machine_id"], old.reload.machine_id
  end

  test "a server whose agent reports seldom is taken back only once it is stale too" do
    old = ingest(@payload.merge("interval_seconds" => 600), token: agent_tokens(:fleet))
    rebuilt = @payload.merge("machine_id" => "rebuilt", "hostname" => "web-1.example.com")

    travel Server::RECLAIM_AFTER + 1.minute
    early = ingest(rebuilt, token: agent_tokens(:fleet))
    assert_not_equal old, early, "silent for less than three of its intervals: still alive"
    early.destroy

    travel 30.minutes
    assert_equal old, ingest(rebuilt, token: agent_tokens(:fleet))
  end

  test "a silent server Git doesn't place is never taken over" do
    lone = Server.create!(name: "spare", hostname: "spare", machine_id: "m-old", last_seen_at: 1.day.ago)

    assert_not_equal lone, ingest(@payload.merge("machine_id" => "m-new", "hostname" => "spare"), token: agent_tokens(:fleet))
  end

  test "the agent's interval is kept, and nonsense is ignored" do
    assert_equal 60, ingest(@payload.merge("interval_seconds" => 60)).interval_seconds
    assert_nil ingest(@payload.merge("interval_seconds" => "60")).interval_seconds
  end

  test "labels must be an object" do
    assert_not snapshot(@payload.merge("labels" => "region=sgp")).valid?
    assert_not snapshot(@payload.merge("labels" => [ %w[ region sgp ] ])).valid?
    assert snapshot(@payload.except("labels")).valid?
  end

  private
    def ingest(payload = @payload, token: agent_tokens(:web_1))
      snapshot(payload, token: token).ingest
    end

    def snapshot(payload = @payload, token: agent_tokens(:web_1))
      Snapshot.new(payload, token: token.reload)
    end
end
