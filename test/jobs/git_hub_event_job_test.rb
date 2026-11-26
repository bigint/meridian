require "test_helper"

class GitHubEventJobTest < ActiveJob::TestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
    @app = @project.apps.find_by!(service: "api")
    @app.update!(source_repo: "example/api-src")
    @writes = stub_github_writes(@project)
    @dispatches = []
    stub_request(:post, %r{/actions/workflows/meridian-deploy.yml/dispatches}).to_return { |r| @dispatches << JSON.parse(r.body); { status: 204 } }
  end

  test "a push to a pull request that has closed since deploys nothing" do
    GitHubEventJob.perform_now("pull_request", pull_request("synchronize", state: "closed"))

    assert_empty @dispatches
    assert_empty Preview.all
  end

  test "a preview's workflow run is matched in the repository that sent it" do
    preview = Preview.deploy(@app, number: 7, head_sha: "e" * 40, url: nil)
    run = { "event" => "workflow_dispatch", "path" => ".github/workflows/meridian-deploy.yml", "head_branch" => "main",
            "display_title" => "deploy deploy/api.yml pr-7", "status" => "completed", "conclusion" => "success" }

    GitHubEventJob.perform_now("workflow_run", { "repository" => { "full_name" => "example/infra" }, "workflow_run" => run })
    assert preview.reload.active?
  end

  test "a pull request from a fork gets no preview, and the activity log says why" do
    GitHubEventJob.perform_now("pull_request", pull_request("opened", head_repo: "mallory/api-src"))
    GitHubEventJob.perform_now("pull_request", pull_request("synchronize", head_repo: "mallory/api-src"))
    GitHubEventJob.perform_now("pull_request", pull_request("opened", number: 8, head_repo: nil))

    assert_empty @writes
    assert_empty @dispatches
    assert_equal [ "No preview for example/api-src#7: it comes from the fork mallory/api-src", "No preview for example/api-src#8: it comes from a deleted fork" ],
      Event.where(action: "preview.skipped").order(:id).map(&:summary)
  end

  test "a pull request from a branch of the repository itself gets a preview" do
    GitHubEventJob.perform_now("pull_request", pull_request("opened", head_repo: "Example/API-src"))
    assert_equal "deploy", @dispatches.sole.dig("inputs", "command")
  end

  private
    def pull_request(action, number: 7, state: "open", head_repo: "example/api-src")
      { "action" => action, "number" => number, "repository" => { "full_name" => "example/api-src" },
        "pull_request" => { "state" => state, "html_url" => "https://github.com/example/api-src/pull/#{number}",
          "head" => { "sha" => "e" * 40, "repo" => head_repo && { "full_name" => head_repo } }, "base" => { "repo" => { "full_name" => "example/api-src" } } } }
    end
end
