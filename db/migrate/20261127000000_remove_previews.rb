# Previews are out of the first release (decision 43).
class RemovePreviews < ActiveRecord::Migration[8.1]
  def up
    drop_table :previews
    remove_column :accounts, :preview_domain
    remove_column :accounts, :preview_hostnames
    remove_column :accounts, :preview_selector
    remove_column :accounts, :preview_ttl_days
  end
end
