# An agent says this container is on this server. Rows are upserted from
# snapshots and deleted when a container disappears; never appended.
class Placement < ApplicationRecord
  belongs_to :server
  belongs_to :app, optional: true

  scope :running, -> { where(state: "running") }
  scope :unhealthy, -> { where(health: "unhealthy") }

  def running?
    state == "running"
  end

  def short_version
    version.to_s.first(12)
  end
end
