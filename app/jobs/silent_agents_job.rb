# Agents that stop talking send no snapshots, so nothing would redraw the
# board when their cells turn stale. This refreshes the groups that just did.
class SilentAgentsJob < ApplicationJob
  queue_as :default

  def perform
    Server.where(last_seen_at: (Server::STALE_AFTER + 1.minute).ago..Server::STALE_AFTER.ago).find_each { Board.refresh_later(it) }
  end
end
