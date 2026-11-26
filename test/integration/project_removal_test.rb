require "test_helper"

class ProjectRemovalTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
    sign_in_as users(:admin)
    @web = @project.apps.find_by!(service: "web", destination: "production")
    @web.update!(source_repo: "acme/web")
  end

  test "removing a project with a running preview warns first, and Activity names what is left" do
    preview(12, "active")
    preview(9, "removed")

    get edit_project_path(@project)
    assert_select "form[action=?][data-turbo-confirm=?]", project_path(@project),
      "Remove this project from Meridian? Nothing in Git changes. Preview acme/web#12 keeps running: Destroy it on Previews first."

    delete project_path(@project)
    assert_equal "Removed example/infra. Preview acme/web#12 was still running: remove the web pr-12 containers and deploy/web.pr-12.yml by hand",
      Event.recent.first.summary
  end

  test "previews still being removed count too" do
    preview(12, "active")
    preview(13, "removing")

    get edit_project_path(@project)
    assert_select "form[data-turbo-confirm$=?]", "Previews acme/web#12 and acme/web#13 keep running: Destroy them on Previews first."

    delete project_path(@project)
    assert_match "Previews acme/web#12 and acme/web#13 were still running: remove the web pr-12 and web pr-13 containers and deploy/web.pr-12.yml and deploy/web.pr-13.yml by hand",
      Event.recent.first.summary
  end

  test "without previews the confirm only says Git is untouched" do
    get edit_project_path(@project)
    assert_select "form[action=?][data-turbo-confirm=?]", project_path(@project), "Remove this project from Meridian? Nothing in Git changes."

    delete project_path(@project)
    assert_equal "Removed example/infra", Event.recent.first.summary
  end

  private
    def preview(number, state)
      @web.previews.create!(pr_number: number, destination: "pr-#{number}", hostname: "pr-#{number}.web.preview.example.com",
        overlay_path: "deploy/web.pr-#{number}.yml", state: state, expires_at: 1.day.from_now)
    end
end
