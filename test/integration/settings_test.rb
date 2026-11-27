require "test_helper"

class SettingsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:ada) }

  test "the install's own place is saved and recorded in Activity" do
    patch settings_account_path, params: { account: { location_name: "Singapore", latitude: "1.35", longitude: "103.82" } }

    assert_redirected_to settings_account_path
    assert Account.current.located?
    assert_equal "settings.updated", Event.recent.first.action
  end

  test "a place off the globe is refused, and the form says why" do
    patch settings_account_path, params: { account: { latitude: "120" } }

    assert_response :unprocessable_entity
    assert_select ".field:has(#account_latitude) .field__error"
    assert_nil Account.current.latitude
  end

  test "a new name keeps the person signed in" do
    patch settings_user_path, params: { user: { name: "Ada King", password: "" } }

    assert_redirected_to settings_account_path
    assert_equal "Ada King", users(:ada).reload.name
    get settings_account_path
    assert_response :success
  end

  test "a new password signs the person out everywhere else" do
    this_session = Current.session
    stolen = users(:ada).sessions.create!

    patch settings_user_path, params: { user: { name: "Ada King" } }
    assert Session.exists?(stolen.id), "saving without a new password keeps sessions"

    patch settings_user_path, params: { user: { password: "a brand new password" } }
    assert_not Session.exists?(stolen.id)
    assert Session.exists?(this_session.id)
  end
end
