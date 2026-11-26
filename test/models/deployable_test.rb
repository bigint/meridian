require "test_helper"

class DeployableTest < ActiveSupport::TestCase
  HISTORY = { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ], [ "b" * 40, "v41\n" ] ] }

  setup do
    @project = projects(:infra)
    stub_github_repo(@project, history: HISTORY)
    @project.sync
    @app = @project.apps.find_by!(service: "web", destination: "production")
    @actor = users(:deployer)
  end

  test "deploy commits the version file with the blob SHA it read and an actor trailer" do
    writes = stub_github_writes(@project)

    deploy = @app.deploy("v43", actor: @actor)

    write = writes.sole
    assert_equal "deploy/web.production.version", write["path"]
    assert_equal "v43\n", write["content"]
    assert_equal blob_sha("v42\n"), write["sha"], "stale writes must fail rather than overwrite"
    assert_equal "deploy(web-production): v43\n\nMeridian-Actor: Dee Deployer <dee@example.com>", write["message"]

    assert_equal [ "v43", "f" * 40, "deploy", "pending" ], [ deploy.version, deploy.commit_sha, deploy.kind, deploy.status ]
    assert_equal "app.deploy", Event.recent.first.action
  end

  test "a concurrent change in Git surfaces as a conflict" do
    stub_request(:put, %r{/contents/deploy/web.production.version}).to_return(status: 409, body: { message: "sha mismatch" }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises(GitHost::Conflict) { @app.deploy("v43", actor: @actor) }
    assert_empty @app.deploys
  end

  test "rejects versions that aren't one plain token" do
    assert_raises(ArgumentError) { @app.deploy("v1; rm -rf /", actor: @actor) }
    assert_raises(ArgumentError) { @app.deploy(" ", actor: @actor) }
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

  test "only the newest release can be rolled back" do
    assert_raises(ArgumentError) { @app.roll_back(@app.releases.last, actor: @actor) }
  end

  test "CI runs move deploys along" do
    @app.deploys.create!(version: "v42", commit_sha: "c" * 40)

    Deploy.from_workflow_run(@project, { "id" => 9, "head_sha" => "c" * 40, "status" => "in_progress", "html_url" => "https://github.com/example/infra/actions/runs/9" })
    assert_equal "in_progress", @app.current_deploy.status

    Deploy.from_workflow_run(@project, { "id" => 9, "head_sha" => "c" * 40, "status" => "completed", "conclusion" => "success", "updated_at" => Time.current.iso8601 })
    assert @app.current_deploy.reload.succeeded?
  end

  test "redeploys are tracked from dispatched runs named after the config" do
    run = { "id" => 31, "event" => "workflow_dispatch", "display_title" => "deploy deploy/web.yml production", "head_sha" => "c" * 40, "status" => "in_progress" }
    deploy = Deploy.from_dispatch(@project, run)

    assert_equal [ "web · production", "redeploy", "v42", "in_progress" ], [ deploy.app.name, deploy.kind, deploy.version, deploy.status ]
    assert_nil Deploy.from_dispatch(@project, run.merge("display_title" => "remove deploy/web.yml pr-3"))
    assert_nil Preview.track(run), "not a preview, so the redeploy path handles it"
  end
end
