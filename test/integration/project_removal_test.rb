require "test_helper"

class ProjectRemovalTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:infra)
    stub_github_repo(@project)
    @project.sync
    sign_in_as users(:ada)
    @web = @project.apps.find_by!(service: "web", destination: "production")
    @web.update!(source_repo: "acme/web")
  end

  test "removing a project asks first, says Git is untouched, and Activity names it" do
    get edit_project_path(@project)
    assert_select "form[action=?][data-turbo-confirm=?]", project_path(@project), "Remove this project from Meridian? Nothing in Git changes."

    delete project_path(@project)
    assert_equal "Removed example/infra", Event.recent.first.summary
  end
end
