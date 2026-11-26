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
end
