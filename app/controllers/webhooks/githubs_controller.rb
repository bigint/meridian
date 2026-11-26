# GitHub App webhooks. Verified with the App's webhook secret, then handed to
# a job so GitHub gets its answer quickly.
class Webhooks::GithubsController < ActionController::API
  EVENTS = %w[ push workflow_run ].freeze

  before_action :verify_signature

  def create
    event = request.headers["X-GitHub-Event"].to_s
    GitHubEventJob.perform_later(event, JSON.parse(request.raw_post)) if EVENTS.include?(event)
    head :accepted
  rescue JSON::ParserError
    head :bad_request
  end

  private
    def verify_signature
      secret = GitHost::GitHub.webhook_secret
      expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, request.raw_post)
      head :unauthorized unless secret.present? && ActiveSupport::SecurityUtils.secure_compare(expected, request.headers["X-Hub-Signature-256"].to_s)
    end
end
