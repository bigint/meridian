class AppsController < ApplicationController
  def index
    @apps = App.includes(:project).ordered
    @apps = @apps.where("service LIKE ? ESCAPE '\\'", "%#{App.sanitize_sql_like(params[:q].to_s)}%") if params[:q].present?
    @latest_releases = Release.latest_per_app.where(app_id: @apps.map(&:id)).index_by(&:app_id)
  end

  def new
    @draft = AppDraft.new(project_id: params[:project_id] || Project.order(:name).first&.id)
  end

  def create
    @draft = AppDraft.new(params.expect(app_draft: [ :project_id, :service, :source_repo, :kind, :hostname, :label_selector, :destination, :app_port, :registry, :version, server_ids: [] ]))
    if (@proposal = @draft.submit(current_user))
      render :proposed, status: :created
    else
      render :new, status: :unprocessable_entity
    end
  rescue GitHost::Error => error
    flash.now[:alert] = github_refused(error)
    render :new, status: :unprocessable_entity
  end

  def show
    @app = App.find(params[:id])
    @board = Board.new(app_id: @app.id, group: "none")
    @releases = @app.releases.limit(20)
    @accessories = Accessory.for(@app)
  end
end
