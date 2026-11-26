require "test_helper"

class SettingsTest < ActionDispatch::IntegrationTest
  test "an admin chooses flat preview hostnames" do
    sign_in_as users(:admin)

    get settings_account_path
    assert_select "select[name='account[preview_hostnames]'] option", 2

    patch settings_account_path, params: { account: { preview_hostnames: "flat" } }
    assert_redirected_to settings_account_path
    assert_predicate Account.current, :preview_hostnames_flat?
  end
end
