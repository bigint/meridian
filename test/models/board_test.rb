require "test_helper"
require "turbo/broadcastable/test_helper"

class BoardTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

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

  test "refreshes are throttled to one per group per second" do
    with_cache(ActiveSupport::Cache::MemoryStore.new) do
      assert_turbo_stream_broadcasts([ :board, "sgp" ], count: 1) do
        3.times { Board.refresh_later(@server) }
        perform_enqueued_jobs
      end
    end
  end

  test "groups large fleets by region automatically and paginates" do
    Meridian::Demo.new(servers: 40, apps: 30).call
    board = Board.new

    assert_equal "region", board.group_by
    assert_equal 2, board.pages
    assert_equal Board::PER_PAGE, board.page_rows.size
    assert board.groups.all? { |group| group.rows.all? { it.is_a?(App) } }
  end

  test "filters by label and state" do
    Meridian::Demo.new(servers: 40, apps: 30).call

    assert Board.new(region: "ams").cells.all? { it.server.label("region") == "ams" }
    missing = Board.new(state: "missing")
    assert missing.cells.all? { it.state == "missing" }
    assert_equal Board.new.summary, missing.summary, "summary ignores the state filter"
  end

  private
    def with_cache(store)
      original, Rails.cache = Rails.cache, store
      yield
    ensure
      Rails.cache = original
    end
end
