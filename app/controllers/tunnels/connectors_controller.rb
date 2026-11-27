# Changes which servers run a tunnel's connectors, as a pull request (or a
# direct commit, where the project allows it) to the connector config.
class Tunnels::ConnectorsController < ApplicationController
  before_action :set_tunnel

  def edit
    @change = Tunnel::ConnectorChange.new(@tunnel, hosts: params[:hosts].presence || @tunnel.connector_hosts)
  end

  def update
    @change = Tunnel::ConnectorChange.new(@tunnel, hosts: params[:hosts])
    if (@proposal = @change.submit(current_user))
      render :proposed, status: :created
    else
      render :edit, status: :unprocessable_entity
    end
  rescue GitHost::Error => error
    flash.now[:alert] = github_refused(error)
    render :edit, status: :unprocessable_entity
  end

  private
    def set_tunnel
      @tunnel = Tunnel.all(project: Project.find(params[:project].to_s)).find { it.secret_name == params[:secret] } or raise ActiveRecord::RecordNotFound
    end
end
