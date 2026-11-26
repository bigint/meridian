require "application_system_test_case"

# Regenerates the screenshots in docs/screenshots. Skipped unless asked:
#
#   SCREENSHOTS=1 bin/rails test test/system/screenshots_test.rb
class ScreenshotsTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1440, 1000 ]

  setup do
    skip "Set SCREENSHOTS=1 to regenerate docs/screenshots" unless ENV["SCREENSHOTS"]
    @project = Meridian::Demo.new(servers: 72, apps: 40).call
    record_some_activity
  end

  test "board, search, app, server and activity in light and dark" do
    sign_in users(:admin)

    %w[ light dark ].each do |scheme|
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ])
      suffix = scheme == "light" ? "" : "-dark"

      visit root_path
      save "board#{suffix}"

      fill_in "Search apps, servers and projects", with: "cedar"
      within("#jump_results") { assert_link "cedar-0" }
      save "search#{suffix}"
      send_keys :escape

      visit app_path(@project.apps.order(:id).second)
      save "app#{suffix}"

      visit server_path(Server.where.not(last_seen_at: nil).order(:id).first)
      save "server#{suffix}"

      visit events_path
      save "activity#{suffix}"

      visit map_path
      save "map#{suffix}"
    end
  end

  private
    def save(name)
      assert_selector "h1"
      page.save_screenshot(Rails.root.join("docs/screenshots/#{name}.png").to_s)
    end

    def record_some_activity
      admin, deployer = users(:admin), users(:deployer)
      apps = @project.apps.order(:id).first(4)
      [
        [ 5.minutes.ago, deployer, "app.deploy", apps[0], "Deployed #{apps[0].name} to v13" ],
        [ 40.minutes.ago, admin, "secret.set", nil, "Set DATABASE_URL on example/fleet" ],
        [ 2.hours.ago, deployer, "app.rollback", apps[1], "Rolled back #{apps[1].name} to v11" ],
        [ 26.hours.ago, admin, "project.pull_request", @project, "feat(#{apps[2].service}): add node app" ],
        [ 27.hours.ago, admin, "agent_token.created", nil, "Created agent token “demo-ams-000”" ],
        [ 50.hours.ago, deployer, "app.redeploy", apps[3], "Redeployed #{apps[3].name} at v12" ]
      ].each do |time, actor, action, subject, summary|
        Event.create!(created_at: time, actor: actor, action: action, subject: subject, details: { summary: summary })
      end
    end
end
