require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @user = User.take }

  test "new" do
    get new_session_path
    assert_response :success
  end

  test "create with valid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "correct horse battery" }

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "create with invalid credentials" do
    post session_path, params: { email_address: @user.email_address, password: "wrong" }

    assert_redirected_to new_session_path
    assert_nil cookies[:session_id]
  end

  test "create with a missing or malformed field is a failed sign-in, not an error" do
    [ {}, { email_address: @user.email_address }, { password: "correct horse battery" }, { email_address: [ "x" ], password: { "a" => "b" } } ].each do |params|
      post session_path, params: params

      assert_redirected_to new_session_path, params.inspect
      assert_nil cookies[:session_id]
    end
  end

  test "destroy" do
    sign_in_as(User.take)

    delete session_path

    assert_redirected_to new_session_path
    assert_empty cookies[:session_id]
  end
end
