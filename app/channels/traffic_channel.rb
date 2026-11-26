# A deployer reading an app's traffic: kamal-proxy's request lines from every
# server the app runs on, only the app's own (LiveTraffic filters them).
# Subscribing, and every ten seconds after, renews the tail leases, as
# LogsChannel does. The servers come from the app, never from the browser.
class TrafficChannel < ApplicationCable::Channel
  include ApplicationCable::Renewal

  periodically every: LogsChannel::RENEW_EVERY do
    next hang_up unless reader&.can_deploy?
    next unless heard_lately?

    LiveTraffic.watch(@app, @proxies)
    @proxies.each { LiveLogs.tail(it, backlog: 0) }
  end

  private
    def subscribed
      @app = find_app
      @proxies = LiveTraffic.proxies(@app) if @app
      return reject if @proxies.blank?

      stream_for @app
      LiveTraffic.watch(@app, @proxies)
      @proxies.each { LiveLogs.tail(it, backlog: LiveLogs::BACKLOG) }
    end

    def find_app
      user, id = reader, params[:app_id]
      App.find_by(id: id) if user&.can_deploy? && id.is_a?(Integer) && LiveLogs.granted?(params[:grant], user, "traffic", id)
    end
end
