require "test_helper"

class SessionsTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "the sign-in page renders" do
    get new_session_path
    assert_response :success
  end

  test "the right password starts a session" do
    post session_path, params: { email_address: @user.email_address, password: "correct horse battery" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "a wrong password starts no session" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "a missing or malformed field is a failed sign-in, not an error" do
    [ {}, { email_address: @user.email_address }, { password: "correct horse battery" }, { email_address: [ "x" ], password: { "a" => "b" } } ].each do |params|
      post session_path, params: params

      assert_redirected_to new_session_path, params.inspect
      assert_nil cookies[:session_id]
    end
  end

  test "signing out ends the session" do
    sign_in_as(@user)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
  end

  test "a session unused for longer than the idle timeout is over" do
    sign_in_as(@user)
    session = Current.session
    session.update_columns(updated_at: (Session::IDLE_TIMEOUT + 1.minute).ago)

    get root_path

    assert_redirected_to new_session_path
    Session.expired.find_each(&:destroy)
    assert_not Session.exists?(session.id)
  end

  test "a session in use still ends at its maximum age" do
    sign_in_as(@user)
    Current.session.update_columns(created_at: (Session::MAX_AGE + 1.minute).ago, updated_at: 1.minute.ago)

    get root_path

    assert_redirected_to new_session_path
  end

  test "using a session moves it on, at most once per touch interval" do
    sign_in_as(@user)
    session = Current.session
    session.update_columns(updated_at: 2.hours.ago)

    get root_path
    assert_response :success
    assert_in_delta Time.current, session.reload.updated_at, 5.seconds
    assert cookies[:session_id].present?

    touched = session.updated_at
    travel 10.minutes do
      get root_path
      assert_equal touched, session.reload.updated_at
    end
  end
end
