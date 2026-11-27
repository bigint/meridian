require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "an agent connects with its bearer token" do
    connect headers: { "Authorization" => "Bearer meridian_web1token" }

    assert_equal agent_tokens(:web_1), connection.agent_token
    assert_nil connection.current_user
  end

  test "a signed-in browser connects with its session cookie" do
    session = users(:ada).sessions.create!
    cookies.signed[:session_id] = session.id
    connect

    assert_equal users(:ada), connection.current_user
    assert_nil connection.agent_token
  end

  test "an unknown or revoked token is rejected" do
    assert_reject_connection { connect headers: { "Authorization" => "Bearer nope" } }
    assert_reject_connection { connect headers: { "Authorization" => "Bearer meridian_revokedtoken" } }
  end

  test "a bearer header never falls back to the cookie" do
    cookies.signed[:session_id] = users(:ada).sessions.create!.id

    assert_reject_connection { connect headers: { "Authorization" => "Bearer nope" } }
  end

  test "neither a token nor a session is rejected" do
    assert_reject_connection { connect }

    cookies.signed[:session_id] = "gone"
    assert_reject_connection { connect }
  end
end
