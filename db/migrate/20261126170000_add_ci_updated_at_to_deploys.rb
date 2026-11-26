# When GitHub last changed the run a deploy follows, so a late or replayed
# workflow_run delivery can't move the deploy back to an older state.
class AddCiUpdatedAtToDeploys < ActiveRecord::Migration[8.1]
  def change
    add_column :deploys, :ci_updated_at, :datetime
  end
end
