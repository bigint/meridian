# One rollout of one app, as CI ran it. Meridian creates the row when it makes
# the commit; polling GitHub's workflow runs moves it along. Progress per server
# is read from agents, not stored: a server is done when it runs the version.
class Deploy < ApplicationRecord
  STATUSES = %w[ pending queued in_progress completed ].freeze
  # A deploy CI hasn't started a run for in this long never will: the
  # workflow is missing, or the commit didn't trigger it.
  UNCLAIMED_AFTER = 15.minutes

  belongs_to :app
  belongs_to :release, optional: true
  belongs_to :actor, class_name: "User", optional: true

  scope :recent, -> { order(created_at: :desc) }
  # Under way: CI is running it, or may still pick it up.
  scope :active, -> { where.not(status: "completed").where.not(ci_run_id: nil).or(where(ci_run_id: nil, created_at: UNCLAIMED_AFTER.ago..)) }

  after_commit -> { broadcast_refresh_later_to app }

  # Who asked for it. A deploy with no person behind it came from Git.
  def requested_by
    actor&.display_name || "Git"
  end

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

  # A redeploy is a dispatched run named "deploy <config> [<destination>]".
  def self.from_dispatch(project, run)
    command, config, destination = run["display_title"].to_s.split(" ", 3)
    return unless command == "deploy"

    app = project.apps.find_by(config_path: config, destination: destination.to_s.strip) or return
    deploy = app.deploys.find_or_initialize_by(commit_sha: run["head_sha"])
    deploy.kind = "redeploy" if deploy.new_record?
    deploy.version ||= app.latest_release&.version || run["head_sha"].first(7)
    deploy.started_at = nil if deploy.ci_run_id != run["id"]
    deploy.track(run)
    deploy
  end

  # Every poll sees a run again, and a state older than the one recorded
  # changes nothing. A run that finishes, or a re-run that finishes again,
  # goes into the activity trail once. Run ids only grow, so an older run never takes over
  # from a newer one: a redeploy made at another app's deploy commit keeps
  # its own run.
  def track(run)
    return if stale?(run)

    self.ci_run_id = run["id"]
    self.ci_url = run["html_url"]
    self.status = status_of(run)
    self.conclusion = run["conclusion"]
    self.started_at ||= run["run_started_at"]
    self.finished_at = run["updated_at"] if status == "completed"
    self.ci_updated_at = run["updated_at"]
    save!
    record_outcome if finished? && (saved_change_to_finished_at? || saved_change_to_ci_run_id?)
  end

  # What CI made of it, for the activity trail. Meridian records the request
  # when someone asks for a deploy; this is how it ended, however it started.
  def record_outcome(at: Time.current)
    Event.create!(action: "app.#{kind}.#{conclusion.presence || "finished"}", subject: app, actor: actor, created_at: at,
      details: { summary: outcome_summary, by: requested_by, version: version, commit: commit_sha, ci_url: ci_url }.compact)
  end

  def finished? = status == "completed"
  def succeeded? = conclusion == "success"

  def unclaimed? = ci_run_id.nil? && created_at < UNCLAIMED_AFTER.ago

  def state_label
    if finished? then conclusion.to_s.humanize.presence || "Finished"
    elsif unclaimed? then "Not started by CI"
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

  private
    def outcome_summary
      what = { "deploy" => "Deploy of #{app.name} at", "redeploy" => "Redeploy of #{app.name} at", "rollback" => "Rollback of #{app.name} to" }
        .fetch(kind, "#{kind.humanize} of #{app.name} at")
      outcome = { "success" => "succeeded", "failure" => "failed", "cancelled" => "was cancelled", "timed_out" => "timed out" }
        .fetch(conclusion.to_s) { "ended: #{conclusion.to_s.humanize(capitalize: false).presence || "no conclusion"}" }
      "#{what} #{version} #{outcome}"
    end

    def status_of(run)
      STATUSES.include?(run["status"]) ? run["status"] : "in_progress"
    end

    def stale?(run)
      return false unless ci_run_id
      return run["id"].to_i < ci_run_id if run["id"].to_i != ci_run_id

      updated = run["updated_at"]&.to_time
      return false unless updated && ci_updated_at
      updated < ci_updated_at || (updated == ci_updated_at && STATUSES.index(status_of(run)) < STATUSES.index(status))
    end
end
