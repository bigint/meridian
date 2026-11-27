class CreateMeridian < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :name
      t.string :email_address, null: false, index: { unique: true }
      t.string :password_digest, null: false
      t.timestamps
    end

    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent
      t.timestamps
    end

    create_table :accounts do |t|
      t.string :location_name
      t.float :latitude
      t.float :longitude
      t.timestamps
    end

    create_table :projects do |t|
      t.string :name, null: false
      t.string :git_host, null: false, default: "github"
      t.string :repo_full_name, null: false, index: { unique: true }
      t.string :default_branch, null: false, default: "main"
      t.bigint :installation_id
      t.json :config_globs, null: false, default: [ "config/deploy*.yml" ]
      t.boolean :direct_commits, null: false, default: false
      t.string :last_synced_sha
      t.datetime :synced_at
      t.json :config_errors, null: false, default: []
      t.string :parse_failed_sha
      t.integer :parse_failures, null: false, default: 0
      t.timestamps
    end

    create_table :apps do |t|
      t.references :project, null: false, foreign_key: true, index: false
      t.string :service, null: false, index: true
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
    end

    create_table :servers do |t|
      t.string :machine_id, index: { unique: true }
      t.string :name, null: false, index: true
      t.string :hostname, null: false, index: true
      t.json :labels, null: false, default: {}
      t.float :latitude
      t.float :longitude
      t.string :agent_version
      t.integer :interval_seconds
      t.datetime :last_seen_at
      t.timestamps
    end

    create_table :assignments do |t|
      t.references :app, null: false, foreign_key: true, index: false
      t.references :server, null: false, foreign_key: true
      t.string :role, null: false
      t.timestamps
      t.index %i[ app_id server_id role ], unique: true
    end

    create_table :placements do |t|
      t.references :server, null: false, foreign_key: true, index: false
      t.references :app, foreign_key: true
      t.string :container_id, null: false
      t.string :name, null: false
      t.string :kind, null: false, default: "app"
      t.string :service
      t.string :role
      t.string :destination, null: false, default: ""
      t.string :image
      t.string :version
      t.string :state
      t.string :health
      t.datetime :started_at
      t.datetime :observed_at, null: false
      t.index %i[ server_id container_id ], unique: true
    end

    create_table :releases do |t|
      t.references :app, null: false, foreign_key: true, index: false
      t.string :version, null: false
      t.string :commit_sha, null: false
      t.string :author
      t.datetime :committed_at, null: false
      t.string :message
      t.timestamps
      t.index %i[ app_id commit_sha ], unique: true
      t.index %i[ app_id committed_at ]
    end

    create_table :deploys do |t|
      t.references :app, null: false, foreign_key: true, index: false
      t.references :release, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :kind, null: false, default: "deploy"
      t.string :version, null: false
      t.string :commit_sha, null: false, index: true
      t.string :status, null: false, default: "pending"
      t.string :conclusion
      t.bigint :ci_run_id
      t.string :ci_url
      t.datetime :ci_updated_at
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index %i[ app_id commit_sha ], unique: true
    end

    # Names only. There is no value column and there never will be: a test
    # fails if one appears.
    create_table :secret_names do |t|
      t.references :project, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.json :apps, null: false, default: []
      t.datetime :last_set_at
      t.timestamps
      t.index %i[ project_id name ], unique: true
    end

    create_table :agent_tokens do |t|
      t.references :server, foreign_key: true
      t.string :label, null: false
      t.string :digest, null: false, index: { unique: true }
      t.boolean :fleet, null: false, default: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end

    create_table :events do |t|
      t.references :actor, foreign_key: { to_table: :users }
      t.string :action, null: false, index: true
      t.references :subject, polymorphic: true
      t.json :details, null: false, default: {}
      t.datetime :created_at, null: false, index: true
    end
  end
end
