require "test_helper"
require "turbo/broadcastable/test_helper"

class SnapshotIngestJobTest < ActiveJob::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @payload = JSON.parse(file_fixture("snapshots/web-1.json").read)
    Snapshot.new(@payload, token: agent_tokens(:web_1)).ingest
  end

  test "a new version redraws the server's region" do
    @payload["containers"].find { it["id"] == "aaa111" }["version"] = "v43"
    assert_turbo_stream_broadcasts([ :board, "sgp" ], count: 1) { report }
  end

  test "an agent back from quiet redraws, though nothing else changed" do
    Server.find_by!(machine_id: @payload["machine_id"]).update!(last_seen_at: 1.hour.ago)
    assert_turbo_stream_broadcasts([ :board, "sgp" ], count: 1) { report }
  end

  private
    def report
      perform_enqueued_jobs { SnapshotIngestJob.perform_now(agent_tokens(:web_1).reload, @payload) }
    end
end
