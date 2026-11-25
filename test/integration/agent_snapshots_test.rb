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

    post agent_snapshots_path, params: "x" * (1.megabyte + 1), headers: headers("meridian_web1token")
    assert_response :content_too_large
  end

  test "tokens are shown once and stored as a digest" do
    sign_in_as users(:admin)
    post agent_tokens_path, params: { agent_token: { label: "db-1" } }

    token = response.body[/meridian_[1-9A-HJ-NP-Za-km-z]{40}/]
    assert token
    assert_equal AgentToken.digest(token), AgentToken.find_by!(label: "db-1").digest
    assert_not AgentToken.column_names.include?("token")

    get agent_tokens_path
    assert_no_match token, response.body
  end

  private
    def headers(token)
      { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    end
end
