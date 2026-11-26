require "application_system_test_case"

class SidebarTest < ApplicationSystemTestCase
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
  end

  test "type in the search box, Enter: you're there" do
    sign_in users(:viewer)

    fill_in "Search apps, servers and projects", with: "blog"
    within("#jump_results") { assert_link "blog" }
    send_keys :enter

    assert_selector "h1", text: "blog"
  end

  test "Escape clears the search" do
    sign_in users(:viewer)

    fill_in "Search apps, servers and projects", with: "blog"
    within("#jump_results") { assert_link "blog" }
    send_keys :escape

    assert_field "Search apps, servers and projects", with: ""
    assert_no_selector "#jump_results a"
  end

  test "the nav goes to the main places and marks where you are" do
    sign_in users(:viewer)
    within("nav[aria-label=Main]") { click_on "Map" }
    assert_selector "h1", text: "Map"
    assert_selector "nav[aria-label=Main] a[aria-current=page]", text: "Map"
  end

  test "on a phone the sidebar is a drawer behind the Menu button" do
    page.driver.browser.manage.window.resize_to(390, 844)
    sign_in users(:viewer)

    assert_no_selector "#sidebar", visible: true
    click_on "Menu"
    within("#sidebar") { click_on "Servers" }
    assert_selector "h1", text: "Servers"
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1000)
  end

  test "the sidebar collapses to a rail, stays that way across pages, and expands again" do
    sign_in users(:viewer)
    assert_selector "#sidebar a[aria-current=page] span", text: "Board", visible: true

    click_on "Collapse sidebar"
    assert_selector "[data-controller=sidebar][data-collapsed]"
    assert_equal "Expand sidebar", page.evaluate_script("document.activeElement.getAttribute('aria-label')"), "focus moves to the twin toggle"
    assert wait_until { sidebar_width < 80 }, "the rail is narrow once the width settles"

    visit map_path
    assert_selector "[data-controller=sidebar][data-collapsed]", wait: 0
    assert_operator sidebar_width, :<, 80, "rendered collapsed by the server, with no animation"
    assert_selector "#sidebar a[data-tooltip=Map][aria-current=page]"

    click_on "Expand sidebar"
    assert_no_selector "[data-controller=sidebar][data-collapsed]"
    visit root_path
    assert_operator sidebar_width, :>, 200
  end

  private
    def sidebar_width = page.evaluate_script("document.getElementById('sidebar').getBoundingClientRect().width")

    def wait_until(timeout: Capybara.default_max_wait_time)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until (result = yield)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
      result
    end
end
