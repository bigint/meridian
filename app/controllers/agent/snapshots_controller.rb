# The one endpoint agents talk to. Validate, enqueue, return 202, fast.
class Agent::SnapshotsController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods

  MAX_BYTES = 1.megabyte

  before_action :authenticate
  # Per sender: a fleet token speaks for many servers, each of which may report.
  # Retry-After is the whole window, the longest the limit can still hold;
  # the agent waits at least that long instead of backing off blindly.
  RATE_WINDOW = 1.minute
  rate_limit to: 120, within: RATE_WINDOW, by: -> { [ @token.id, (sender if @token.fleet?) ].compact.join(":") },
    with: -> { too_many_requests }
  # The sender is whatever machine id the body says, so a fleet token also has
  # a ceiling of its own: 3,000 servers at the default 15 seconds.
  FLEET_CEILING = 12_000
  rate_limit to: FLEET_CEILING, within: RATE_WINDOW, by: -> { @token.id }, name: "fleet", if: -> { @token.fleet? },
    with: -> { too_many_requests }

  def create
    snapshot = Snapshot.new(JSON.parse(request.raw_post.byteslice(0, MAX_BYTES + 1)), token: @token)
    if snapshot.valid?
      snapshot.ingest_later
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

    def too_many_requests
      response.set_header("Retry-After", RATE_WINDOW.to_i.to_s)
      head :too_many_requests
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
