# A deployer reading an app's traffic: kamal-proxy's request lines from every
# server the app runs on, only the app's own (LiveTraffic filters them).
# Subscribing, and every ten seconds after, renews the tail leases, as
# LogsChannel does. The servers come from the app, never from the browser.
class TrafficChannel < ApplicationCable::Channel
  def subscribed
    @app = find_app
    @proxies = LiveTraffic.proxies(@app) if @app
    return reject if @proxies.blank?

    stream_for @app
    LiveTraffic.watch(@app, @proxies)
    @proxies.each { LiveLogs.tail(it, backlog: LiveLogs::BACKLOG) }
  end

  periodically every: LogsChannel::RENEW_EVERY do
    LiveTraffic.watch(@app, @proxies)
    @proxies.each { LiveLogs.tail(it, backlog: 0) }
  end

  private
    def find_app
      App.find_by(id: params[:app_id]) if connection.current_user&.can_deploy? && params[:app_id].is_a?(Integer)
    end
end
