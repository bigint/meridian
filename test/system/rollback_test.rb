require "application_system_test_case"

# M2: a rollback from the UI ships through CI and the board returns to in sync.
class RollbackTest < ApplicationSystemTestCase
  include GitHubHelper

  BEFORE = { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ], [ "b" * 40, "v41\n" ] ] }
  AFTER = { "deploy/web.production.version" => [ [ "r" * 40, "v41\n" ], [ "c" * 40, "v42\n" ], [ "b" * 40, "v41\n" ] ] }
  SERVERS = { "web-1" => "web", "web-2" => "web", "jobs-1" => "job" }

  setup do
    @project = projects(:infra)
    stub_github_repo(@project, history: BEFORE)
    @project.sync
    @app = @project.apps.find_by!(service: "web", destination: "production")
    report_running "v42"
  end

  test "roll back, CI deploys, agents report, board is in sync" do
    stub_github_commit(@project, "c" * 40, parent: "b" * 40)
    writes = stub_github_writes(@project, commit: "r" * 40)

    sign_in users(:deployer)
    visit app_path(@app)
    accept_confirm { click_on "Roll back" }
    assert_text "Committed a revert to v41"
    assert_equal "v41\n", writes.sole["content"]

    # GitHub: the push lands, then the Actions run completes.
    stub_github_repo(@project, head: "r" * 40, history: AFTER, files: { "deploy/web.production.version" => "v41\n" })
    perform_enqueued_jobs do
      deliver "push", ref: "refs/heads/main"
      deliver "workflow_run", workflow_run: { id: 5, head_sha: "r" * 40, head_branch: "main", status: "completed", conclusion: "success", html_url: "https://github.com/example/infra/actions/runs/5", updated_at: Time.current.iso8601 }
    end

    # Kamal ran; agents now see v41.
    report_running "v41"

    visit app_path(@app)
    within("section[aria-labelledby=deploy-heading]") do
      assert_text "Success"
      assert_text "v41"
      assert_no_text "Waiting"
    end

    visit root_path(app: "web")
    within("tr", text: "web · production") do
      assert_selector "[data-state=in_sync]", count: 3
      assert_no_selector "[data-state=drifted]"
    end
  end

  private
    def deliver(event, payload)
      body = payload.merge(repository: { full_name: @project.repo_full_name }).to_json
      signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", ENV["GITHUB_APP_WEBHOOK_SECRET"], body)
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post "/webhooks/github", params: body, headers: { "X-GitHub-Event" => event, "X-Hub-Signature-256" => signature, "Content-Type" => "application/json" }
      assert_equal 202, session.response.status
    end

    def report_running(version)
      SERVERS.each do |host, role|
        token = AgentToken.find_or_create_by!(label: host)
        payload = { "machine_id" => "m-#{host}", "hostname" => host, "agent_version" => "0.1.0", "labels" => {},
          "containers" => [ { "id" => "#{host}-#{version}", "name" => "web-#{role}-production-#{version}", "service" => "web", "role" => role, "destination" => "production", "version" => version, "kind" => "app", "state" => "running" } ] }
        Snapshot.new(payload, token: token).ingest
      end
    end
end
