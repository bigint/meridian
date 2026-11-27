# An agent says this container is on this server. Rows are upserted from
# snapshots and deleted when a container disappears; never appended.
class Placement < ApplicationRecord
  belongs_to :server
  belongs_to :app, optional: true

  scope :running, -> { where(state: "running") }
  scope :running_first, -> { order(Arel.sql("state = 'running' DESC"), :id) }

  # What runs now, without the stopped containers Kamal keeps for rollback
  # (retain_containers, 5 by default) and the "_replaced_" ones a redeploy
  # leaves. Per server, service, role and destination: every running
  # container, else the newest stopped one, so an app that went down still
  # shows, as stopped.
  scope :current, -> {
    where(state: "running").or(where(<<~SQL.squish))
      NOT EXISTS (
        SELECT 1 FROM placements newer
        WHERE newer.server_id = placements.server_id AND newer.kind = placements.kind
          AND newer.service IS placements.service AND newer.role IS placements.role
          AND newer.destination = placements.destination AND newer.id != placements.id
          AND (newer.state = 'running'
            OR COALESCE(newer.started_at, '') > COALESCE(placements.started_at, '')
            OR (COALESCE(newer.started_at, '') = COALESCE(placements.started_at, '') AND newer.id > placements.id)))
    SQL
  }

  def running?
    state == "running"
  end

  def short_version
    version.to_s.first(12)
  end
end
