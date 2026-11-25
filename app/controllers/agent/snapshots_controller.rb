# The one endpoint agents talk to. Validate, enqueue, return 202, fast.
class Agent::SnapshotsController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods

  MAX_BYTES = 1.megabyte

  before_action :authenticate
  rate_limit to: 120, within: 1.minute, by: -> { @token.id }, with: -> { head :too_many_requests }

  def create
    return head :content_too_large if request.content_length.to_i > MAX_BYTES

    snapshot = Snapshot.new(JSON.parse(request.raw_post.byteslice(0, MAX_BYTES + 1)), token: @token)
    if snapshot.valid?
      SnapshotIngestJob.perform_later(@token, snapshot.to_job)
      head :accepted
    else
      render json: { errors: snapshot.errors.full_messages }, status: :unprocessable_entity
    end
  rescue JSON::ParserError
    render json: { errors: [ "Body must be JSON" ] }, status: :bad_request
  end

  private
    def authenticate
      @token = authenticate_with_http_token { |token, _| AgentToken.authenticate(token) }
      head :unauthorized unless @token
    end
end
