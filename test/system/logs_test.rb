require "application_system_test_case"

# The log viewer draws what LogsChannel relays: every source in timestamp
# order, filtered, followed, and never more than a few thousand rows.
class LogsTest < ApplicationSystemTestCase
  setup do
    app = App.create!(project: projects(:infra), service: "web", destination: "production", config_path: "deploy/web.production.yml", kind: "rails")
    @web = place(server_named("web-1.example.com"), WEB, app: app)
    @worker = place(server_named("web-2.example.com"), WORKER, app: app, name: "web-web-production-v41")
    @app = app

    use_async_cable
  end

  teardown do
    restore_cable
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ])
  end

  test "lines from two servers arrive out of order and are kept in timestamp order" do
    open_app_logs
    send_lines @web, line("12:00:02.5", "web two"), line("12:00:04.5", "web four")
    send_lines @worker, line("12:00:01.5", "worker one"), line("12:00:03.5", "worker three")

    assert_selector ".logs__line", count: 4
    assert_equal [ "worker one", "web two", "worker three", "web four" ], messages
    assert_selector ".logs__time[title='2026-11-26T12:00:01.5Z']"
    assert_equal [ "web-2", "web-1", "web-2", "web-1" ], all(".logs__source").map(&:text)
  end

  test "a line that arrives late finds its place among the ones already there" do
    open_app_logs
    send_lines @web, line("12:00:01", "first"), line("12:00:03", "third")
    assert_selector ".logs__line", count: 2

    send_lines @worker, line("12:00:02", "second")

    assert_selector ".logs__line", count: 3
    assert_equal %w[ first second third ], messages
  end

  test "the filter hides lines that don't match and marks the ones that do" do
    open_app_logs
    send_lines @web, line("12:00:01", "GET /health 200"), line("12:00:02", "ERROR: connection refused"), line("12:00:03", "GET / 200")
    assert_selector ".logs__line", count: 3

    fill_in "Filter lines", with: "ERR"

    assert_selector ".logs__line:not([hidden])", count: 1
    assert_selector ".logs__line[hidden]", count: 2, visible: :all
    assert_selector ".logs__text mark", text: "ERR"
    assert_selector ".logs__text", text: "ERROR: connection refused"

    fill_in "Filter lines", with: "zzz"
    assert_text "No lines match."

    fill_in "Filter lines", with: ""
    assert_selector ".logs__line:not([hidden])", count: 3
    assert_no_selector "mark"
  end

  test "stdout and stderr can be told apart, and stderr carries a rule" do
    open_app_logs
    send_lines @web, line("12:00:01", "fine"), line("12:00:02", "slow query", stream: "err")
    assert_selector ".logs__line", count: 2
    assert_selector ".logs__line[data-stream=err]", text: "slow query"

    click_on "stderr"
    assert_selector ".logs__line:not([hidden])", count: 1, text: "slow query"

    click_on "stdout"
    assert_selector ".logs__line:not([hidden])", count: 1, text: "fine"

    click_on "Both"
    assert_selector ".logs__line:not([hidden])", count: 2
  end

  test "a source can be switched off from its chip" do
    open_app_logs
    send_lines @web, line("12:00:01", "from web")
    send_lines @worker, line("12:00:02", "from worker")
    assert_selector ".logs__line", count: 2

    click_on "web-2"
    assert_selector ".logs__line:not([hidden])", count: 1, text: "from web"

    click_on "web-2"
    assert_selector ".logs__line:not([hidden])", count: 2
  end

  test "a backlog fills an empty source but is ignored once it has live lines" do
    open_app_logs
    send_lines @web, line("12:00:01", "history one"), line("12:00:02", "history two"), backlog: true
    assert_selector ".logs__line", count: 2

    send_lines @web, line("12:00:05", "live one")
    assert_selector ".logs__line", count: 3

    send_lines @web, line("12:00:01", "history one"), line("12:00:02", "history two"), line("12:00:03", "history three"), backlog: true
    send_lines @worker, line("12:00:04", "other source")
    assert_selector ".logs__line", count: 4

    assert_equal [ "history one", "history two", "other source", "live one" ], messages
  end

  test "a second reader's copy of the backlog is not drawn twice" do
    open_app_logs
    send_lines @web, line("12:00:01", "one"), line("12:00:02", "two"), backlog: true
    send_lines @web, line("12:00:01", "one"), line("12:00:02", "two"), backlog: true
    send_lines @worker, line("12:00:03", "marker")

    assert_selector ".logs__line", count: 3
    assert_equal %w[ one two marker ], messages
  end

  test "an agent with logs off is said so, per source" do
    open_app_logs
    broadcast @web, "off" => true
    broadcast @web, "off" => true
    send_lines @worker, line("12:00:01", "worker still talks")

    assert_selector ".logs__line--notice", count: 1
    assert_selector ".logs__line--notice", text: "Logs are off on web-1.example.com's agent. Set MERIDIAN_LOGS=1"
    assert_selector ".logs__line--notice .logs__source", text: "web-1"
    assert_selector ".logs[data-state=live]"
  end

  test "when every agent has logs off the page doesn't claim to be live" do
    sign_in users(:deployer)
    visit placement_log_path(@web)
    assert_selector ".logs[data-state=live]"

    broadcast @web, "off" => true

    assert_selector "[data-logs-target=status]", text: "Not streaming"
    assert_text "Set MERIDIAN_LOGS=1"
  end

  test "a refused container says why" do
    open_app_logs
    broadcast @worker, "refused" => "not a Kamal container"

    assert_selector ".logs__line--notice", text: "Logs refused: not a Kamal container"
  end

  test "skipped lines and a stopped container are said in the stream" do
    open_app_logs
    send_lines @web, line("12:00:01", "before")
    broadcast @web, "dropped" => 1234, "lines" => [ line("12:00:03", "after") ], "ended" => true
    broadcast @web, "ended" => true

    assert_selector ".logs__line", count: 4
    assert_equal [ "before", "1,234 lines skipped (over 512 KB/s)", "after", "Container stopped" ], messages
  end

  test "ANSI colours become styles, other escapes are cut and markup is only text" do
    open_app_logs
    send_lines @web, line("12:00:01", "\e[31mred\e[0m plain \e[1;32mbold green\e[0m \e[2J\e[?25l\e]0;title\a<img src=x onerror=alert(1)> \e[38;5;196mx\e[0m")

    assert_selector ".ansi-31", text: "red"
    assert_selector ".ansi-bold.ansi-32", text: "bold green"
    assert_no_selector ".logs__text img"
    assert_selector ".logs__text", text: "red plain bold green <img src=x onerror=alert(1)> x"
    assert_no_text "title"
  end

  test "following sticks to the end until you scroll up, then a button brings you back" do
    open_app_logs
    send_lines @web, *numbered_lines(300)
    assert_selector ".logs__line", count: 300
    assert_at_end

    page.execute_script("document.querySelector('.logs__scroller').scrollTop = 0")
    assert_selector "[data-logs-target=follow][aria-pressed=false]"

    send_lines @web, *numbered_lines(5, from: 300)
    assert_selector ".logs__jump", text: "5 new lines, jump to latest"
    assert_not at_end?

    click_on "5 new lines, jump to latest"
    assert_selector "[data-logs-target=follow][aria-pressed=true]"
    assert_no_selector ".logs__jump"
    assert_at_end
  end

  test "a flood leaves the newest five thousand rows in the page, in order and without gaps" do
    open_app_logs
    11.times { |chunk| send_lines @web, *numbered_lines(500, from: chunk * 500) }

    assert_selector ".logs__line:last-child", text: "line 5499", wait: 20
    assert_selector ".logs__line", count: 5000
    assert_equal (500..5499).map { "line #{it}" }, messages
  end

  test "clear empties the view" do
    open_app_logs
    send_lines @web, line("12:00:01", "gone soon")
    assert_selector ".logs__line", count: 1

    click_on "Clear"

    assert_no_selector ".logs__line"
    assert_text "No lines yet"
  end

  test "a quiet container reads as waiting, not as an error" do
    open_app_logs
    assert_selector ".logs[data-state=live]"
    assert_selector "[data-logs-target=status]", text: "Waiting for new lines", wait: 15
    assert_no_selector ".logs[data-state=unavailable]"
  end

  test "screenshots, light and dark" do
    open_app_logs
    realistic_logs.each { |source, *lines| send_lines source, *lines }
    assert_selector ".logs__line", count: 14
    assert_selector ".logs[data-state=live]"

    %w[ light dark ].each do |scheme|
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ])
      page.save_screenshot(Rails.root.join("tmp/logs-#{scheme}.png").to_s)
    end
  end

  private
    def open_app_logs
      sign_in users(:deployer)
      visit app_log_path(@app)
      assert_selector ".logs[data-state=live]"
    end

    # One round trip: asking the browser for thousands of rows one by one takes a minute.
    def messages
      page.evaluate_script("[...document.querySelectorAll('.logs__line:not([hidden]) .logs__text')].map(text => text.textContent)")
    end

    def line(time, message, stream: "out")
      { "t" => "2026-11-26T#{time.include?(".") ? time : "#{time}.000"}Z", "s" => stream, "m" => message }
    end

    def numbered_lines(count, from: 0)
      Array.new(count) { |i| { "t" => (Time.utc(2026, 11, 26, 12) + (from + i) / 1000.0).iso8601(3), "s" => "out", "m" => "line #{from + i}" } }
    end

    def send_lines(placement, *lines, backlog: false)
      broadcast placement, "lines" => lines, "backlog" => backlog
    end

    def broadcast(placement, extra)
      LogsChannel.broadcast_to(placement, { "container" => placement.container_id, "source" => placement.id }.merge(extra))
    end

    def at_end?
      page.evaluate_script("(() => { const s = document.querySelector('.logs__scroller'); return s.scrollHeight - s.scrollTop - s.clientHeight < 4 })()")
    end

    def assert_at_end
      assert_selector ".logs__scroller" # then poll: scrolling happens a frame after the rows
      Timeout.timeout(5) { sleep 0.05 until at_end? }
    end

    def realistic_logs
      [
        [ @web, line("12:16:20.101", "[\e[32mINFO\e[0m] Booting Puma 6.4.2"), line("12:16:20.512", "[\e[32mINFO\e[0m] Listening on http://0.0.0.0:3000"),
          line("12:16:25.123", "Started GET \"/\" for 10.0.0.4 at 2026-11-26 12:16:25 +0000"), line("12:16:25.131", "Completed 200 OK in 8ms (Views: \e[1m6.1ms\e[0m | ActiveRecord: 0.4ms)"),
          line("12:16:27.944", "\e[33mWARN\e[0m slow query: SELECT * FROM events ORDER BY created_at DESC (412ms)", stream: "err"),
          line("12:16:30.002", "Started GET \"/health\" for 10.0.0.1 at 2026-11-26 12:16:30 +0000") ],
        [ @worker, line("12:16:21.300", "\e[2mworker:\e[0m connected to queue default"), line("12:16:24.870", "ProcessEmailJob started (id=c0ffee)"),
          line("12:16:25.402", "\e[31mERROR\e[0m ProcessEmailJob failed: Net::ReadTimeout with \"smtp.example.com:587\"", stream: "err"),
          line("12:16:25.403", "  from lib/mailer.rb:42:in `deliver'", stream: "err"), line("12:16:25.404", "  from app/jobs/process_email_job.rb:9:in `perform'", stream: "err"),
          line("12:16:28.250", "ProcessEmailJob retry scheduled in 30s"), line("12:16:31.016", "\e[36mmetrics\e[0m queue=default depth=3 latency=0.4s"),
          line("12:16:32.700", "\e[1mDeploy\e[0m check: version \e[4mv42\e[0m matches") ]
      ]
    end
end
