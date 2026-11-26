class AddPreviewHostnamesToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :preview_hostnames, :string, default: "nested", null: false
  end
end
