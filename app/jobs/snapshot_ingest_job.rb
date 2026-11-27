class SnapshotIngestJob < ApplicationJob
  queue_as :snapshots
  discard_on Snapshot::Rejected

  def perform(token, payload)
    Snapshot.new(payload, token: token).ingest
  end
end
