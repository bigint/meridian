class Apps::RedeploysController < ApplicationController
  include AppScoped

  rate_limit to: 5, within: 1.minute

  def create
    version = @app.redeploy(actor: current_user)
    redirect_to @app, notice: "Asked CI to deploy #{version} again."
  end
end
