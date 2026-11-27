require "test_helper"

# Without webhooks Meridian polls: the scheduled sync also reads recent
# workflow runs, so deploys made outside Meridian still show up and finish.
class ProjectPollTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { @project = projects(:infra) }

  test "a workflow run found by polling becomes a deploy, and later polls move it along" do
    stub_github_repo(@project, head: "c" * 40, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ] ] },
      runs: [ workflow_run(id: 77, status: "in_progress", updated_at: 2.minutes.ago) ])
    ProjectSyncJob.perform_now(@project)

    deploy = Deploy.sole
    assert_equal [ "web · production", "v42", 77, "in_progress" ], [ deploy.app.name, deploy.version, deploy.ci_run_id, deploy.status ]

    stub_github_runs(@project, [ workflow_run(id: 77, status: "completed", conclusion: "success", updated_at: 1.minute.ago) ])
    ProjectSyncJob.perform_now(@project)

    assert_equal [ "completed", "success" ], [ deploy.reload.status, deploy.conclusion ]
  end

  test "runs on other branches are ignored" do
    stub_github_repo(@project, head: "c" * 40, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ] ] },
      runs: [ workflow_run(id: 78, head_branch: "feature") ])
    ProjectSyncJob.perform_now(@project)

    assert_empty Deploy.all
  end

  test "an unchanged repository is asked with ETags, and GitHub's 304 answers are used from cache" do
    with_cache do
      stub_github_repo(@project, runs: [])
      repo = "#{GitHubHelper::API}/repos/#{@project.repo_full_name}"
      stub_request(:get, "#{repo}/branches/main").to_return_json(body: { commit: { sha: "a" * 40 } }, headers: { "ETag" => %("head-1") })
      ProjectSyncJob.perform_now(@project)

      not_modified = stub_request(:get, "#{repo}/branches/main").with(headers: { "If-None-Match" => %("head-1") }).to_return(status: 304)
      assert_not @project.sync
      assert_requested not_modified
    end
  end

  private
    def workflow_run(id:, status: "completed", conclusion: nil, head_branch: "main", updated_at: Time.current)
      { id: id, path: ".github/workflows/meridian-deploy.yml", head_sha: "c" * 40, head_branch: head_branch, event: "push", status: status, conclusion: conclusion,
        display_title: "deploy(web): v42", html_url: "https://github.com/example/infra/actions/runs/#{id}",
        run_started_at: 5.minutes.ago.iso8601, updated_at: updated_at.iso8601 }
    end

    def with_cache
      cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = cache
    end
end
