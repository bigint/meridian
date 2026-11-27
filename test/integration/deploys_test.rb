require "test_helper"

# Deploys, rollbacks and redeploys from an app's page (AppScoped): each ends
# on the app's page, saying what happened or why it didn't.
class DeploysTest < ActionDispatch::IntegrationTest
  HISTORY = { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ], [ "b" * 40, "v41\n" ] ] }

  setup do
    @project = projects(:infra)
    stub_github_repo(@project, history: HISTORY)
    @project.sync
    @app = @project.apps.find_by!(service: "web", destination: "production")
    sign_in_as users(:ada)
  end

  test "a deploy commits the version and says CI will deploy it" do
    writes = stub_github_writes(@project)

    post app_deploys_path(@app), params: { deploy: { version: "v43" } }

    assert_redirected_to app_path(@app)
    assert_equal "Committed. CI will deploy it.", flash[:notice]
    assert_equal "v43\n", writes.sole["content"]
  end

  test "a refused deploy says why and commits nothing" do
    writes = stub_github_writes(@project)

    post app_deploys_path(@app), params: { deploy: { version: "--skip-hooks" } }

    assert_redirected_to app_path(@app)
    assert_match "Version must be an image tag", flash[:alert]
    assert_empty writes
  end

  test "a version file changed in Git since the page loaded re-reads the project" do
    stub_request(:put, %r{/contents/deploy/web.production.version}).to_return(status: 409,
      body: { message: "deploy/web.production.version does not match abc" }.to_json, headers: { "Content-Type" => "application/json" })

    assert_enqueued_with(job: ProjectSyncJob) do
      post app_deploys_path(@app), params: { deploy: { version: "v43" } }
    end

    assert_redirected_to app_path(@app)
    assert_match "The version file changed in Git since this page loaded", flash[:alert]
  end

  test "a commit GitHub refuses for a reason other than a stale SHA says why" do
    stub_request(:put, %r{/contents/deploy/web.production.version}).to_return(status: 409,
      body: { message: "Repository rule violations found\n\nChanges must be made through a pull request." }.to_json, headers: { "Content-Type" => "application/json" })

    post app_deploys_path(@app), params: { deploy: { version: "v43" } }

    assert_redirected_to app_path(@app)
    assert_match "GitHub refused", flash[:alert]
    assert_match "Changes must be made through a pull request", flash[:alert]
  end

  test "a rollback commits the version from before the newest release" do
    writes = stub_github_writes(@project)
    stub_github_commit(@project, "c" * 40, parent: "b" * 40)

    post app_rollbacks_path(@app, release_id: @app.latest_release.id)

    assert_redirected_to app_path(@app)
    assert_equal "Committed a revert to v41. CI will deploy it.", flash[:notice]
    assert_equal "v41\n", writes.sole["content"]
  end

  test "a redeploy asks CI to deploy the current version again" do
    dispatch = stub_request(:post, "https://api.github.com/repos/example/infra/actions/workflows/meridian-deploy.yml/dispatches")
      .with(body: hash_including(ref: "main", inputs: { config: "deploy/web.yml", destination: "production", version: "v42" }))
      .to_return(status: 204)

    post app_redeploy_path(@app)

    assert_redirected_to app_path(@app)
    assert_equal "Asked CI to deploy v42 again.", flash[:notice]
    assert_requested dispatch
    assert_equal "app.redeploy", Event.recent.first.action
  end
end
