class ProjectsController < ApplicationController
  require_admin except: %i[ index show ]
  before_action :set_project, only: %i[ show edit update destroy ]

  def index
    @projects = Project.order(:name)
  end

  def show
    @apps = @project.apps.ordered
  end

  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params)
    if @project.save
      Event.record("project.created", subject: @project, summary: "Added #{@project.repo_full_name}")
      @project.sync_later
      redirect_to @project, notice: "Project added. Syncing now."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @project.update(project_params)
      Event.record("project.updated", subject: @project, summary: "Updated #{@project.repo_full_name}")
      redirect_to @project, notice: "Project saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @project.destroy
    Event.record("project.removed", summary: "Removed #{@project.repo_full_name}")
    redirect_to projects_path, notice: "Project removed. Nothing in Git was changed."
  end

  private
    def set_project
      @project = Project.find(params[:id])
    end

    def project_params
      params.expect(project: [ :name, :repo_full_name, :default_branch, :installation_id, :config_globs, :direct_commits ])
    end
end
