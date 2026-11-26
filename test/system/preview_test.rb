require "application_system_test_case"

# M5: a PR gets a working preview URL and is cleaned up when it closes.
class PreviewSystemTest < ApplicationSystemTestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
    @project.apps.find_by!(service: "api").update!(source_repo: "example/api-src")
    @writes = stub_github_writes(@project)
    stub_request(:post, %r{/actions/workflows/meridian-deploy.yml/dispatches}).to_return(status: 204)
    @delete = stub_request(:delete, %r{/contents/deploy/api.pr-3.yml}).to_return_json(body: { commit: { sha: "d" * 40 } })
  end

  test "pull request opens, preview goes live, pull request closes, preview is removed" do
    perform_enqueued_jobs do
      deliver "pull_request", { action: "opened", number: 3, pull_request: { head: { sha: "h" * 40 }, html_url: "https://github.com/example/api-src/pull/3" } }, repo: "example/api-src"
      deliver "workflow_run", { workflow_run: { event: "workflow_dispatch", display_title: "deploy deploy/api.yml pr-3", head_branch: "main", status: "completed", conclusion: "success" } }
    end

    sign_in users(:viewer)
    visit previews_path
    within("tr", text: "example/api-src#3") do
      assert_link "pr-3.api.preview.example.com", href: "https://pr-3.api.preview.example.com"
      assert_text "Active"
    end

    stub_github_files(@project, { "deploy/api.yml" => file_fixture("infra/deploy/api.yml").read, "deploy/api.pr-3.yml" => @writes.sole["content"] }, head: "z" * 40)
    perform_enqueued_jobs do
      deliver "pull_request", { action: "closed", number: 3, pull_request: { merged: true, head: { sha: "h" * 40 } } }, repo: "example/api-src"
      deliver "workflow_run", { workflow_run: { event: "workflow_dispatch", display_title: "remove deploy/api.yml pr-3", head_branch: "main", status: "completed", conclusion: "success" } }
    end

    visit previews_path
    assert_text "No open previews"
    assert_selector "section h2", text: /recently removed/i
    assert_requested @delete
  end

  private
    def deliver(event, payload, repo: @project.repo_full_name)
      body = payload.merge(repository: { full_name: repo }).to_json
      signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", ENV["GITHUB_APP_WEBHOOK_SECRET"], body)
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post "/webhooks/github", params: body, headers: { "X-GitHub-Event" => event, "X-Hub-Signature-256" => signature, "Content-Type" => "application/json" }
      assert_equal 202, session.response.status
    end
end
