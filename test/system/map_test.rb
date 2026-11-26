require "application_system_test_case"

class MapTest < ApplicationSystemTestCase
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
    Server.find_by!(name: "web-2.example.com").update!(latitude: 1.35, longitude: 103.82, last_seen_at: Time.current)
    Server.find_by!(name: "api-1.example.com").update!(latitude: 50.11, longitude: 8.68, last_seen_at: Time.current)
  end

  test "clicking a place on the map opens it in the side panel, through Turbo" do
    sign_in users(:viewer)
    visit map_path
    page.execute_script("window.stillTheSamePage = true")

    find(".world__sites a.site", match: :first).tap { |dot| @name = dot[:"aria-label"].split(":").first }.click

    assert_selector "#place h2", text: @name
    assert_selector ".world__sites a.site.selected[aria-current=true]", count: 1
    assert page.evaluate_script("window.stillTheSamePage"), "a Turbo visit, not a full reload"
  end
end
