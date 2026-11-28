# Someone reading traffic: kamal-proxy's request lines from every server an
# app runs on, only the app's own, or for the Traffic page in the sidebar,
# every app's (LiveTraffic filters them). Subscribing, and every ten seconds
# after, renews the tail leases, as LogsChannel does. The servers come from
# the app or the fleet, never from the browser.
class TrafficChannel < ApplicationCable::Channel
  include ApplicationCable::Renewal

  periodically every: RENEW_EVERY do
    next unless heard_lately?

    LiveTraffic.watch(@subject, @proxies)
    @proxies.each { LiveLogs.tail(it, backlog: 0) }
  end

  private
    def subscribed
      @subject = find_subject
      @proxies = LiveTraffic.proxies(@subject) if @subject
      return reject if @proxies.blank?

      stream_for @subject
      LiveTraffic.watch(@subject, @proxies)
      @proxies.each { LiveLogs.tail(it, backlog: 0) } # live only: LiveTraffic drops history
    end

    # An app, or LiveTraffic::FLEET, as the page's grant names it.
    def find_subject
      if params[:fleet] == true
        LiveTraffic::FLEET if granted?(LiveTraffic::FLEET)
      else
        id = params[:app_id]
        App.find_by(id: id) if id.is_a?(Integer) && granted?(id)
      end
    end

    def granted?(subject) = LiveGrant.granted?(params[:grant], current_user, "traffic", subject)
end
