# Every 30 seconds: how Meridian learns of pushes and CI runs. A repository where nothing changed costs GitHub no rate limit (ETags).
class ReconcileProjectsJob < ApplicationJob
  queue_as :default

  def perform
    Project.find_each(&:sync_later)
  end
end
