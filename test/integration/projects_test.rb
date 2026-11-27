require "test_helper"

class ProjectsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:ada) }

  test "adding a project syncs it" do
    assert_enqueued_with job: ProjectSyncJob do
      post projects_path, params: { project: { name: "Homelab", repo_full_name: "example/homelab", installation_id: 7, config_globs: "kamal/*.yml, config/deploy*.yml" } }
    end

    project = Project.find_by!(repo_full_name: "example/homelab")
    assert_equal %w[ kamal/*.yml config/deploy*.yml ], project.config_globs
    assert_equal "project.created", Event.recent.first.action
  end

  test "changing a project's config paths syncs it again, though the head hasn't moved" do
    project = projects(:infra)

    assert_enqueued_with job: ProjectSyncJob, args: [ project, { force: true } ] do
      patch project_path(project), params: { project: { config_globs: "deploy/blog.yml" } }
    end
    assert_no_enqueued_jobs only: ProjectSyncJob do
      patch project_path(project), params: { project: { name: "Infra repo" } }
    end
  end
end
