# A commit that changed what an app should run.
class Release < ApplicationRecord
  belongs_to :app

  scope :latest_per_app, -> { where("committed_at = (SELECT MAX(r.committed_at) FROM releases r WHERE r.app_id = releases.app_id)") }

  def short_sha
    commit_sha.first(7)
  end

  def short_version
    version.first(12)
  end
end
