require "test_helper"

class GitHost::GitHubTest < ActiveSupport::TestCase
  # Links Meridian shows go to the GitHub that GITHUB_API_URL points at.
  {
    nil => "https://github.com",
    "https://api.github.com/" => "https://github.com",
    "https://github.example.com/api/v3/" => "https://github.example.com",
    "https://github.example.com:8443/api/v3" => "https://github.example.com:8443",
    "https://api.acme.ghe.com/" => "https://acme.ghe.com"
  }.each do |api, web|
    test "repository, commit and file links for #{api || "the default API"} go to #{web}" do
      with_env("GITHUB_API_URL" => api) do
        project = projects(:infra)
        assert_equal "#{web}/example/infra", project.repo_url
        assert_equal "#{web}/example/infra/commit/#{"a" * 40}", project.git.commit_url("a" * 40)
        assert_equal "#{web}/acme/shop/commit/#{"a" * 40}", project.git.commit_url("a" * 40, repo: "acme/shop")
        assert_equal "#{web}/example/infra/blob/main/deploy/web.yml", project.git.file_url("deploy/web.yml")
        assert_equal "#{web}/example/infra/blob/#{"b" * 40}/deploy/web.yml#L3", project.git.file_url("deploy/web.yml", ref: "b" * 40, line: 3)
      end
    end
  end

  test "a token stands in for the App: no installation token is requested" do
    with_env("GITHUB_APP_ID" => nil, "GITHUB_APP_PRIVATE_KEY" => nil, "GITHUB_TOKEN" => "ghp_test") do
      project = projects(:infra)
      project.installation_id = nil
      branch = stub_request(:get, "https://api.github.com/repos/example/infra/branches/main")
        .with(headers: { "Authorization" => "token ghp_test" })
        .to_return_json(body: { commit: { sha: "a" * 40 } })

      assert GitHost::GitHub.token_mode?
      assert_equal "a" * 40, project.git.head_sha
      assert_requested branch
      assert_not_requested :post, %r{/access_tokens}
    end
  end

  test "an App wins when both are set" do
    with_env("GITHUB_TOKEN" => "ghp_test") { assert_not GitHost::GitHub.token_mode? }
  end

  test "a dispatch to a workflow GitHub doesn't have raises instead of answering false, so a redeploy that ran nothing isn't recorded" do
    project = projects(:infra)
    stub_github_repo(project)
    stub_request(:post, %r{/actions/workflows/meridian-deploy.yml/dispatches}).to_return(status: 404, body: "{}", headers: { "Content-Type" => "application/json" })

    error = assert_raises(GitHost::NotFound) { project.git.dispatch_workflow("meridian-deploy.yml", inputs: { config: "deploy/web.yml", version: "v1" }) }
    assert_equal "example/infra has no meridian-deploy.yml workflow on main: add the CI workflow first", error.message

    project.sync
    assert_raises(GitHost::NotFound) { project.apps.find_by!(service: "web", destination: "production").redeploy(actor: users(:ada)) }
    assert_not Event.exists?(action: "app.redeploy")
  end
end
