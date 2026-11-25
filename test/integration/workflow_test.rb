require "test_helper"

class WorkflowTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    sign_in_as users(:admin)
  end

  test "adding the CI workflow opens a pull request" do
    ref = stub_request(:post, "https://api.github.com/repos/example/infra/git/refs").to_return_json(status: 201, body: { ref: "refs/heads/x" })
    writes = stub_github_writes(@project)
    pull = stub_request(:post, "https://api.github.com/repos/example/infra/pulls").to_return_json(status: 201, body: { number: 5, html_url: "https://github.com/example/infra/pull/5" })

    post project_workflow_path(@project)

    assert_redirected_to project_path(@project)
    assert_requested ref
    assert_requested pull
    write = writes.sole
    assert_equal ".github/workflows/meridian-deploy.yml", write["path"]
    assert_match %r{\Ameridian/ci-}, write["branch"]
    assert_match "kamal deploy", write["content"]
    assert_match "gem install kamal -v 2.12.0", write["content"]
  end

  test "projects that allow direct commits get a commit instead" do
    @project.update!(direct_commits: true)
    writes = stub_github_writes(@project)

    post project_workflow_path(@project)
    assert_equal "main", writes.sole["branch"]
  end

  test "viewers can't deploy" do
    sign_in_as users(:viewer)
    stub_github_repo(@project)
    @project.sync
    app = @project.apps.first

    post app_deploys_path(app), params: { deploy: { version: "v9" } }
    assert_redirected_to root_path
    assert_not_requested :put, %r{/contents/}
  end
end
