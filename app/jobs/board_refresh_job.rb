# The refresh at the end of a throttled window (Board.refresh_stream_later).
class BoardRefreshJob < ApplicationJob
  queue_as :default

  def perform(key)
    Board.refresh_now(key)
  end
end
