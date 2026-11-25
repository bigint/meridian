require "test_helper"

class DriftTest < ActiveSupport::TestCase
  setup do
    @live = Server.new(last_seen_at: Time.current)
  end

  test "states" do
    assert_equal "in_sync", Drift.state(assigned: true, versions: [ "v2" ], release: "v2", server: @live)
    assert_equal "drifted", Drift.state(assigned: true, versions: [ "v1" ], release: "v2", server: @live)
    assert_equal "drifted", Drift.state(assigned: true, versions: [ "v1", "v2" ], release: "v2", server: @live)
    assert_equal "missing", Drift.state(assigned: true, versions: [], release: "v2", server: @live)
    assert_equal "stray", Drift.state(assigned: false, versions: [ "v1" ], release: "v2", server: @live)
    assert_equal "unknown", Drift.state(assigned: true, versions: [ "v1" ], release: nil, server: @live)
    assert_nil Drift.state(assigned: false, versions: [], release: nil, server: @live)
  end

  test "silent agents make a cell stale and absent agents make it unknown" do
    assert_equal "stale", Drift.state(assigned: true, versions: [ "v2" ], release: "v2", server: Server.new(last_seen_at: 2.minutes.ago))
    assert_equal "unknown", Drift.state(assigned: true, versions: [], release: "v2", server: Server.new)
  end

  test "worst state wins" do
    assert_equal "missing", Drift.worst(%w[ in_sync missing drifted ])
  end
end
