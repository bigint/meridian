require "test_helper"

class LiveLogsTest < ActiveSupport::TestCase
  include MemoryCacheHelper, ActionCable::TestHelper

  LINE = { "t" => "2026-11-26T12:16:25.123456789Z", "s" => "out", "m" => "GET / 200 1.2ms" }

  test "keeps the contract's keys and drops the rest" do
    parsed = LiveLogs.parse(
      "action" => "logs", "secret" => "x", "container" => WEB, "backlog" => true, "dropped" => 3, "ended" => true,
      "lines" => [ LINE.merge("env" => "x") ]
    )

    assert_equal({ "container" => WEB, "backlog" => true, "dropped" => 3, "ended" => true, "lines" => [ LINE ] }, parsed)
  end

  test "an agent that has logs off, or refuses a container, says so" do
    assert_equal({ "container" => WEB, "off" => true }, LiveLogs.parse("action" => "logs", "container" => WEB, "off" => true))
    assert_equal({ "container" => WEB, "refused" => "not a Kamal container" }, LiveLogs.parse("action" => "logs", "container" => WEB, "refused" => "not a Kamal container"))
  end

  test "anything that is not about a container is nothing" do
    [ nil, "x", [], 1, {}, { "lines" => [ LINE ] }, { "container" => nil, "lines" => [ LINE ] } ].each do |data|
      assert_nil LiveLogs.parse(data), data.inspect
    end
  end

  test "container ids are lowercase hex of 12 to 64 characters" do
    [ "A" * 64, "g" * 64, "a" * 11, "a" * 65, "../#{"a" * 12}", "#{"a" * 12}\n", "" ].each do |id|
      assert_nil LiveLogs.parse(batch(id)), id.inspect
    end
    assert LiveLogs.parse(batch("a" * 12))
    assert LiveLogs.parse(batch("a" * 64))
  end

  test "a batch with nothing in it is nothing, with a drop count, an end or a notice it is something" do
    assert_nil LiveLogs.parse(batch(WEB, lines: []))
    assert_nil LiveLogs.parse(batch(WEB, lines: [], backlog: true, dropped: 0, ended: false))
    assert_nil LiveLogs.parse(batch(WEB, lines: [], off: "yes", refused: "", dropped: -1))

    assert_equal 5, LiveLogs.parse(batch(WEB, lines: [], dropped: 5))["dropped"]
    assert LiveLogs.parse(batch(WEB, lines: [], ended: true))["ended"]
  end

  test "lines that break the contract are dropped one by one" do
    lines = [
      LINE,
      LINE.merge("s" => "stdin"),
      LINE.merge("s" => nil),
      LINE.merge("m" => 42),
      LINE.merge("m" => nil),
      LINE.merge("m" => { "x" => 1 }),
      LINE.merge("t" => 1_764_159_385),
      LINE.merge("t" => "2026-11-26T12:16:25.#{"1" * 30}Z"),
      LINE.merge("m" => "x" * 8194),
      "not a line",
      nil,
      LINE.merge("m" => "x" * 8193, "t" => "2026-11-26T12:16:26Z")
    ]

    parsed = LiveLogs.parse(batch(WEB, lines: lines))

    assert_equal [ "GET / 200 1.2ms", "x" * 8193 ], parsed["lines"].map { it["m"] }
  end

  test "keeps at most a thousand lines" do
    lines = Array.new(1500) { |i| LINE.merge("m" => "line #{i}") }

    parsed = LiveLogs.parse(batch(WEB, lines: lines))

    assert_equal 1000, parsed["lines"].size
    assert_equal "line 999", parsed["lines"].last["m"]
  end

  test "lines that are not a list are nothing" do
    assert_nil LiveLogs.parse(batch(WEB, lines: "GET / 200"))
    assert_nil LiveLogs.parse(batch(WEB, lines: { "t" => LINE["t"], "s" => "out", "m" => "x" }))
  end

  test "flags are true or nothing, counts are positive integers, reasons are short strings" do
    parsed = LiveLogs.parse(batch(WEB, lines: [ LINE ], backlog: "true", ended: 1, off: "yes", dropped: "9", refused: "x" * 81))
    assert_equal({ "container" => WEB, "lines" => [ LINE ] }, parsed)

    assert_nil LiveLogs.parse(batch(WEB, lines: [], dropped: 1.5))
    assert_equal "x" * 80, LiveLogs.parse(batch(WEB, lines: [], refused: "x" * 80))["refused"]
  end

  test "a new reader's tail request always goes out, with its backlog" do
    placement = place(server_named("web-1.example.com"), WEB)

    2.times do
      assert_broadcast_on AgentChannel.broadcasting_for(placement.server), { type: "tail", container: WEB, seconds: 30, backlog: 200 } do
        LiveLogs.tail(placement, backlog: 200)
      end
    end
  end

  test "renewals go out at most once per few seconds per container, however many people read" do
    web_1 = server_named("web-1.example.com")
    placement, other = place(web_1, WEB), place(web_1, WORKER, name: "web-worker")
    stream = AgentChannel.broadcasting_for(web_1)

    assert_broadcasts stream, 2 do
      3.times { LiveLogs.tail(placement, backlog: 0) }
      3.times { LiveLogs.tail(other, backlog: 0) }
    end

    travel LiveLogs::RENEW_EVERY + 1.second
    assert_broadcast_on stream, { type: "tail", container: WEB, seconds: 30, backlog: 0 } do
      LiveLogs.tail(placement, backlog: 0)
    end
  end

  test "a reader who just asked for a backlog doesn't need a renewal right behind it" do
    placement = place(server_named("web-1.example.com"), WEB)

    assert_broadcasts AgentChannel.broadcasting_for(placement.server), 1 do
      LiveLogs.tail(placement, backlog: 200)
      LiveLogs.tail(placement, backlog: 0)
    end
  end
end
