# Meridian has one user, and they can do everything.
class RemoveUserRoles < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :role, :string, default: "viewer", null: false
  end
end
