require "test_helper"

class AccessTest < ActionDispatch::IntegrationTest
  test "everything requires signing in" do
    [ root_path, apps_path, servers_path, projects_path, events_path ].each do |path|
      get path
      assert_redirected_to new_session_path, path
    end
  end

  test "first run creates the first admin, then closes" do
    User.delete_all
    get new_session_path
    assert_redirected_to first_run_path

    post first_run_path, params: { user: { name: "Ada", email_address: "first@example.com", password: "a long enough password" } }
    assert_redirected_to projects_path
    assert User.find_by!(email_address: "first@example.com").admin?

    get first_run_path
    assert_redirected_to root_path
  end

  test "viewers can read but not change projects" do
    sign_in_as users(:viewer)

    get projects_path
    assert_response :success

    post projects_path, params: { project: { name: "X", repo_full_name: "example/x" } }
    assert_redirected_to root_path
    assert_nil Project.find_by(repo_full_name: "example/x")

    post project_sync_path(projects(:infra))
    assert_redirected_to root_path
  end

  test "only admins reach settings and jobs" do
    sign_in_as users(:deployer)
    get settings_users_path
    assert_redirected_to root_path
    get "/jobs"
    assert_response :redirect

    sign_in_as users(:admin)
    get "/settings/users"
    assert_response :success
    get "/jobs"
    assert_response :success
  end

  test "admins add a project and it syncs" do
    sign_in_as users(:admin)

    assert_enqueued_with job: ProjectSyncJob do
      post projects_path, params: { project: { name: "Homelab", repo_full_name: "example/homelab", installation_id: 7, config_globs: "kamal/*.yml, config/deploy*.yml" } }
    end

    project = Project.find_by!(repo_full_name: "example/homelab")
    assert_equal %w[ kamal/*.yml config/deploy*.yml ], project.config_globs
    assert_equal "project.created", Event.recent.first.action
  end

  test "the last admin can't be demoted" do
    sign_in_as users(:admin)
    patch settings_user_path(users(:admin)), params: { user: { role: "viewer" } }
    assert users(:admin).reload.admin?
  end
end
