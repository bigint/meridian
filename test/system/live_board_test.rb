require "application_system_test_case"

# M1: a container that stops on one server turns its cell missing, live.
class LiveBoardTest < ApplicationSystemTestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ] ] })
    @project.sync
    @payload = JSON.parse(file_fixture("snapshots/web-1.json").read)
    ingest

    use_async_cable
  end

  teardown { restore_cable }

  test "stopping a container turns its cell missing without a reload" do
    sign_in users(:viewer)
    visit server_path(Server.find_by!(name: "web-1.example.com"))
    within("tr", text: "web · production") { assert_text "In sync" }
    assert_selector "turbo-cable-stream-source[connected]", visible: :all

    @payload["containers"].find { it["id"] == "aaa111" }["state"] = "exited"
    ingest

    within("tr", text: "web · production") { assert_text "Missing", wait: 10 }
  end

  private
    def ingest
      Rails.cache.clear
      perform_enqueued_jobs { SnapshotIngestJob.perform_later(agent_tokens(:web_1), @payload) }
    end
end
