# Reads Git, then the CI runs webhooks may have missed. Shares a concurrency
# group with GitHubEventJob so one repository's deploys have one writer at a time.
class ProjectSyncJob < ApplicationJob
  queue_as :default
  limits_concurrency key: ->(project, **) { project.repo_full_name }, group: "github_repository"

  def perform(project, force: false)
    project.sync(force: force)
    project.poll_workflow_runs
  end
end
