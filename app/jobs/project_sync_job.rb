# Reads Git, then the repository's CI runs. One job per repository at a time,
# so one repository's deploys have one writer.
class ProjectSyncJob < ApplicationJob
  queue_as :default
  limits_concurrency key: ->(project, **) { project.repo_full_name.downcase }, group: "github_repository"

  def perform(project, force: false)
    project.sync(force: force)
    project.poll_workflow_runs
  end
end
