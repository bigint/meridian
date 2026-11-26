class SnapshotIngestJob < ApplicationJob
  queue_as :snapshots
  discard_on Snapshot::Rejected, ActiveRecord::RecordNotFound

  def perform(token, payload)
    snapshot = Snapshot.new(payload, token: token)
    server = snapshot.ingest
    Board.refresh_later(server) if snapshot.changed?
  end
end
