class Projects::SyncsController < ApplicationController
  def create
    project = Project.find(params[:project_id])
    project.sync_later(force: true)
    redirect_to project, notice: "Syncing #{project.repo_full_name}."
  end
end
