require "test_helper"

# Scale is a feature: the board makes the same number of queries for 500
# servers as for 40, so a bigger fleet never means an N+1 somewhere.
class BoardPerformanceTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:ada) }

  test "the board's queries don't grow with the fleet" do
    build_fleet(servers: 40, apps: 30, seed: 1)
    small = board_queries

    Project.find_by!(repo_full_name: "example/fleet").destroy!
    Server.where("name LIKE ?", "fleet-%").destroy_all
    build_fleet(servers: 500, apps: 200, seed: 1)
    large = board_queries

    assert_equal small, large, "the board ran #{large - small} more queries for a bigger fleet"
  end

  private
    def board_queries
      get root_path # warm caches, so both counts are of a steady page
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[ SCHEMA TRANSACTION ]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get root_path }
      assert_response :success
      assert_select "[data-board-grid]"
      count
    end
end
