# Who asked for a deploy, kept after that person is removed (actor_id is then
# nulled), as events keep it. Existing deploys take it from their actor, or,
# once the actor is gone, from the deploy or rollback event of their commit.
class AddActorNameToDeploys < ActiveRecord::Migration[8.1]
  def up
    add_column :deploys, :actor_name, :string
    execute <<~SQL
      UPDATE deploys SET actor_name = (
        SELECT COALESCE(NULLIF(users.name, ''), users.email_address) FROM users WHERE users.id = deploys.actor_id)
      WHERE actor_id IS NOT NULL
    SQL
    execute <<~SQL
      UPDATE deploys SET actor_name = (
        SELECT json_extract(events.details, '$.actor_name') FROM events
        WHERE events.subject_type = 'App' AND events.subject_id = deploys.app_id
          AND events.action IN ('app.deploy', 'app.rollback')
          AND json_extract(events.details, '$.commit') = deploys.commit_sha
        ORDER BY events.id LIMIT 1)
      WHERE actor_id IS NULL
    SQL
  end

  def down
    remove_column :deploys, :actor_name
  end
end
