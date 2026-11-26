# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_26_210000) do
  create_table "accounts", force: :cascade do |t|
    t.string "name", default: "Meridian", null: false
    t.string "preview_domain"
    t.integer "preview_ttl_days", default: 7, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "preview_selector"
    t.float "latitude"
    t.float "longitude"
    t.string "location_name"
    t.string "preview_hostnames", default: "nested", null: false
  end

  create_table "agent_tokens", force: :cascade do |t|
    t.integer "server_id"
    t.string "digest", null: false
    t.string "label", null: false
    t.boolean "fleet", default: false, null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["digest"], name: "index_agent_tokens_on_digest", unique: true
    t.index ["server_id"], name: "index_agent_tokens_on_server_id"
  end

  create_table "apps", force: :cascade do |t|
    t.integer "project_id", null: false
    t.string "service", null: false
    t.string "config_path", null: false
    t.string "destination", default: "", null: false
    t.string "kind", default: "other", null: false
    t.string "image"
    t.json "hostnames", default: [], null: false
    t.json "roles", default: [], null: false
    t.json "accessories", default: [], null: false
    t.json "secret_names", default: [], null: false
    t.string "version_path"
    t.json "source_shas", default: {}, null: false
    t.string "source_repo"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "config_path", "destination"], name: "index_apps_on_project_id_and_config_path_and_destination", unique: true
    t.index ["service"], name: "index_apps_on_service"
  end

  create_table "assignments", force: :cascade do |t|
    t.integer "app_id", null: false
    t.integer "server_id", null: false
    t.string "role", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "server_id", "role"], name: "index_assignments_on_app_id_and_server_id_and_role", unique: true
    t.index ["server_id"], name: "index_assignments_on_server_id"
  end

  create_table "deploys", force: :cascade do |t|
    t.integer "app_id", null: false
    t.integer "release_id"
    t.integer "actor_id"
    t.string "version", null: false
    t.string "commit_sha", null: false
    t.string "kind", default: "deploy", null: false
    t.bigint "ci_run_id"
    t.string "ci_url"
    t.string "status", default: "pending", null: false
    t.string "conclusion"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "ci_updated_at"
    t.string "actor_name"
    t.index ["actor_id"], name: "index_deploys_on_actor_id"
    t.index ["app_id", "commit_sha"], name: "index_deploys_on_app_id_and_commit_sha", unique: true
    t.index ["commit_sha"], name: "index_deploys_on_commit_sha"
    t.index ["release_id"], name: "index_deploys_on_release_id"
  end

  create_table "events", force: :cascade do |t|
    t.integer "actor_id"
    t.string "action", null: false
    t.string "subject_type"
    t.integer "subject_id"
    t.json "details", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["action"], name: "index_events_on_action"
    t.index ["actor_id"], name: "index_events_on_actor_id"
    t.index ["created_at"], name: "index_events_on_created_at"
    t.index ["subject_type", "subject_id"], name: "index_events_on_subject"
  end

  create_table "placements", force: :cascade do |t|
    t.integer "server_id", null: false
    t.integer "app_id"
    t.string "container_id", null: false
    t.string "name", null: false
    t.string "service"
    t.string "role"
    t.string "destination", default: "", null: false
    t.string "kind", default: "app", null: false
    t.string "image"
    t.string "version"
    t.string "state"
    t.string "health"
    t.datetime "started_at"
    t.datetime "observed_at", null: false
    t.index ["app_id"], name: "index_placements_on_app_id"
    t.index ["server_id", "container_id"], name: "index_placements_on_server_id_and_container_id", unique: true
  end

  create_table "previews", force: :cascade do |t|
    t.integer "app_id", null: false
    t.integer "pr_number", null: false
    t.string "pr_url"
    t.string "head_sha"
    t.string "destination", null: false
    t.string "hostname", null: false
    t.string "overlay_path", null: false
    t.string "state", default: "deploying", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "latest_run_id"
    t.bigint "dispatched_after_run_id"
    t.integer "remove_attempts", default: 0, null: false
    t.index ["app_id", "pr_number"], name: "index_previews_on_app_id_and_pr_number", unique: true
    t.index ["state"], name: "index_previews_on_state"
  end

  create_table "projects", force: :cascade do |t|
    t.string "name", null: false
    t.string "git_host", default: "github", null: false
    t.string "repo_full_name", null: false
    t.string "default_branch", default: "main", null: false
    t.bigint "installation_id"
    t.json "config_globs", default: ["config/deploy*.yml"], null: false
    t.string "last_synced_sha"
    t.datetime "synced_at"
    t.json "config_errors", default: [], null: false
    t.boolean "direct_commits", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "parse_failed_sha"
    t.integer "parse_failures", default: 0, null: false
    t.index ["repo_full_name"], name: "index_projects_on_repo_full_name", unique: true
  end

  create_table "releases", force: :cascade do |t|
    t.integer "app_id", null: false
    t.string "version", null: false
    t.string "commit_sha", null: false
    t.string "author"
    t.datetime "committed_at", null: false
    t.string "message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "commit_sha"], name: "index_releases_on_app_id_and_commit_sha", unique: true
    t.index ["app_id", "committed_at"], name: "index_releases_on_app_id_and_committed_at"
  end

  create_table "secret_names", force: :cascade do |t|
    t.integer "project_id", null: false
    t.string "name", null: false
    t.json "apps", default: [], null: false
    t.datetime "last_set_at"
    t.integer "last_set_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["last_set_by_id"], name: "index_secret_names_on_last_set_by_id"
    t.index ["project_id", "name"], name: "index_secret_names_on_project_id_and_name", unique: true
  end

  create_table "servers", force: :cascade do |t|
    t.string "machine_id"
    t.string "name", null: false
    t.string "hostname", null: false
    t.json "labels", default: {}, null: false
    t.string "agent_version"
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.float "latitude"
    t.float "longitude"
    t.integer "interval_seconds"
    t.index ["hostname"], name: "index_servers_on_hostname"
    t.index ["machine_id"], name: "index_servers_on_machine_id", unique: true
    t.index ["name"], name: "index_servers_on_name"
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.string "role", default: "viewer", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "agent_tokens", "servers"
  add_foreign_key "apps", "projects"
  add_foreign_key "assignments", "apps"
  add_foreign_key "assignments", "servers"
  add_foreign_key "deploys", "apps"
  add_foreign_key "deploys", "releases"
  add_foreign_key "deploys", "users", column: "actor_id"
  add_foreign_key "events", "users", column: "actor_id"
  add_foreign_key "placements", "apps"
  add_foreign_key "placements", "servers"
  add_foreign_key "previews", "apps"
  add_foreign_key "releases", "apps"
  add_foreign_key "secret_names", "projects"
  add_foreign_key "secret_names", "users", column: "last_set_by_id"
  add_foreign_key "sessions", "users"
end
