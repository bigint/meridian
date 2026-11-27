require "test_helper"

class DeployableTest < ActiveSupport::TestCase
  HISTORY = { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ], [ "b" * 40, "v41\n" ] ] }

  setup do
    @project = projects(:infra)
    stub_github_repo(@project, history: HISTORY)
    @project.sync
    @app = @project.apps.find_by!(service: "web", destination: "production")
    @actor = users(:ada)
  end

  test "deploy commits the version file with the blob SHA it read and an actor trailer" do
    writes = stub_github_writes(@project)

    deploy = @app.deploy("v43", actor: @actor)

    write = writes.sole
    assert_equal "deploy/web.production.version", write["path"]
    assert_equal "v43\n", write["content"]
    assert_equal blob_sha("v42\n"), write["sha"], "stale writes must fail rather than overwrite"
    assert_equal "deploy(web-production): v43\n\nMeridian-Actor: Ada Lovelace <ada@example.com>", write["message"]

    assert_equal [ "v43", "f" * 40, "deploy", "pending" ], [ deploy.version, deploy.commit_sha, deploy.kind, deploy.status ]
    assert_equal "app.deploy", Event.recent.first.action
  end

  test "deploying the version already in the file commits nothing" do
    writes = stub_github_writes(@project)

    error = assert_raises(App::Refused) { @app.deploy("v42", actor: @actor) }
    assert_match "Redeploy", error.message
    assert_empty writes
    assert_empty @app.deploys
  end

  test "an accessories-only config is never deployed, rolled back or redeployed" do
    @app.update!(kind: App::ACCESSORIES)
    writes = stub_github_writes(@project)

    assert_raises(App::Refused) { @app.deploy("v43", actor: @actor) }
    assert_raises(App::Refused) { @app.roll_back(@app.latest_release, actor: @actor) }
    assert_raises(App::Refused) { @app.redeploy(actor: @actor) }
    assert_empty writes
    assert_not_requested :post, %r{/dispatches}
  end

  test "a concurrent change in Git surfaces as a conflict" do
    stub_request(:put, %r{/contents/deploy/web.production.version}).to_return(status: 409, body: { message: "deploy/web.production.version does not match #{blob_sha("v42\n")}" }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises(GitHost::Conflict) { @app.deploy("v43", actor: @actor) }
    assert_empty @app.deploys
  end

  test "rejects versions that aren't one plain token" do
    assert_raises(App::Refused) { @app.deploy("v1; rm -rf /", actor: @actor) }
    assert_raises(App::Refused) { @app.deploy(" ", actor: @actor) }
    assert_raises(App::Refused, "CI would pass it to Kamal as a flag") { @app.deploy("--skip-hooks", actor: @actor) }
    assert_raises(App::Refused, "not valid in a container name") { @app.deploy("v1@sha256:abc", actor: @actor) }
  end

  test "roll back restores the version file from before the newest release" do
    writes = stub_github_writes(@project, commit: "r" * 40)
    stub_github_commit(@project, "c" * 40, parent: "b" * 40)

    deploy = @app.roll_back(@app.latest_release, actor: @actor)

    write = writes.sole
    assert_equal "v41\n", write["content"]
    assert_match "rollback(web-production): v41", write["message"]
    assert_match "This reverts commit #{"c" * 40}.", write["message"]
    assert_equal "rollback", deploy.kind
  end

  test "rolling back a release Git has moved past is a conflict, not a revert of the newer change" do
    newer = "d" * 40
    stub_request(:get, %r{/repos/example/infra/commits\?}).to_return_json(body: [ { sha: newer, commit: { message: "deploy v43", author: { name: "Ada", date: Time.current.iso8601 } } } ])
    writes = stub_github_writes(@project)

    assert_raises(GitHost::Conflict) { @app.roll_back(@app.latest_release, actor: @actor) }
    assert_empty writes
  end

  test "rolling back the commit that created the version file says there is nothing to go back to" do
    stub_github_commit(@project, "c" * 40, parent: "0" * 40)
    stub_request(:get, %r{/contents/deploy/web.production.version\?ref=0{40}}).to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

    error = assert_raises(App::Refused) { @app.roll_back(@app.latest_release, actor: @actor) }
    assert_match "didn't exist before cccccc", error.message
  end

  test "only the newest release can be rolled back" do
    assert_raises(App::Refused) { @app.roll_back(@app.releases.last, actor: @actor) }
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

  test "a redeploy at another app's deploy commit keeps its own run" do
    stub_github_writes(@project, commit: "d" * 40)
    @app.deploy("v43", actor: @actor)
    blog = @project.apps.find_by!(service: "blog")

    Deploy.from_dispatch(@project, { "id" => 50, "event" => "workflow_dispatch", "display_title" => "deploy deploy/blog.yml ", "head_sha" => "d" * 40,
      "status" => "completed", "conclusion" => "failure", "updated_at" => 1.minute.ago.iso8601 })
    Deploy.from_workflow_run(@project, { "id" => 49, "head_sha" => "d" * 40, "status" => "completed", "conclusion" => "success", "updated_at" => Time.current.iso8601 })

    assert_equal [ 50, "failure" ], [ blog.current_deploy.ci_run_id, blog.current_deploy.conclusion ]
    assert_equal [ 49, "success" ], [ @app.current_deploy.ci_run_id, @app.current_deploy.conclusion ]
  end

  test "redeploy dispatches the version in the file now, not the last synced one" do
    stub_request(:get, "#{GitHubHelper::API}/repos/example/infra/contents/deploy/web.production.version?ref=main")
      .to_return_json(body: { content: Base64.encode64("v43\n"), sha: blob_sha("v43\n"), encoding: "base64" })
    dispatch = stub_request(:post, %r{/actions/workflows/meridian-deploy.yml/dispatches}).with(body: hash_including(inputs: hash_including(version: "v43"))).to_return(status: 204)

    assert_equal "v43", @app.redeploy(actor: @actor)
    assert_requested dispatch
  end

  test "a redeploy is recorded with the version it dispatched, which its run keeps" do
    stub_request(:get, "#{GitHubHelper::API}/repos/example/infra/contents/deploy/web.production.version?ref=main")
      .to_return_json(body: { content: Base64.encode64("v43\n"), sha: blob_sha("v43\n"), encoding: "base64" })
    stub_request(:post, %r{/actions/workflows/meridian-deploy.yml/dispatches}).to_return(status: 204)

    @app.redeploy(actor: @actor)
    deploy = @app.current_deploy
    assert_equal [ "redeploy", "v43", "a" * 40, @actor ], [ deploy.kind, deploy.version, deploy.commit_sha, deploy.actor ]

    Deploy.from_dispatch(@project, { "id" => 60, "event" => "workflow_dispatch", "display_title" => "deploy deploy/web.yml production", "head_sha" => "a" * 40, "status" => "queued" })
    assert_equal [ deploy, "v43", 60 ], [ @app.reload.current_deploy, deploy.reload.version, deploy.ci_run_id ], "not the v42 release Meridian last synced"
  end

  test "an app without a version file has nothing to redeploy" do
    blog = @project.apps.find_by!(service: "blog")

    error = assert_raises(App::Refused) { blog.redeploy(actor: @actor) }
    assert_match "no version file", error.message
    assert_not_requested :post, %r{/dispatches}
  end

  test "redeploys are tracked from dispatched runs named after the config" do
    run = { "id" => 31, "event" => "workflow_dispatch", "display_title" => "deploy deploy/web.yml production", "head_sha" => "c" * 40, "status" => "in_progress" }
    deploy = Deploy.from_dispatch(@project, run)

    assert_equal [ "web · production", "redeploy", "v42", "in_progress" ], [ deploy.app.name, deploy.kind, deploy.version, deploy.status ]
    assert_nil Deploy.from_dispatch(@project, run.merge("display_title" => "remove deploy/web.yml pr-3"))
  end
end
