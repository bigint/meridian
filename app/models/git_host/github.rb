# GitHub through a GitHub App installation, so Meridian only ever has the
# access the App was granted. For homelabs and local development a token
# (GITHUB_TOKEN, a fine-grained or classic personal access token) can stand
# in for the App; then every call is made as that token's owner.
class GitHost::GitHub
  TOKENS = Concurrent::Map.new

  # GitHub answers a write whose blob SHA is stale with "<path> does not
  # match <sha>", or '"sha" wasn't supplied' when the file appeared since it
  # was read. Other 409s and 422s, such as branch protection or repository
  # rules, are refusals the user has to see, not races to retry.
  STALE = /does not match|"sha" wasn't supplied/

  class << self
    def app_id = setting(:app_id, "GITHUB_APP_ID")
    def private_key = setting(:private_key, "GITHUB_APP_PRIVATE_KEY")&.gsub("\\n", "\n")
    def api_endpoint = ENV.fetch("GITHUB_API_URL", "https://api.github.com/")

    # Where people browse that API's repositories: api.github.com and
    # api.<name>.ghe.com drop the "api.", and Enterprise Server drops /api/v3.
    def web_url
      uri = URI(api_endpoint)
      uri.host = uri.host.delete_prefix("api.")
      uri.path, uri.query, uri.fragment = "", nil, nil
      uri.to_s
    end
    def token = ENV["GITHUB_TOKEN"].presence || Rails.application.credentials.dig(:github, :token)
    def token_mode? = token.present? && !(app_id.present? && private_key.present?)
    def configured? = (app_id.present? && private_key.present?) || token.present?

    private
      def setting(name, env)
        ENV[env].presence || Rails.application.credentials.dig(:github, name)
      end
  end

  attr_reader :project

  def initialize(project)
    @project = project
  end

  def head_sha
    conditional("branches/#{project.default_branch}", ->(data) { data.commit.sha }) { client.branch(repo, project.default_branch, headers: it) }
  end

  # The branch's latest workflow runs, newest first, in GitHub's workflow_run shape.
  def workflow_runs
    conditional("runs/#{project.default_branch}", ->(data) { data.workflow_runs.map { it.to_attrs.deep_stringify_keys } }) do
      client.repository_workflow_runs(repo, branch: project.default_branch, per_page: 20, headers: it)
    end
  end

  # Every file at the commit. GitHub cuts a very large tree short and says
  # so; read as whole, it would look as if the missing configs were deleted.
  def tree(sha)
    request do
      tree = client.tree(repo, sha, recursive: true)
      raise GitHost::Error, "GitHub truncated the tree of #{sha.first(7)}: the repository has too many files to read" if tree.truncated

      tree.tree.select { it.type == "blob" }.map { GitHost::Entry.new(path: it.path, sha: it.sha) }
    end
  end

  def blob(sha)
    request { Base64.decode64(client.blob(repo, sha).content).force_encoding(Encoding::UTF_8) }
  end

  def commits(path:, limit: 20)
    request do
      # The committer date says when a commit landed on the branch, as the
      # API orders them. The author date says when it was written, which a
      # rebased or merged pull request carries over from days before.
      client.commits(repo, project.default_branch, path: path, per_page: limit).map do |commit|
        landed = commit.commit.committer&.date || commit.commit.author.date
        GitHost::Commit.new(sha: commit.sha, author: commit.commit.author.name, committed_at: landed, message: commit.commit.message)
      end
    end
  end

  def file(path, ref: project.default_branch)
    request do
      content = client.contents(repo, path: path, ref: ref)
      GitHost::Content.new(path: path, content: Base64.decode64(content.content).force_encoding(Encoding::UTF_8), sha: content.sha)
    end
  end

  def file_or_nil(path, ref: project.default_branch)
    file(path, ref: ref)
  rescue GitHost::NotFound
    nil
  end

  # Writes one file with the contents API. Passing the blob SHA that was read
  # makes a stale write fail instead of overwriting someone else's change.
  def write_file(path, content:, message:, sha: nil, branch: project.default_branch)
    options = { branch: branch, sha: sha }.compact
    request { client.create_contents(repo, path, message, content, **options).commit.sha }
  end

  def parent_sha(sha)
    request { client.commit(repo, sha).parents.first&.sha }
  end

  def create_branch(name, from:)
    request { client.create_ref(repo, "heads/#{name}", from) }
  end

  # Returns [number, url].
  def create_pull_request(head:, title:, body:)
    request do
      pull = client.create_pull_request(repo, project.default_branch, head, title, body)
      [ pull.number, pull.html_url ]
    end
  end

  # Seals the value with the repository's public key and stores it as an
  # Actions secret. The plaintext never leaves this method.
  def put_secret(name, value)
    request do
      key = client.get_actions_public_key(repo)
      sealed = RbNaCl::Boxes::Sealed.from_public_key(Base64.decode64(key.key)).encrypt(value)
      client.create_or_update_actions_secret(repo, name, encrypted_value: Base64.strict_encode64(sealed), key_id: key.key_id)
    end
  end

  # Octokit answers a 404 (no such workflow on that branch yet) with false
  # rather than an error, so nothing would run and nobody would know.
  def dispatch_workflow(workflow, inputs:)
    request do
      client.workflow_dispatch(repo, workflow, project.default_branch, inputs: inputs) or raise GitHost::NotFound, "#{repo} has no #{workflow} workflow on #{project.default_branch}: add the CI workflow first"
    end
  end

  def repo_url = "#{self.class.web_url}/#{repo}"
  def commit_url(sha) = "#{repo_url}/commit/#{sha}"
  def file_url(path, ref: project.default_branch, line: nil) = "#{repo_url}/blob/#{ref}/#{path}#{"#L#{line}" if line}"

  private
    def repo = project.repo_full_name

    def request
      yield
    rescue Octokit::Conflict, Octokit::UnprocessableEntity => error
      raise (error.message.match?(STALE) ? GitHost::Conflict : GitHost::Error), error.message
    rescue Octokit::NotFound => error
      raise GitHost::NotFound, error.message
    rescue Octokit::Error, Faraday::Error => error
      raise GitHost::Error, error.message
    end

    # Sent with the last answer's ETag, a GET that finds nothing changed gets a
    # 304, which costs no rate limit, and the value comes from the cache.
    def conditional(name, value)
      key = [ "github", repo, name ]
      cached = Rails.cache.read(key)
      data = request { yield(cached ? { "If-None-Match" => cached[:etag] } : {}) }
      return cached[:value] if cached && client.last_response.status == 304

      value.(data).tap do |fresh|
        etag = client.last_response.headers["etag"]
        Rails.cache.write(key, { etag: etag, value: fresh }) if etag
      end
    end

    def client
      @client ||= Octokit::Client.new(access_token: installation_token, api_endpoint: self.class.api_endpoint, auto_paginate: false)
    end

    def installation_token
      return self.class.token if self.class.token_mode?
      raise GitHost::Error, "GitHub isn't connected: set GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY, or GITHUB_TOKEN" unless self.class.configured?

      cached = TOKENS[project.installation_id]
      return cached[:token] if cached && cached[:expires_at] > 5.minutes.from_now

      app = Octokit::Client.new(bearer_token: app_jwt, api_endpoint: self.class.api_endpoint)
      response = app.create_app_installation_access_token(project.installation_id)
      TOKENS[project.installation_id] = { token: response.token, expires_at: response.expires_at }
      response.token
    end

    def app_jwt
      key = OpenSSL::PKey::RSA.new(self.class.private_key)
      JWT.encode({ iat: Time.now.to_i - 60, exp: Time.now.to_i + 9.minutes.to_i, iss: self.class.app_id }, key, "RS256")
    end
end
