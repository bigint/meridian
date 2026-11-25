# Names only. There is no value column and there never will be: a test fails
# if one appears.
class CreateSecretNames < ActiveRecord::Migration[8.1]
  def change
    create_table :secret_names do |t|
      t.references :project, null: false, foreign_key: true
      t.string :name, null: false
      t.json :apps, null: false, default: []
      t.datetime :last_set_at
      t.references :last_set_by, foreign_key: { to_table: :users }
      t.timestamps
      t.index %i[ project_id name ], unique: true
    end
  end
end
