class ProjectSyncJob < ApplicationJob
  queue_as :default
  limits_concurrency key: ->(project, **) { project }

  def perform(project, force: false)
    project.sync(force: force)
  end
end
