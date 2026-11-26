class SnapshotIngestJob < ApplicationJob
  queue_as :snapshots
  discard_on Snapshot::Rejected, ActiveRecord::RecordNotFound

  def perform(token, payload)
    Snapshot.new(payload, token: token).ingest
  end
end
