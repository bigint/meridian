# One rollout of one app, as CI ran it. Meridian creates the row when it makes
# the commit; GitHub's workflow_run webhooks move it along. Progress per server
# is read from agents, not stored: a server is done when it runs the version.
class Deploy < ApplicationRecord
  STATUSES = %w[ pending queued in_progress completed ].freeze

  belongs_to :app
  belongs_to :release, optional: true
  belongs_to :actor, class_name: "User", optional: true

  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where.not(status: "completed") }

  after_commit -> { broadcast_refresh_later_to app }

  def self.from_workflow_run(project, run)
    sha = run["head_sha"]
    apps = project.apps.joins(:releases).where(releases: { commit_sha: sha }).distinct.to_a
    apps |= project.apps.joins(:deploys).where(deploys: { commit_sha: sha }).distinct.to_a

    apps.map do |app|
      deploy = app.deploys.find_or_initialize_by(commit_sha: sha)
      deploy.release ||= app.releases.find_by(commit_sha: sha)
      deploy.version ||= deploy.release&.version || sha.first(7)
      deploy.track(run)
      deploy
    end
  end

  def track(run)
    self.ci_run_id = run["id"]
    self.ci_url = run["html_url"]
    self.status = STATUSES.include?(run["status"]) ? run["status"] : "in_progress"
    self.conclusion = run["conclusion"]
    self.started_at ||= run["run_started_at"]
    self.finished_at = run["updated_at"] if status == "completed"
    save!
  end

  def finished? = status == "completed"
  def succeeded? = conclusion == "success"
  def rollback? = kind == "rollback"

  def state_label
    if finished? then conclusion.to_s.humanize.presence || "Finished"
    else status.humanize
    end
  end

  # [ [server, running_versions, done?] ] from what agents report right now.
  def progress
    running = app.placements.running.pluck(:server_id, :version).group_by(&:first)
    app.servers.ordered.map do |server|
      versions = Array(running[server.id]).map(&:last)
      [ server, versions, versions.include?(version) ]
    end
  end
end
