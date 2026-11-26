# Which CI runs a preview has seen, so a replayed run from before its latest
# dispatch can't undo that dispatch, and how many times removal was asked
# for, so expiry stops asking after a few failures.
class AddRunTrackingToPreviews < ActiveRecord::Migration[8.1]
  def change
    add_column :previews, :latest_run_id, :bigint
    add_column :previews, :dispatched_after_run_id, :bigint
    add_column :previews, :remove_attempts, :integer, default: 0, null: false
  end
end
