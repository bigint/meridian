# Someone reading container logs. Subscribing, and every ten seconds
# after while the page still renews, renews the tail lease that makes each
# container's agent stream.
class LogsChannel < ApplicationCable::Channel
  include ApplicationCable::Renewal

  RENEW_EVERY = 10.seconds

  periodically every: RENEW_EVERY do
    next unless heard_lately?

    @placements.each { LiveLogs.tail(it, backlog: 0) }
  end

  private
    def subscribed
      @placements = find_placements
      return reject if @placements.blank?

      @placements.each do |placement|
        stream_for placement
        LiveLogs.tail(placement, backlog: LiveLogs::BACKLOG)
      end
    end

    def find_placements
      ids = params[:placement_ids]
      return unless ids.is_a?(Array) && ids.size <= LiveLogs::MAX_PLACEMENTS && ids.all?(Integer)
      return unless LiveGrant.granted?(params[:grant], current_user, "logs", *ids) # only what a page granted

      Placement.includes(:server).where(id: ids).to_a
    end
end
