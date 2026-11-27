class Apps::RollbacksController < ApplicationController
  include AppScoped

  rate_limit to: 10, within: 1.minute

  def create
    deploy = @app.roll_back(@app.releases.find(params.expect(:release_id)), actor: current_user)
    redirect_to @app, notice: "Committed a revert to #{deploy.version}. CI will deploy it."
  end
end
