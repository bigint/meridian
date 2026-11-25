# Webhooks keep projects current; this catches anything they missed.
class ReconcileProjectsJob < ApplicationJob
  queue_as :default

  def perform
    Project.find_each(&:sync_later)
  end
end
