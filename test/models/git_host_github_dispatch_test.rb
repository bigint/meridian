require "test_helper"

class GitHostGitHubDispatchTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    stub_request(:post, %r{/actions/workflows/meridian-deploy.yml/dispatches}).to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })
  end

  test "a dispatch to a workflow GitHub doesn't have raises instead of answering false" do
    error = assert_raises(GitHost::NotFound) { @project.git.dispatch_workflow("meridian-deploy.yml", inputs: { command: "deploy" }) }
    assert_equal "example/infra has no meridian-deploy.yml workflow on main: add the CI workflow first", error.message
  end

  test "so a redeploy that ran nothing isn't recorded as one" do
    @project.sync
    app = @project.apps.find_by!(service: "web", destination: "production")

    assert_raises(GitHost::NotFound) { app.redeploy(actor: users(:ada)) }
    assert_not Event.exists?(action: "app.redeploy")
  end
end
