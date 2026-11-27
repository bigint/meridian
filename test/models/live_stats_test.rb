require "test_helper"

class LiveStatsTest < ActiveSupport::TestCase
  include MemoryCacheHelper

  ID = "0123456789abcdef" * 4

  test "keeps the contract's keys and drops the rest" do
    frame = LiveStats.parse(
      "action" => "stats", "secret" => "x",
      "host" => { "cpu_cores" => 0.21, "cores" => 2, "memory_used" => 7, "memory_total" => 9, "load1" => 0.05, "disk_used" => 1, "disk_total" => 2, "uptime" => 5 },
      "containers" => [ { "id" => ID, "cpu_cores" => 0.003, "memory_used" => 3, "memory_limit" => 4, "net_rx" => 14.7, "net_tx" => 211.3, "disk_read" => 0, "disk_write" => 0, "env" => "x" } ]
    )

    assert_equal %w[ containers host ], frame.keys.sort
    assert_equal %w[ cores cpu_cores disk_total disk_used load1 memory_total memory_used ], frame["host"].keys.sort
    assert_equal %w[ cpu_cores disk_read disk_write id memory_limit memory_used net_rx net_tx ], frame["containers"].first.keys.sort
  end

  test "keeps only finite non-negative numbers" do
    frame = LiveStats.parse(
      "host" => { "cpu_cores" => -1, "cores" => "2", "memory_used" => Float::NAN, "memory_total" => Float::INFINITY, "load1" => nil, "disk_used" => true, "disk_total" => 0 },
      "containers" => [ { "id" => ID, "cpu_cores" => -0.5, "memory_used" => "3", "net_rx" => Float::NAN, "net_tx" => 0.0, "disk_read" => [ 1 ] } ]
    )

    assert_equal({ "disk_total" => 0 }, frame["host"])
    assert_equal [ { "id" => ID, "net_tx" => 0.0 } ], frame["containers"]
  end

  test "drops containers whose id is not a lowercase hex container id" do
    ids = [ "a" * 11, "A" * 12, "g" * 12, "a" * 65, "a;b" + "c" * 10, "", nil, 123, "a" * 12 + "\n", "a" * 12, "a" * 64 ]
    frame = LiveStats.parse("containers" => ids.map { { "id" => it, "cpu_cores" => 1 } })

    assert_equal [ "a" * 12, "a" * 64 ], frame["containers"].map { it["id"] }
  end

  test "keeps at most 500 containers" do
    frame = LiveStats.parse("containers" => Array.new(900) { |i| { "id" => i.to_s(16).rjust(12, "0") } })

    assert_equal 500, frame["containers"].size
  end

  test "a frame without host or containers is still a frame" do
    assert_equal({ "containers" => [] }, LiveStats.parse({}))
    assert_equal({ "containers" => [] }, LiveStats.parse("host" => "x", "containers" => "x"))
    assert_equal({ "containers" => [] }, LiveStats.parse("host" => { "uptime" => 1 }, "containers" => [ "x", nil, [] ]))
  end

  test "anything that is not a hash is not a frame" do
    [ nil, "stats", 1, [ { "host" => {} } ] ].each { assert_nil LiveStats.parse(it) }
  end

  test "the lease runs out" do
    server = Server.create!(name: "a", hostname: "a")
    assert_equal 0, LiveStats.lease_remaining(server)

    freeze_time do
      LiveStats.watch(server)
      assert_equal 30, LiveStats.lease_remaining(server)

      travel 12.seconds
      assert_equal 18, LiveStats.lease_remaining(server)

      travel 19.seconds
      assert_equal 0, LiveStats.lease_remaining(server)
    end
  end
end
