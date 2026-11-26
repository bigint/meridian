class TunnelsController < ApplicationController
  def index
    @tunnels = Tunnel.all
    @account = Account.current
  end

  # Step-by-step setup of a project's shared tunnel, in its own names, for
  # the servers picked to run connectors.
  def new
    @projects = Project.order(:name).to_a
    project = @projects.find { it.id == params[:project].to_i } || @projects.first
    @setup = Tunnel::Setup.for(project, hosts: Array(params[:hosts]).compact_blank) if project
  end
end
