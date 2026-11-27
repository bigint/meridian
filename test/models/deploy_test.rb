require "test_helper"

# CI's workflow runs move a deploy along: Deploy.from_workflow_run.
class DeployTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
    @app = @project.apps.find_by!(service: "web", destination: "production")
  end

  test "CI runs move deploys along" do
    @app.deploys.create!(version: "v42", commit_sha: "c" * 40)

    Deploy.from_workflow_run(@project, { "id" => 9, "head_sha" => "c" * 40, "status" => "in_progress", "html_url" => "https://github.com/example/infra/actions/runs/9" })
    assert_equal "in_progress", @app.current_deploy.status

    Deploy.from_workflow_run(@project, { "id" => 9, "head_sha" => "c" * 40, "status" => "completed", "conclusion" => "success", "updated_at" => Time.current.iso8601 })
    assert @app.current_deploy.reload.succeeded?
  end

  test "a late or replayed run event never moves a deploy back, but a re-run does" do
    deploy = @app.deploys.create!(version: "v42", commit_sha: "c" * 40)
    run = { "id" => 9, "head_sha" => "c" * 40 }

    Deploy.from_workflow_run(@project, run.merge("status" => "completed", "conclusion" => "success", "updated_at" => 1.minute.ago.iso8601))
    Deploy.from_workflow_run(@project, run.merge("status" => "in_progress", "updated_at" => 3.minutes.ago.iso8601))
    assert_equal [ "completed", "success" ], [ deploy.reload.status, deploy.conclusion ]

    Deploy.from_workflow_run(@project, run.merge("status" => "queued", "run_attempt" => 2, "updated_at" => Time.current.iso8601))
    assert_equal [ "queued", nil ], [ deploy.reload.status, deploy.conclusion ]
  end

  test "an older run never takes a deploy over from a newer one" do
    deploy = @app.deploys.create!(version: "v42", commit_sha: "c" * 40)

    Deploy.from_workflow_run(@project, { "id" => 12, "head_sha" => "c" * 40, "status" => "completed", "conclusion" => "success", "updated_at" => 2.minutes.ago.iso8601 })
    Deploy.from_workflow_run(@project, { "id" => 11, "head_sha" => "c" * 40, "status" => "completed", "conclusion" => "failure", "updated_at" => 1.minute.ago.iso8601 })
    assert_equal [ 12, "success" ], [ deploy.reload.ci_run_id, deploy.conclusion ]
  end
end
