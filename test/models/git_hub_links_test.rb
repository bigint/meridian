require "test_helper"

# Links Meridian shows go to the GitHub that GITHUB_API_URL points at.
class GitHubLinksTest < ActiveSupport::TestCase
  {
    nil => "https://github.com",
    "https://api.github.com/" => "https://github.com",
    "https://github.example.com/api/v3/" => "https://github.example.com",
    "https://github.example.com:8443/api/v3" => "https://github.example.com:8443",
    "https://api.acme.ghe.com/" => "https://acme.ghe.com"
  }.each do |api, web|
    test "repository and commit links for #{api || "the default API"} go to #{web}" do
      with_env("GITHUB_API_URL" => api) do
        project = projects(:infra)
        assert_equal "#{web}/example/infra", project.repo_url
        assert_equal "#{web}/example/infra/commit/#{"a" * 40}", project.git.commit_url("a" * 40)
      end
    end
  end
end
