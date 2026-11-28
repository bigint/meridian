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

  test "a deploy CI never picks up stops counting as under way, and says so" do
    deploy = @app.deploys.create!(version: "v43", commit_sha: "d" * 40)
    assert_includes Deploy.active, deploy
    assert_equal "Pending", deploy.state_label

    travel Deploy::UNCLAIMED_AFTER + 1.minute do
      assert_not_includes Deploy.active, deploy
      assert deploy.unclaimed?
      assert_equal "Not started by CI", deploy.state_label
    end
  end

  test "a deploy CI is running stays under way however long it takes" do
    deploy = @app.deploys.create!(version: "v43", commit_sha: "d" * 40)
    Deploy.from_workflow_run(@project, { "id" => 11, "head_sha" => "d" * 40, "status" => "in_progress" })

    travel 2.hours do
      assert_includes Deploy.active, deploy
      assert_not deploy.reload.unclaimed?
    end
  end

  test "a finished CI run goes into the activity trail once, and a re-run again" do
    @app.deploys.create!(version: "v42", commit_sha: "c" * 40, actor: users(:ada))
    run = { "id" => 9, "head_sha" => "c" * 40, "html_url" => "https://github.com/example/infra/actions/runs/9" }

    Deploy.from_workflow_run(@project, run.merge("status" => "in_progress", "updated_at" => 2.minutes.ago.iso8601))
    assert_no_difference -> { Event.count } do
      Deploy.from_workflow_run(@project, run.merge("status" => "in_progress", "updated_at" => 1.minute.ago.iso8601))
    end

    finished = run.merge("status" => "completed", "conclusion" => "failure", "updated_at" => Time.current.iso8601)
    assert_difference -> { Event.count }, 1 do
      2.times { Deploy.from_workflow_run(@project, finished) }
    end
    event = Event.recent.first
    assert_equal [ "app.deploy.failure", "Deploy of #{@app.name} at v42 failed", users(:ada).display_name, run["html_url"] ],
      [ event.action, event.summary, event.actor_name, event.details["ci_url"] ]

    travel 1.minute do
      assert_difference -> { Event.count }, 1 do
        Deploy.from_workflow_run(@project, run.merge("status" => "completed", "conclusion" => "success", "run_attempt" => 2, "updated_at" => Time.current.iso8601))
      end
      assert_equal "Deploy of #{@app.name} at v42 succeeded", Event.recent.first.summary
    end
  end

  test "a redeploy started outside Meridian says it came from Git" do
    run = { "id" => 21, "head_sha" => "e" * 40, "display_title" => "deploy #{@app.config_path} #{@app.destination}", "status" => "completed", "conclusion" => "success", "updated_at" => Time.current.iso8601 }

    Deploy.from_dispatch(@project, run)
    event = Event.recent.first
    assert_equal [ "app.redeploy.success", "Git" ], [ event.action, event.actor_name ]
    assert_match(/\ARedeploy of #{@app.name} at \S+ succeeded\z/, event.summary)
  end
end
