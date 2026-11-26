# CI runs on the default branch become deploys. A run arrives from a
# workflow_run webhook, from polling, or from both; handling it again changes nothing.
module Project::WorkflowRuns
  extend ActiveSupport::Concern

  def track_workflow_run(run)
    return unless run["head_branch"] == default_branch
    return Preview.track(run) || Deploy.from_dispatch(self, run) if run["event"] == "workflow_dispatch"

    sync if last_synced_sha != run["head_sha"]
    Deploy.from_workflow_run(self, run)
  end

  # Tracks the runs that changed since the last poll, oldest first. The
  # watermark is GitHub's own updated_at, so clocks never need to agree.
  def poll_workflow_runs
    key = [ "project", id, "workflow_runs_seen_at" ]
    seen = Rails.cache.read(key)
    runs = git.workflow_runs.reverse.select { seen.nil? || it["updated_at"].to_time >= seen }

    runs.each { track_workflow_run(it) }
    Rails.cache.write(key, runs.map { it["updated_at"].to_time }.max) if runs.any?
  end
end
