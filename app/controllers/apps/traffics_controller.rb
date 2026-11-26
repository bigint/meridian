# An app's requests, as kamal-proxy logs them on every server it runs on.
class Apps::TrafficsController < ApplicationController
  require_deployer

  def show
    @app = App.find(params[:app_id])
    @proxies = LiveTraffic.proxies(@app)
    Event.record("traffic.viewed", subject: @app,
      summary: "Viewed the traffic of #{@app.name} (kamal-proxy on #{helpers.pluralize(@proxies.size, "server")})")
  end
end
