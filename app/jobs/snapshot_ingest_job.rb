class SnapshotIngestJob < ApplicationJob
  queue_as :snapshots
  discard_on Snapshot::Rejected, ActiveRecord::RecordNotFound

  def perform(token, payload)
    server = Snapshot.new(payload, token: token).ingest
    Board.refresh_later(server)
  end
end
