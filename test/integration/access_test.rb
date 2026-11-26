require "test_helper"

class AccessTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

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

    post first_run_path, params: { setup_code: User.setup_code, user: { name: "Ada", email_address: "first@example.com", password: "a long enough password" } }
    assert_redirected_to projects_path
    assert User.find_by!(email_address: "first@example.com").admin?

    get first_run_path
    assert_redirected_to root_path
  end

  test "first run needs the setup code, so whoever reaches a fresh deploy first can't take it" do
    User.delete_all

    [ nil, "wrong" ].each do |code|
      post first_run_path, params: { setup_code: code, user: { name: "Eve", email_address: "eve@example.com", password: "a long enough password" } }
      assert_response :unprocessable_entity
      assert_select ".alert", text: /Setup code doesn.t match/
    end
    assert_not User.exists?
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

  test "changing a project's config paths syncs it again, though the head hasn't moved" do
    project = projects(:infra)
    sign_in_as users(:admin)

    assert_enqueued_with job: ProjectSyncJob, args: [ project, { force: true } ] do
      patch project_path(project), params: { project: { config_globs: "deploy/blog.yml" } }
    end
    assert_no_enqueued_jobs only: ProjectSyncJob do
      patch project_path(project), params: { project: { name: "Infra repo" } }
    end
  end

  test "a new password signs the person out everywhere else" do
    stolen = users(:viewer).sessions.create!
    sign_in_as users(:admin)
    admin_session = Current.session

    patch settings_user_path(users(:viewer)), params: { user: { role: "viewer" } }
    assert Session.exists?(stolen.id), "saving without a new password keeps sessions"

    patch settings_user_path(users(:viewer)), params: { user: { password: "a brand new password" } }
    assert_not Session.exists?(stolen.id)
    assert Session.exists?(admin_session.id)
  end

  test "the last admin can't be demoted" do
    sign_in_as users(:admin)
    patch settings_user_path(users(:admin)), params: { user: { role: "viewer" } }
    assert users(:admin).reload.admin?
  end

  test "a new role, signing out and being removed hang up the person's open cables" do
    cables = "action_cable/#{users(:deployer).to_gid_param}"
    sign_in_as users(:admin)

    assert_broadcasts(cables, 1) { patch settings_user_path(users(:deployer)), params: { user: { role: "viewer" } } }
    assert_no_broadcasts(cables) { patch settings_user_path(users(:deployer)), params: { user: { name: "Dee" } } }

    sign_in_as users(:deployer)
    assert_broadcasts(cables, 1) { delete session_path }

    users(:deployer).sessions.create!
    sign_in_as users(:admin)
    assert_broadcasts(cables, 1) { delete settings_user_path(users(:deployer)) }
  end

  test "signing in goes back to the page that asked, but not to a form's POST or a bare frame" do
    sign_in = -> { post session_path, params: { email_address: users(:deployer).email_address, password: "correct horse battery" } }

    get servers_path
    sign_in.call
    assert_redirected_to servers_url

    delete session_path
    post app_deploys_path(App.create!(project: projects(:infra), service: "api", config_path: "deploy/api.yml", kind: "rails"))
    sign_in.call
    assert_redirected_to root_url

    delete session_path
    get jump_path(q: "web"), headers: { "Turbo-Frame" => "jump" }
    sign_in.call
    assert_redirected_to root_url
  end
end
