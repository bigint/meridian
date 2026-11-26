require "test_helper"
require_relative "test_helpers/chrome_storage_reset"
require_relative "test_helpers/async_cable_helper"

Capybara.enable_aria_label = true

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include ActiveJob::TestHelper, AsyncCableHelper

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ]

  def sign_in(user)
    visit new_session_path
    fill_in "Email", with: user.email_address
    fill_in "Password", with: "correct horse battery"
    click_on "Sign in"
    assert_selector "#sidebar", visible: :all
  end
end
