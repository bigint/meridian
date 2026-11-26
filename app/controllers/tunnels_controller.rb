class TunnelsController < ApplicationController
  def index
    @tunnels = Tunnel.all
    @account = Account.current
  end

  # Step-by-step setup for one app, in its own names.
  def new
    @apps = App.ordered.includes(:project, :servers)
    tunnels = Tunnel.all
    app = @apps.find { it.id == params[:app].to_i } || (@apps - tunnels.map(&:app)).first || @apps.first
    @setup = Tunnel::Setup.for(app, tunnels: tunnels) if app
  end
end
