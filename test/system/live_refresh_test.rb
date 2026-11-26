require "application_system_test_case"

# A live refresh morphs the page to the server's HTML, which doesn't know
# what the person is typing. Their text and the search's results stay.
class LiveRefreshTest < ApplicationSystemTestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ] ] })
    @project.sync
    @payload = JSON.parse(file_fixture("snapshots/web-1.json").read)
    ingest

    use_async_cable
  end

  teardown { restore_cable }

  test "a refresh keeps the search box's text and results, and a half-typed field" do
    sign_in users(:viewer)
    visit server_path(Server.find_by!(name: "web-1.example.com"))
    within("tr", text: "web · production") { assert_text "In sync" }
    assert_selector "turbo-cable-stream-source[connected]", visible: :all

    fill_in "Search apps, servers and projects", with: "blog"
    within("#jump_results") { assert_link "blog" }

    @payload["containers"].find { it["id"] == "aaa111" }["state"] = "exited"
    ingest
    within("tr", text: "web · production") { assert_text "Missing", wait: 10 }

    assert_field "Search apps, servers and projects", with: "blog"
    within("#jump_results") { assert_link "blog" }
  end

  private
    def ingest
      Rails.cache.clear
      perform_enqueued_jobs { SnapshotIngestJob.perform_later(agent_tokens(:web_1), @payload) }
    end
end
