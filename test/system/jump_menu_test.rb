require "application_system_test_case"

class JumpMenuTest < ApplicationSystemTestCase
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
  end

  test "press M, type, Enter: you're there" do
    sign_in users(:viewer)
    wait_for_shortcuts

    find("body").send_keys("m")
    within("#jump") do
      assert_field "Go to an app, server or project", focused: true
      send_keys "blog"
      assert_link "blog"
    end
    send_keys :enter

    assert_selector "h1", text: "blog"
  end

  test "number keys open the menu's places" do
    sign_in users(:viewer)
    click_on "Open the Meridian menu"
    assert_field "Go to an app, server or project", focused: true
    send_keys "3"
    assert_selector "h1", text: "Servers"
  end
end
