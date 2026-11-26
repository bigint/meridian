class PreviewExpiryJob < ApplicationJob
  queue_as :default

  def perform
    Preview.expired.find_each { each_preview(it) { it.close(reason: "expired") } }
    # A removal whose CI run never reported back: drop the overlay anyway.
    Preview.where(state: "removing").where(updated_at: ..1.day.ago).find_each { each_preview(it, &:finish_removal) }
  end

  private
    # One project GitHub refuses (an uninstalled App, a missing workflow)
    # mustn't stop every other preview from expiring.
    def each_preview(preview)
      yield preview
    rescue GitHost::Error => error
      Rails.logger.warn("Preview #{preview.app.name} ##{preview.pr_number} not expired: #{error.message}")
    end
end
