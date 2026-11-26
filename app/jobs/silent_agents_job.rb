# Agents that stop talking send no snapshots, and snapshots that change
# nothing don't redraw. So once a minute this redraws every group with a
# quiet agent: its cells turn stale, and "quiet for 3 minutes" keeps counting.
class SilentAgentsJob < ApplicationJob
  queue_as :default

  def perform
    Server.silent.find_each { Board.refresh_later(it) }
  end
end
