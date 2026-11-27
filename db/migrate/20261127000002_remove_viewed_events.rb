# Opening the logs or traffic pages no longer records an event.
class RemoveViewedEvents < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM events WHERE action IN ('logs.viewed', 'traffic.viewed')"
  end

  def down
  end
end
