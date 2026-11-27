# A commit that changed what an app should run.
class Release < ApplicationRecord
  belongs_to :app

  # Newest first. Commits that landed in the same second, as a rebase-merge
  # makes them, are told apart by id: App#record_releases inserts oldest first.
  scope :newest_first, -> { order(committed_at: :desc, id: :desc) }
  scope :latest_per_app, -> { where("releases.id = (SELECT r.id FROM releases r WHERE r.app_id = releases.app_id ORDER BY r.committed_at DESC, r.id DESC LIMIT 1)") }

  def short_sha
    commit_sha.first(7)
  end

  def short_version
    version.first(12)
  end
end
