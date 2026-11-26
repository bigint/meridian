require "application_system_test_case"

# The server page draws what ServerStatsChannel relays: host tiles with
# sparklines, and CPU, memory and network cells on each running container.
class LiveStatsTest < ApplicationSystemTestCase
  WEB = "aaa111".ljust(64, "0")
  BLOG = "bbb222".ljust(64, "0")

  setup do
    @project = projects(:infra)
    stub_github_repo(@project, history: { "deploy/web.production.version" => [ [ "c" * 40, "v42\n" ] ] })
    @project.sync
    @payload = JSON.parse(file_fixture("snapshots/web-1.json").read)
    @payload["containers"].each { it["id"] = it["id"].ljust(64, "0") }
    ingest
    @server = Server.find_by!(name: "web-1.example.com")

    use_async_cable
  end

  teardown do
    restore_cable
    set_color_scheme "light"
  end

  test "frames fill the host tiles and the running containers' cells" do
    open_page
    assert_selector ".live__status", text: "Connecting…"

    broadcast frame
    assert_selector ".live__status", text: "Live"
    within("[data-metric=cpu]") { assert_text "10.5%" }
    within("[data-metric=memory]") { assert_text "68.0 MB"; assert_text "3.3%"; assert_text "of 2.0 GB" }
    within("[data-metric=load]") { assert_text "0.05" }
    within("[data-metric=disk]") { assert_text "9.0 GB"; assert_text "22.5%"; assert_text "of 40.0 GB" }
    within("tr", text: "web-web-production-v42") do
      assert_text "2.0%"
      assert_text "3.4 MB"
      assert_text "14.7 B/s"
      assert_text "211.3 KB/s"
    end
    within("tr", text: "web-web-production-v41") { assert_no_text "KB/s" }
  end

  test "a board refresh does not wipe the numbers or the sparklines" do
    open_page
    3.times { broadcast frame }
    within("[data-metric=cpu]") { assert_text "10.5%" }
    assert_selector "[data-metric=cpu] [data-part=trace][d^=M]", visible: :all
    trace = find("[data-metric=cpu] [data-part=trace]", visible: :all)[:d]

    @payload["containers"].find { it["id"] == BLOG }["state"] = "exited"
    ingest
    within("tr", text: "blog-web-1a2b3c4d") { assert_text "exited", wait: 10 }

    within("tr", text: "web-web-production-v42") { assert_text "3.4 MB" }
    within("[data-metric=cpu]") { assert_text "10.5%" }
    assert_equal trace, find("[data-metric=cpu] [data-part=trace]", visible: :all)[:d]
  end

  test "a frame without host numbers says what they need" do
    open_page
    broadcast frame.except("host")

    assert_text "Host numbers need the agent's /proc mount."
    within("[data-metric=cpu]") { assert_text "—" }
    within("tr", text: "web-web-production-v42") { assert_text "3.4 MB" }
  end

  test "the page says so when the agent stops sending" do
    open_page
    broadcast frame

    assert_selector ".live__status", text: "Live"
    assert_selector ".live__status", text: "Paused, the agent stopped sending", wait: 10
  end

  test "screenshots, light and dark" do
    open_page
    40.times { |i| broadcast frame(wave: i) }
    within("[data-metric=cpu]") { assert_text "%" }

    %w[ light dark ].each do |scheme|
      set_color_scheme scheme
      page.save_screenshot(Rails.root.join("tmp/live-stats-#{scheme}.png").to_s)
    end
  end

  private
    def open_page
      sign_in users(:viewer)
      visit server_path(@server)
      assert_selector ".live[data-subscribed]"
    end

    def broadcast(frame)
      ServerStatsChannel.broadcast_to(@server, frame)
    end

    def frame(wave: 0)
      {
        "host" => { "cpu_cores" => 0.21 + 0.3 * Math.sin(wave / 4.0).abs, "cores" => 2, "memory_used" => 71_303_168 + wave * 300_000, "memory_total" => 2_147_483_648,
                    "load1" => 0.05 + wave / 100.0, "disk_used" => 9_663_676_416, "disk_total" => 42_949_672_960 },
        "containers" => [
          { "id" => WEB, "cpu_cores" => 0.04, "memory_used" => 3_596_288, "memory_limit" => 2_147_483_648, "net_rx" => 14.7, "net_tx" => 216_371.2, "disk_read" => 0, "disk_write" => 0 },
          { "id" => BLOG, "cpu_cores" => 0.002, "memory_used" => 41_943_040, "memory_limit" => 536_870_912, "net_rx" => 2_048, "net_tx" => 512, "disk_read" => 0, "disk_write" => 0 }
        ]
      }
    end

    def set_color_scheme(scheme)
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ])
    end

    def ingest
      Rails.cache.clear
      perform_enqueued_jobs { SnapshotIngestJob.perform_later(agent_tokens(:web_1), @payload) }
    end

    def use_async_cable
      @cable_config = ActionCable.server.config.cable
      ActionCable.server.config.cable = { "adapter" => "async" }
      ActionCable.server.restart
    end

    def restore_cable
      ActionCable.server.config.cable = @cable_config
      ActionCable.server.restart
    end
end
