# An app's requests, as kamal-proxy logs them on every server it runs on.
class Apps::TrafficsController < ApplicationController
  def show
    @app = App.find(params[:app_id])
    @proxies = LiveTraffic.proxies(@app)
  end
end
