# Each of these is the leading column of a composite index on the same table,
# or serves no query.
class RemoveRedundantIndexes < ActiveRecord::Migration[8.1]
  def change
    remove_index :apps, :project_id
    remove_index :assignments, :app_id
    remove_index :deploys, :app_id
    remove_index :deploys, :ci_run_id
    remove_index :placements, :server_id
    remove_index :placements, [ :service, :role, :destination ]
    remove_index :previews, :app_id
    remove_index :releases, :app_id
    remove_index :secret_names, :project_id
  end
end
