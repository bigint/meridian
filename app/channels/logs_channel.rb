# A deployer reading container logs. Subscribing, and every ten seconds
# after while the page still renews, renews the tail lease that makes each
# container's agent stream.
# Logs can hold secrets, so unlike stats this is for deployers only.
class LogsChannel < ApplicationCable::Channel
  include ApplicationCable::Renewal

  MAX_PLACEMENTS = 20
  RENEW_EVERY = 10.seconds

  periodically every: RENEW_EVERY do
    next hang_up unless reader&.can_deploy?
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
      user, ids = reader, params[:placement_ids]
      return unless user&.can_deploy? && ids.is_a?(Array) && ids.size <= MAX_PLACEMENTS && ids.all?(Integer)
      return unless LiveLogs.granted?(params[:grant], user, "logs", *ids) # only what a page recorded as viewed

      Placement.includes(:server).where(id: ids).to_a
    end
end
