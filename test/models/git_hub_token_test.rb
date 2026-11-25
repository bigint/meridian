require "test_helper"

class GitHubTokenTest < ActiveSupport::TestCase
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

  private
    def with_env(values)
      original = values.keys.to_h { [ it, ENV[it] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      original.each { |key, value| ENV[key] = value }
    end
end
