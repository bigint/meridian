require "application_system_test_case"

class LayoutTest < ApplicationSystemTestCase
  setup { Meridian::Demo.new(servers: 60, apps: 4).call }

  test "a wide board scrolls inside its table, not the page" do
    page.driver.browser.manage.window.resize_to(1024, 800)
    sign_in users(:viewer)

    visit root_path(group: "none")
    assert_selector "[data-board-grid]"
    assert_equal page.evaluate_script("document.documentElement.clientWidth"),
      page.evaluate_script("document.documentElement.scrollWidth")
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1000)
  end

  test "on a phone no page scrolls sideways; wide tables scroll in their own box" do
    page.driver.browser.manage.window.resize_to(390, 844)
    sign_in users(:viewer)

    [ root_path(group: "none"), app_path(App.order(:id).first), server_path(Server.order(:id).first) ].each do |path|
      visit path
      assert_selector "h1"
      assert_equal page.evaluate_script("document.documentElement.clientWidth"),
        page.evaluate_script("document.documentElement.scrollWidth"), "#{path} scrolls sideways"
    end
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1000)
  end
end
