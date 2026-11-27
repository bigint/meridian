class Apps::DeploysController < ApplicationController
  include AppScoped

  rate_limit to: 10, within: 1.minute

  def create
    @app.deploy(params.expect(deploy: [ :version ])[:version], actor: current_user)
    redirect_to @app, notice: "Committed. CI will deploy it."
  end
end
