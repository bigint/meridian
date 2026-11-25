class CreateMeridianSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string :name, null: false, default: "Meridian"
      t.string :preview_domain
      t.integer :preview_ttl_days, null: false, default: 7
      t.timestamps
    end

    add_column :users, :name, :string
    add_column :users, :role, :string, null: false, default: "viewer"

    create_table :identities do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :uid, null: false
      t.timestamps
      t.index %i[ provider uid ], unique: true
    end

    create_table :projects do |t|
      t.string :name, null: false
      t.string :git_host, null: false, default: "github"
      t.string :repo_full_name, null: false
      t.string :default_branch, null: false, default: "main"
      t.bigint :installation_id
      t.json :config_globs, null: false, default: [ "config/deploy*.yml" ]
      t.string :last_synced_sha
      t.datetime :synced_at
      t.json :config_errors, null: false, default: []
      t.boolean :direct_commits, null: false, default: false
      t.timestamps
      t.index :repo_full_name, unique: true
    end

    create_table :apps do |t|
      t.references :project, null: false, foreign_key: true
      t.string :service, null: false
      t.string :config_path, null: false
      t.string :destination, null: false, default: ""
      t.string :kind, null: false, default: "other"
      t.string :image
      t.json :hostnames, null: false, default: []
      t.json :roles, null: false, default: []
      t.json :accessories, null: false, default: []
      t.json :secret_names, null: false, default: []
      t.string :version_path
      t.json :source_shas, null: false, default: {}
      t.string :source_repo
      t.timestamps
      t.index %i[ project_id config_path destination ], unique: true
      t.index :service
    end

    create_table :servers do |t|
      t.string :machine_id
      t.string :name, null: false
      t.string :hostname, null: false
      t.json :labels, null: false, default: {}
      t.string :agent_version
      t.datetime :last_seen_at
      t.timestamps
      t.index :machine_id, unique: true
      t.index :hostname
      t.index :name
    end

    create_table :assignments do |t|
      t.references :app, null: false, foreign_key: true
      t.references :server, null: false, foreign_key: true
      t.string :role, null: false
      t.timestamps
      t.index %i[ app_id server_id role ], unique: true
    end

    create_table :placements do |t|
      t.references :server, null: false, foreign_key: true
      t.references :app, foreign_key: true
      t.string :container_id, null: false
      t.string :name, null: false
      t.string :service
      t.string :role
      t.string :destination, null: false, default: ""
      t.string :kind, null: false, default: "app"
      t.string :image
      t.string :version
      t.string :state
      t.string :health
      t.datetime :started_at
      t.datetime :observed_at, null: false
      t.index %i[ server_id container_id ], unique: true
      t.index %i[ service role destination ]
    end

    create_table :releases do |t|
      t.references :app, null: false, foreign_key: true
      t.string :version, null: false
      t.string :commit_sha, null: false
      t.string :author
      t.datetime :committed_at, null: false
      t.string :message
      t.timestamps
      t.index %i[ app_id commit_sha ], unique: true
      t.index %i[ app_id committed_at ]
    end

    create_table :agent_tokens do |t|
      t.references :server, foreign_key: true
      t.string :digest, null: false
      t.string :label, null: false
      t.boolean :fleet, null: false, default: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
      t.index :digest, unique: true
    end

    create_table :events do |t|
      t.references :actor, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.references :subject, polymorphic: true
      t.json :details, null: false, default: {}
      t.datetime :created_at, null: false
      t.index :action
      t.index :created_at
    end
  end
end
