require "test_helper"

class AgentSnapshotsTest < ActionDispatch::IntegrationTest
  setup { @body = file_fixture("snapshots/web-1.json").read }

  test "accepts a valid snapshot and enqueues ingestion" do
    assert_enqueued_with job: SnapshotIngestJob do
      post agent_snapshots_path, params: @body, headers: headers("meridian_web1token")
    end
    assert_response :accepted
    assert agent_tokens(:web_1).reload.last_used_at
  end

  test "refuses unknown and revoked tokens" do
    post agent_snapshots_path, params: @body, headers: headers("nope")
    assert_response :unauthorized

    post agent_snapshots_path, params: @body, headers: headers("meridian_revokedtoken")
    assert_response :unauthorized
  end

  test "refuses bad bodies" do
    post agent_snapshots_path, params: "{", headers: headers("meridian_web1token")
    assert_response :bad_request

    post agent_snapshots_path, params: { hostname: "x" }.to_json, headers: headers("meridian_web1token")
    assert_response :unprocessable_entity
  end

  test "tokens are shown once and stored as a digest" do
    sign_in_as users(:ada)
    post agent_tokens_path, params: { agent_token: { label: "db-1" } }

    token = response.body[/meridian_[1-9A-HJ-NP-Za-km-z]{40}/]
    assert token
    assert_equal AgentToken.digest(token), AgentToken.find_by!(label: "db-1").digest
    assert_not AgentToken.column_names.include?("token")

    get agent_tokens_path
    assert_no_match token, response.body
  end

  test "bodies that aren't snapshots are refused, not crashed on or queued" do
    [ "[1]", "\"x\"", "42" ].each do |body|
      post agent_snapshots_path, params: body, headers: headers("meridian_web1token")
      assert_response :unprocessable_entity, body
    end

    assert_no_enqueued_jobs do
      post agent_snapshots_path, params: JSON.parse(@body).merge("labels" => "region=sgp").to_json, headers: headers("meridian_web1token")
    end
    assert_response :unprocessable_entity
  end

  test "an oversized body is refused before Rails parses it, token or not" do
    parsed = 0
    json = ActionDispatch::Request.parameter_parsers[:json]
    ActionDispatch::Request.parameter_parsers = ActionDispatch::Request.parameter_parsers.merge(json: ->(raw) { parsed += 1; json.call(raw) })

    big = { "machine_id" => "m", "hostname" => "h", "containers" => [], "pad" => "x" * (1.megabyte + 1) }.to_json
    post agent_snapshots_path, params: big, headers: headers("nope")
    assert_response :content_too_large
    post agent_snapshots_path, params: big, headers: headers("meridian_web1token")
    assert_response :content_too_large
    assert_equal 0, parsed
  ensure
    ActionDispatch::Request.parameter_parsers = ActionDispatch::Request.parameter_parsers.merge(json: json)
  end

  test "a per-server token is refused on a second machine" do
    perform_enqueued_jobs { post agent_snapshots_path, params: @body, headers: headers("meridian_web1token") }

    assert_no_enqueued_jobs do
      post agent_snapshots_path, params: JSON.parse(@body).merge("machine_id" => "another-machine").to_json, headers: headers("meridian_web1token")
    end
    assert_response :unprocessable_entity
    assert_match "belongs to another server", response.parsed_body["errors"].join

    travel Server::RECLAIM_AFTER + 1.minute
    post agent_snapshots_path, params: JSON.parse(@body).merge("machine_id" => "another-machine").to_json, headers: headers("meridian_web1token")
    assert_response :accepted, "a silent server's token goes with its rebuilt machine"
  end

  test "a fleet token's rate limit is per server" do
    store = Agent::SnapshotsController.cache_store
    counts = ActiveSupport::Cache::MemoryStore.new
    store.define_singleton_method(:increment) { |*args, **options| counts.increment(*args, **options) }
    body = JSON.parse(@body)

    statuses = 40.times.flat_map do |i|
      4.times.map do
        post agent_snapshots_path, params: body.merge("machine_id" => "m#{i}", "hostname" => "host-#{i}").to_json, headers: headers("meridian_fleettoken")
        response.status
      end
    end
    assert_equal [ 202 ], statuses.uniq

    121.times { post agent_snapshots_path, params: body.merge("machine_id" => "m0").to_json, headers: headers("meridian_fleettoken") }
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
  ensure
    store.singleton_class.remove_method(:increment)
  end

  test "a fleet token has a ceiling however many machine ids it reports for" do
    store = Agent::SnapshotsController.cache_store
    counts = ActiveSupport::Cache::MemoryStore.new
    store.define_singleton_method(:increment) { |*args, **options| counts.increment(*args, **options) }
    token = agent_tokens(:fleet)
    counts.write("rate-limit:agent/snapshots:fleet:#{token.id}", Agent::SnapshotsController::FLEET_CEILING, raw: true)

    post agent_snapshots_path, params: JSON.parse(@body).merge("machine_id" => "never-seen").to_json, headers: headers("meridian_fleettoken")
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]

    post agent_snapshots_path, params: @body, headers: headers("meridian_web1token")
    assert_response :accepted, "a per-server token has no fleet ceiling"
  ensure
    store.singleton_class.remove_method(:increment)
  end

  private
    def headers(token)
      { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    end
end
