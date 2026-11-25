class PreviewExpiryJob < ApplicationJob
  queue_as :default

  def perform
    Preview.expired.find_each { it.close(reason: "expired") }
    # A removal whose CI run never reported back: drop the overlay anyway.
    Preview.where(state: "removing").where(updated_at: ..1.day.ago).find_each(&:finish_removal)
  end
end
