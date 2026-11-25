# GitHub through a GitHub App installation. Every call is made as the
# installation, so Meridian only ever has the access the App was granted.
class GitHost::GitHub
  TOKENS = Concurrent::Map.new

  class << self
    def app_id = setting(:app_id)
    def private_key = setting(:private_key)&.gsub("\\n", "\n")
    def webhook_secret = setting(:webhook_secret)
    def api_endpoint = ENV.fetch("GITHUB_API_URL", "https://api.github.com/")
    def configured? = app_id.present? && private_key.present?

    private
      def setting(name)
        ENV["GITHUB_APP_#{name.upcase}"].presence || Rails.application.credentials.dig(:github, name)
      end
  end

  attr_reader :project

  def initialize(project)
    @project = project
  end

  def head_sha(branch = project.default_branch)
    request { client.branch(repo, branch).commit.sha }
  end

  def tree(sha)
    request { client.tree(repo, sha, recursive: true).tree.select { it.type == "blob" }.map { GitHost::Entry.new(path: it.path, sha: it.sha) } }
  end

  def blob(sha)
    request { Base64.decode64(client.blob(repo, sha).content).force_encoding(Encoding::UTF_8) }
  end

  def commits(path:, ref: project.default_branch, limit: 20)
    request do
      client.commits(repo, ref, path: path, per_page: limit).map do |commit|
        GitHost::Commit.new(sha: commit.sha, author: commit.commit.author.name, committed_at: commit.commit.author.date, message: commit.commit.message)
      end
    end
  end

  def file(path, ref: project.default_branch)
    request do
      content = client.contents(repo, path: path, ref: ref)
      GitHost::Content.new(path: path, content: Base64.decode64(content.content).force_encoding(Encoding::UTF_8), sha: content.sha)
    end
  end

  # Writes one file with the contents API. Passing the blob SHA that was read
  # makes a stale write fail instead of overwriting someone else's change.
  def write_file(path, content:, message:, sha: nil, branch: project.default_branch)
    options = { branch: branch, sha: sha }.compact
    request { client.create_contents(repo, path, message, content, **options).commit.sha }
  end

  def delete_file(path, sha:, message:, branch: project.default_branch)
    request { client.delete_contents(repo, path, message, sha, branch: branch) }
  end

  def parent_sha(sha)
    request { client.commit(repo, sha).parents.first&.sha }
  end

  def create_branch(name, from:)
    request { client.create_ref(repo, "heads/#{name}", from) }
  end

  # Returns [number, url].
  def create_pull_request(head:, title:, body:, base: project.default_branch)
    request do
      pull = client.create_pull_request(repo, base, head, title, body)
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

  def dispatch_workflow(workflow, inputs:, ref: project.default_branch)
    request { client.workflow_dispatch(repo, workflow, ref, inputs: inputs) }
  end

  def commit_url(sha) = "https://github.com/#{repo}/commit/#{sha}"

  private
    def repo = project.repo_full_name

    def request
      yield
    rescue Octokit::Conflict, Octokit::UnprocessableEntity => error
      raise GitHost::Conflict, error.message
    rescue Octokit::NotFound => error
      raise GitHost::NotFound, error.message
    rescue Octokit::Error, Faraday::Error => error
      raise GitHost::Error, error.message
    end

    def client
      @client ||= Octokit::Client.new(access_token: installation_token, api_endpoint: self.class.api_endpoint, auto_paginate: false)
    end

    def installation_token
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
