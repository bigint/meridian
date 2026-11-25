require "test_helper"

# Target from the spec: the board's first page renders in under 200 ms with
# 500 servers and 200 apps. Best of three warm requests, to keep noise out.
class BoardPerformanceTest < ActionDispatch::IntegrationTest
  TARGET = ENV.fetch("BOARD_TARGET_MS", 200).to_f

  setup do
    Meridian::Demo.new(servers: 500, apps: 200).call
    sign_in_as users(:viewer)
  end

  test "first page of a 500-server board renders under the target" do
    get root_path
    assert_response :success
    assert_select "table.grid"

    best = 3.times.map { elapsed_ms { get root_path } }.min
    assert_operator best, :<, TARGET, "Board took #{best.round} ms"
  end

  private
    def elapsed_ms
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    end
end
