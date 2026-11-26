require "application_system_test_case"

class ThemeTest < ApplicationSystemTestCase
  setup { prefer "light" }
  teardown { prefer nil }

  test "pick dark, keep it across pages, go back to the system's" do
    sign_in users(:viewer)
    light = background

    click_on "Account: #{users(:viewer).display_name}"
    click_on "Dark"
    assert_selector "html[data-theme=dark]", visible: :all
    assert_not_equal light, background

    visit map_path
    assert_selector "html[data-theme=dark]", visible: :all
    assert_not_equal light, background, "rendered dark by the server, from the cookie"

    click_on "Account: #{users(:viewer).display_name}"
    click_on "System"
    assert_no_selector "html[data-theme]", visible: :all
    visit root_path
    assert_equal light, background
  end

  private
    # The operating system's preference, as the browser reports it.
    def prefer(scheme)
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme.to_s } ])
    end

    def background = page.evaluate_script("getComputedStyle(document.body).backgroundColor")
end
