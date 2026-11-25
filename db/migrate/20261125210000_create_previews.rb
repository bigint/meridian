class CreatePreviews < ActiveRecord::Migration[8.1]
  def change
    create_table :previews do |t|
      t.references :app, null: false, foreign_key: true
      t.integer :pr_number, null: false
      t.string :pr_url
      t.string :head_sha
      t.string :destination, null: false
      t.string :hostname, null: false
      t.string :overlay_path, null: false
      t.string :state, null: false, default: "deploying"
      t.datetime :expires_at, null: false
      t.timestamps
      t.index %i[ app_id pr_number ], unique: true
      t.index :state
    end

    add_column :accounts, :preview_selector, :string
  end
end
