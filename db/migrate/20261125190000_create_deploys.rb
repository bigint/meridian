class CreateDeploys < ActiveRecord::Migration[8.1]
  def change
    create_table :deploys do |t|
      t.references :app, null: false, foreign_key: true
      t.references :release, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :version, null: false
      t.string :commit_sha, null: false
      t.string :kind, null: false, default: "deploy"
      t.bigint :ci_run_id
      t.string :ci_url
      t.string :status, null: false, default: "pending"
      t.string :conclusion
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index %i[ app_id commit_sha ], unique: true
      t.index :commit_sha
      t.index :ci_run_id
    end
  end
end
