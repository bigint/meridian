class ServersController < ApplicationController
  require_admin only: :update

  def index
    @servers = Server.ordered
    @servers = @servers.where("name LIKE ? OR hostname LIKE ?", *[ "%#{Server.sanitize_sql_like(params[:q])}%" ] * 2) if params[:q].present?
    @silent = params[:silent].present?
    @servers = @servers.silent if @silent
  end

  def show
    @server = Server.find(params[:id])
    @placements = @server.placements.includes(:app).order(:service, :role, :name)
    @board = Board.new(server_id: @server.id, group: "none")
  end

  # Only the location is editable; everything else comes from Git and agents.
  def update
    server = Server.find(params[:id])
    if server.update(params.expect(server: [ :latitude, :longitude ]))
      Event.record("server.located", subject: server, summary: "Placed #{server.name} on the map")
      redirect_to server, notice: "Location saved."
    else
      redirect_to server, alert: server.errors.full_messages.to_sentence
    end
  end
end
