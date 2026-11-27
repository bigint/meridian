require "test_helper"
require "turbo/broadcastable/test_helper"

class BoardTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper, MemoryCacheHelper

  setup do
    @server = Server.create!(name: "web-1.example.com", hostname: "web-1.example.com", labels: { "region" => "sgp" }, last_seen_at: Time.current)
  end

  test "configs that only run accessories stay off the board" do
    project = projects(:infra)
    project.apps.create!(service: "edge", kind: App::ACCESSORIES, config_path: "deploy/edge.yml")
    project.apps.create!(service: "shop", config_path: "deploy/shop.yml")

    services = Board.new.apps.values.map(&:service)
    assert_includes services, "shop"
    assert_not_includes services, "edge"
  end

  test "refreshes are throttled to one per group per second, and the last change still goes out" do
    assert_turbo_stream_broadcasts([ :board, "sgp" ], count: 1) do
      Board.refresh_later(@server)
      perform_enqueued_jobs
    end

    assert_enqueued_with(job: BoardRefreshJob, args: [ "sgp" ]) do
      3.times { Board.refresh_later(@server) }
    end
    assert_enqueued_jobs 1, only: BoardRefreshJob
    assert_turbo_stream_broadcasts([ :board, "sgp" ], count: 1) { perform_enqueued_jobs }

    assert_enqueued_jobs 1, only: BoardRefreshJob do
      Board.refresh_later(@server)
    end
  end

  test "a server that moves region is refreshed in the region it left too" do
    @server.update!(labels: { "region" => "fra" })

    Board.refresh_later(@server)
    perform_enqueued_jobs
    assert_turbo_stream_broadcasts [ :board, "fra" ], count: 1
    assert_turbo_stream_broadcasts [ :board, "sgp" ], count: 1
  end

  test "groups large fleets by region automatically and paginates" do
    build_fleet(servers: 40, apps: 30)
    board = Board.new

    assert_equal "region", board.group_by
    assert_equal 2, board.pages
    assert_equal Board::PER_PAGE, board.page_rows.size
    assert board.groups.all? { |group| group.rows.all? { it.is_a?(App) } }
  end

  test "a page past the last shows the last" do
    versioned_app("shop")
    assert_equal 1, Board.new(page: "1#{"0" * 30}").page
    assert_equal [ "shop" ], Board.new(page: "1#{"0" * 30}").page_rows.map(&:service)
    assert_equal 1, Board.new(page: "-3").page
  end

  test "filters by label and state" do
    build_fleet(servers: 40, apps: 30)

    assert Board.new(region: "ams").cells.all? { it.server.label("region") == "ams" }
    missing = Board.new(state: "missing")
    assert missing.cells.all? { it.state == "missing" }
    assert_equal Board.new.summary, missing.summary, "summary ignores the state filter"
  end

  test "each role Git assigns to a server has a state, and the worst one is the cell's" do
    app = versioned_app("shop", roles: %w[ web job ])
    start app, role: "web", version: "v2"

    cell = Board.new.cells.sole
    assert_equal "missing", cell.state, "the job role isn't running"
    assert_equal({ "web" => "in_sync", "job" => "missing" }, cell.role_states)
    assert_equal [ "missing" ], Board.new.attention.map(&:state)

    start app, role: "job", version: "v2"
    start app, role: "cron", version: "v2"
    cell = Board.new.cells.sole
    assert_equal "stray", cell.state, "Git doesn't put the cron role here"
    assert_equal [ "cron" ], cell.roles_in("stray")
  end

  test "a quiet server's cell never shows Git's version as if it ran there" do
    @server.update!(last_seen_at: 10.minutes.ago)
    versioned_app("shop", version: "v42")

    cell = Board.new.cells.sole
    assert_equal "stale", cell.state
    assert_nil cell.version, "the agent reported nothing running"
  end

  private
    def versioned_app(service, version: "v2", roles: %w[ web ], server: @server)
      app = projects(:infra).apps.create!(service: service, config_path: "deploy/#{service}.yml", version_path: "deploy/#{service}.version")
      app.releases.create!(version: version, commit_sha: SecureRandom.hex(20), committed_at: 1.hour.ago)
      roles.each { app.assignments.create!(server: server, role: it) }
      app
    end

    def start(app, role:, version:, server: @server)
      Placement.create!(server: server, app: app, container_id: SecureRandom.hex(6), name: "#{app.service}-#{role}-#{version}",
        service: app.service, role: role, version: version, state: "running", observed_at: Time.current)
    end
end
