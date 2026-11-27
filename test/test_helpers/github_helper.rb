require "webmock/minitest"

# Serves a directory as a GitHub repository through WebMock, so sync runs the
# real Octokit + Kamal code paths against fixture files.
module GitHubHelper
  API = "https://api.github.com"
  INFRA = Rails.root.join("test/fixtures/files/infra")

  def stub_github_repo(project, head: "a" * 40, history: {}, files: {}, runs: [])
    stub_github_files(project, infra_files.merge(files), head: head, history: history)
    stub_github_runs(project, runs)
  end

  # The fixture infra repository's files by path, leaving out those in except.
  def infra_files(except: [])
    Dir.glob("**/*", File::FNM_DOTMATCH, base: INFRA).select { File.file?(INFRA.join(it)) }.excluding(except).index_with { File.read(INFRA.join(it)) }
  end

  # The repository's recent workflow runs, as GitHub lists them.
  def stub_github_runs(project, runs)
    stub_request(:get, %r{\A#{Regexp.escape(API)}/repos/#{project.repo_full_name}/actions/runs\?})
      .to_return_json(body: { total_count: runs.size, workflow_runs: runs })
  end

  # history: { "deploy/web.production.version" => [ ["sha1", "v41\n"], ["sha2", "v40\n"] ] }
  def stub_github_files(project, files, head: "a" * 40, history: {})
    repo = "#{API}/repos/#{project.repo_full_name}"
    stub_installation_token(project)

    stub_request(:get, "#{repo}/branches/#{project.default_branch}").to_return_json(body: { name: project.default_branch, commit: { sha: head } })

    tree = files.map { |path, content| { path: path, type: "blob", mode: "100644", sha: blob_sha(content), size: content.bytesize } }
    stub_request(:get, "#{repo}/git/trees/#{head}?recursive=true").to_return_json(body: { sha: head, tree: tree, truncated: false })

    files.each_value do |content|
      stub_request(:get, "#{repo}/git/blobs/#{blob_sha(content)}").to_return_json(body: { content: Base64.encode64(content), encoding: "base64" })
    end

    stub_request(:get, %r{\A#{Regexp.escape(repo)}/commits\?}).to_return do |request|
      path = Rack::Utils.parse_query(URI(request.uri).query)["path"]
      commits = history.fetch(path) { [ [ Digest::SHA1.hexdigest("#{head}#{path}"), files[path] ] ] }
      json_response(commits.each_with_index.map { |(sha, _), index| commit_json(sha, path, index) })
    end

    stub_request(:get, %r{\A#{Regexp.escape(repo)}/contents/}).to_return do |request|
      uri = URI(request.uri)
      path = uri.path.delete_prefix(URI(repo).path + "/contents/")
      ref = Rack::Utils.parse_query(uri.query)["ref"]
      content = Array(history[path]).to_h[ref] || files[path]
      content ? json_response(content: Base64.encode64(content), sha: blob_sha(content), path: path, encoding: "base64") : { status: 404, body: "{}", headers: { "Content-Type" => "application/json" } }
    end
  end

  def stub_github_commit(project, sha, parent:)
    stub_request(:get, "#{API}/repos/#{project.repo_full_name}/commits/#{sha}").to_return_json(body: { sha: sha, parents: [ { sha: parent } ] })
  end

  # Records every contents PUT and answers with a new commit SHA.
  def stub_github_writes(project, commit: "f" * 40)
    writes = []
    stub_request(:put, %r{\A#{Regexp.escape(API)}/repos/#{project.repo_full_name}/contents/}).to_return do |request|
      body = JSON.parse(request.body)
      writes << body.merge("path" => URI(request.uri).path.split("/contents/", 2).last, "content" => Base64.decode64(body["content"]))
      json_response(content: { sha: "1" * 40 }, commit: { sha: commit })
    end
    writes
  end

  def stub_installation_token(project)
    stub_request(:post, "#{API}/app/installations/#{project.installation_id}/access_tokens")
      .to_return_json(status: 201, body: { token: "ghs_test", expires_at: 1.hour.from_now.iso8601 })
  end

  def blob_sha(content)
    Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
  end

  private
    def commit_json(sha, path, index)
      { sha: sha, commit: { message: "Change #{path}\n\nDetails", author: { name: "Ada Example", email: "ada@example.com", date: (index + 1).hours.ago.iso8601 } } }
    end

    def json_response(body)
      { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
    end
end
