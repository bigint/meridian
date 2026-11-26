# The one endpoint agents talk to. Validate, enqueue, return 202, fast.
class Agent::SnapshotsController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods

  MAX_BYTES = 1.megabyte

  before_action :authenticate
  # Per sender: a fleet token speaks for many servers, each of which may report.
  rate_limit to: 120, within: 1.minute, by: -> { [ @token.id, (sender if @token.fleet?) ].compact.join(":") },
    with: -> { head :too_many_requests }

  def create
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
    # Rails parses a JSON body before any callback runs (to wrap and log its
    # params), so an oversized body is turned away before that, token or not.
    def process_action(*)
      return head :content_too_large if request.content_length.to_i > MAX_BYTES
      super
    end

    def authenticate
      @token = authenticate_with_http_token { |token, _| AgentToken.authenticate(token) }
      head :unauthorized unless @token
    end

    # Already parsed by then, and at most MAX_BYTES.
    def sender
      request.request_parameters["machine_id"].to_s.first(128)
    rescue ActionDispatch::Http::Parameters::ParseError
      nil
    end
end
