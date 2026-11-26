class TunnelsController < ApplicationController
  def index
    @tunnels = Tunnel.all
    @account = Account.current
    @apps = App.ordered.includes(:project)
    tunnelled = @tunnels.map(&:app)
    app = @apps.find { it.id == params[:app].to_i } || (@apps - tunnelled).first || @apps.first
    @setup = Tunnel::Setup.new(app) if app
  end
end
