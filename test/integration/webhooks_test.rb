require "test_helper"

class WebhooksTest < ActionDispatch::IntegrationTest
  setup { @project = projects(:infra) }

  test "rejects unsigned and wrongly signed deliveries" do
    post webhooks_github_path, params: "{}", headers: { "X-GitHub-Event" => "push" }
    assert_response :unauthorized

    github_webhook "push", { repository: { full_name: "example/infra" } }, secret: "wrong"
    assert_response :unauthorized
  end

  test "a push to the default branch syncs the project" do
    stub_github_repo(@project)

    perform_enqueued_jobs do
      github_webhook "push", { ref: "refs/heads/main", repository: { full_name: "example/infra" } }
    end

    assert_response :accepted
    assert_equal "a" * 40, @project.reload.last_synced_sha
  end

  test "webhooks find the project whatever the case of its name" do
    @project.update!(repo_full_name: "Example/Infra")
    stub_github_repo(@project)

    perform_enqueued_jobs do
      github_webhook "push", { ref: "refs/heads/main", repository: { full_name: "example/infra" } }
    end

    assert_equal "a" * 40, @project.reload.last_synced_sha
  end

  test "workflow runs create deploys for the apps a commit released" do
    stub_github_repo(@project, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ] ] })

    perform_enqueued_jobs do
      github_webhook "workflow_run", { repository: { full_name: "example/infra" },
        workflow_run: { id: 77, path: ".github/workflows/meridian-deploy.yml", head_sha: "c" * 40, head_branch: "main", status: "queued", html_url: "https://github.com/example/infra/actions/runs/77" } }
    end

    deploy = Deploy.sole
    assert_equal [ "web · production", "v42", 77, "queued" ], [ deploy.app.name, deploy.version, deploy.ci_run_id, deploy.status ]
  end

  test "runs of other workflows at the same commit leave deploys alone" do
    stub_github_repo(@project, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ] ] })
    run = { id: 77, path: ".github/workflows/meridian-deploy.yml", head_sha: "c" * 40, head_branch: "main", event: "push",
      status: "completed", conclusion: "failure", html_url: "https://github.com/example/infra/actions/runs/77" }

    perform_enqueued_jobs do
      github_webhook "workflow_run", { repository: { full_name: "example/infra" }, workflow_run: run }
      github_webhook "workflow_run", { repository: { full_name: "example/infra" }, workflow_run: run.merge(id: 78, path: ".github/workflows/lint.yml", conclusion: "success") }
      github_webhook "workflow_run", { repository: { full_name: "example/infra" },
        workflow_run: run.merge(id: 79, path: ".github/workflows/lint.yml", head_sha: @project.apps.find_by!(service: "blog").latest_release.commit_sha) }
    end

    deploy = Deploy.sole
    assert_equal [ "web · production", 77, "failure" ], [ deploy.app.name, deploy.ci_run_id, deploy.conclusion ]
  end
end
