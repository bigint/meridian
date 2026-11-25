class ServersController < ApplicationController
  def index
    @servers = Server.ordered
    @servers = @servers.where("name LIKE ? OR hostname LIKE ?", *[ "%#{Server.sanitize_sql_like(params[:q])}%" ] * 2) if params[:q].present?
    @silent = params[:silent].present?
    @servers = @servers.silent if @silent
  end

  def show
    @server = Server.find(params[:id])
    @placements = @server.placements.includes(:app).order(:service, :role, :name)
    @assignments = @server.assignments.includes(app: :project)
    @board = Board.new(server_id: @server.id, group: "none")
  end
end
