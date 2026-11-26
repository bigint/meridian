# Every 30 seconds: catches what webhooks missed, or everything when there are
# none. A repository where nothing changed costs GitHub no rate limit (ETags).
class ReconcileProjectsJob < ApplicationJob
  queue_as :default

  def perform
    Project.find_each(&:sync_later)
  end
end
