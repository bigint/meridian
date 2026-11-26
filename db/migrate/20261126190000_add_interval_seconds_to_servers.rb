# The agent's snapshot interval, so a server set to report every minute isn't
# called stale between reports. Nil for agents too old to send it: 15 seconds.
class AddIntervalSecondsToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :interval_seconds, :integer
  end
end
