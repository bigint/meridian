class Apps::DeploysController < ApplicationController
  require_deployer
  rate_limit to: 10, within: 1.minute, only: :create

  def create
    app = App.find(params[:app_id])
    app.deploy(params.expect(deploy: [ :version ])[:version], actor: current_user)
    redirect_to app, notice: "Committed. CI will deploy it."
  rescue ArgumentError => error
    redirect_to app, alert: error.message
  rescue GitHost::Conflict
    app.project.sync_later
    redirect_to app, alert: "The version file changed in Git since this page loaded. Meridian is re-reading it; check the new state and try again."
  rescue GitHost::Error => error
    redirect_to app, alert: "GitHub refused the commit: #{error.message.truncate(200)}"
  end
end
