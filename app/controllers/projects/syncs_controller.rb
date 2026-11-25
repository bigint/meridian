class Projects::SyncsController < ApplicationController
  require_admin

  def create
    project = Project.find(params[:project_id])
    ProjectSyncJob.perform_later(project, force: true)
    redirect_to project, notice: "Syncing #{project.repo_full_name}."
  end
end
