# A deployer reading container logs. Subscribing, and every ten seconds
# after, renews the tail lease that makes each container's agent stream.
# Logs can hold secrets, so unlike stats this is for deployers only.
class LogsChannel < ApplicationCable::Channel
  MAX_PLACEMENTS = 20
  RENEW_EVERY = 10.seconds

  periodically every: RENEW_EVERY do
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
      return unless connection.current_user&.can_deploy?

      ids = params[:placement_ids]
      Placement.includes(:server).where(id: ids).to_a if ids.is_a?(Array) && ids.size <= MAX_PLACEMENTS && ids.all?(Integer)
    end
end
