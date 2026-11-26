class TunnelsController < ApplicationController
  def index
    @tunnels = Tunnel.all
  end
end
