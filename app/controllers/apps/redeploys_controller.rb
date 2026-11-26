class Apps::RedeploysController < ApplicationController
  rate_limit to: 5, within: 1.minute

  def create
    app = App.find(params[:app_id])
    version = app.redeploy(actor: current_user)
    redirect_to app, notice: "Asked CI to deploy #{version} again."
  rescue ArgumentError => error
    redirect_to app, alert: error.message
  rescue GitHost::Error => error
    redirect_to app, alert: "GitHub refused: #{error.message.truncate(200)}"
  end
end
