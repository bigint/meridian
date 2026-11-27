require "test_helper"

class AccessTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  test "everything requires signing in" do
    [ root_path, apps_path, servers_path, projects_path, events_path ].each do |path|
      get path
      assert_redirected_to new_session_path, path
    end
  end

  test "first run creates the one user, then closes" do
    User.delete_all
    get new_session_path
    assert_redirected_to first_run_path

    post first_run_path, params: { setup_code: User.setup_code, user: { name: "Ada", email_address: "first@example.com", password: "a long enough password" } }
    assert_redirected_to projects_path
    assert User.exists?(email_address: "first@example.com")

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

  test "adding a project syncs it" do
    sign_in_as users(:ada)

    assert_enqueued_with job: ProjectSyncJob do
      post projects_path, params: { project: { name: "Homelab", repo_full_name: "example/homelab", installation_id: 7, config_globs: "kamal/*.yml, config/deploy*.yml" } }
    end

    project = Project.find_by!(repo_full_name: "example/homelab")
    assert_equal %w[ kamal/*.yml config/deploy*.yml ], project.config_globs
    assert_equal "project.created", Event.recent.first.action
  end

  test "changing a project's config paths syncs it again, though the head hasn't moved" do
    project = projects(:infra)
    sign_in_as users(:ada)

    assert_enqueued_with job: ProjectSyncJob, args: [ project, { force: true } ] do
      patch project_path(project), params: { project: { config_globs: "deploy/blog.yml" } }
    end
    assert_no_enqueued_jobs only: ProjectSyncJob do
      patch project_path(project), params: { project: { name: "Infra repo" } }
    end
  end

  test "a new password signs the person out everywhere else" do
    stolen = users(:ada).sessions.create!
    sign_in_as users(:ada)
    this_session = Current.session

    patch settings_user_path, params: { user: { name: "Ada King" } }
    assert Session.exists?(stolen.id), "saving without a new password keeps sessions"

    patch settings_user_path, params: { user: { password: "a brand new password" } }
    assert_not Session.exists?(stolen.id)
    assert Session.exists?(this_session.id)
  end

  test "settings need a session" do
    get settings_root_path
    assert_redirected_to new_session_path

    sign_in_as users(:ada)
    get settings_root_path
    assert_response :success
  end

  test "the jobs dashboard sits behind the same sign-in" do
    get "/jobs"
    assert_redirected_to "/session/new"
  end

  test "signing out hangs up the person's open cables" do
    sign_in_as users(:ada)

    assert_broadcasts("action_cable/#{users(:ada).to_gid_param}", 1) { delete session_path }
  end

  test "signing in goes back to the page that asked, but not to a form's POST or a bare frame" do
    sign_in = -> { post session_path, params: { email_address: users(:ada).email_address, password: "correct horse battery" } }

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
