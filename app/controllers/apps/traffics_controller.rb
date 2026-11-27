# An app's requests, as kamal-proxy logs them on every server it runs on.
class Apps::TrafficsController < ApplicationController
  include AppScoped

  def show
    @proxies = LiveTraffic.proxies(@app)
  end
end
