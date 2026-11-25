class Apps::RollbacksController < ApplicationController
  require_deployer
  rate_limit to: 10, within: 1.minute, only: :create

  def create
    app = App.find(params[:app_id])
    deploy = app.roll_back(app.releases.find(params.expect(:release_id)), actor: current_user)
    redirect_to app, notice: "Committed a revert to #{deploy.version}. CI will deploy it."
  rescue ArgumentError => error
    redirect_to app, alert: error.message
  rescue GitHost::Conflict
    app.project.sync_later
    redirect_to app, alert: "The version file changed in Git since this page loaded. Meridian is re-reading it; check the new state and try again."
  rescue GitHost::Error => error
    redirect_to app, alert: "GitHub refused the commit: #{error.message.truncate(200)}"
  end
end
