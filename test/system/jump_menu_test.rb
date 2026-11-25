require "application_system_test_case"

class JumpMenuTest < ApplicationSystemTestCase
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
  end

  test "open the menu, type, Enter: you're there" do
    sign_in users(:viewer)

    click_on "Open the Meridian menu"
    within("#jump") do
      fill_in "Go to an app, server or project", with: "blog"
      assert_link "blog"
    end
    send_keys :enter

    assert_selector "h1", text: "blog"
  end

  test "tiles go to the main places" do
    sign_in users(:viewer)
    click_on "Open the Meridian menu"
    within("#jump") { click_on "Map" }
    assert_selector "h1", text: "Map"
  end
end
