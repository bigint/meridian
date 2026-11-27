require "test_helper"

class ProjectRemovalTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:infra)
    sign_in_as users(:ada)
  end

  test "removing a project asks first, says Git is untouched, and Activity names it" do
    get edit_project_path(@project)
    assert_select "form[action=?][data-turbo-confirm=?]", project_path(@project), "Remove this project from Meridian? Nothing in Git changes."

    delete project_path(@project)
    assert_equal "Removed example/infra", Event.recent.first.summary
  end
end
