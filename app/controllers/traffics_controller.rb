# Every app's requests at once, as kamal-proxy logs them across the fleet.
class TrafficsController < ApplicationController
  def show
    @proxies = LiveTraffic.proxies(LiveTraffic::FLEET)
    @servers = LiveTraffic.proxy_servers
  end
end
