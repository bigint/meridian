require "application_system_test_case"

class BoardSyncTest < ApplicationSystemTestCase
  test "an admin syncs a project and reads the board" do
    project = projects(:infra)
    stub_github_repo(project)

    sign_in users(:admin)
    visit project_path(project)
    click_on "Sync now"
    assert_text "Syncing example/infra"
    perform_enqueued_jobs

    visit project_path(project)
    assert_text "deploy/broken.yml:6"
    assert_text "servers/web/hosts: should be an array"

    click_on "Open the Meridian menu"
    within("#jump") { click_on "Board" }
    within "table.grid" do
      assert_text "web · production"
      assert_text "blog"
      assert_selector "a[title='api-1.example.com']", text: "api-1"
    end
    assert_selector ".summary", text: "Unknown"
  end
end
