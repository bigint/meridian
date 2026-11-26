class PreviewExpiryJob < ApplicationJob
  queue_as :default

  def perform
    Preview.expire_all
  end
end
