class TunnelsController < ApplicationController
  def index
    @tunnels = Tunnel.all
    @account = Account.current
  end
end
