require "test_helper"

class PlacementTest < ActiveSupport::TestCase
  setup do
    @server = server_named("web-1.example.com")
  end

  test "what runs now leaves out the stopped containers Kamal keeps for rollback" do
    live = place(@server, "a" * 64, name: "web-web-production-v42", started_at: 1.hour.ago)
    place(@server, "b" * 64, name: "web-web-production-v41", state: "exited", started_at: 1.day.ago)
    place(@server, "c" * 64, name: "web-web-production-v40_replaced_1a2b", state: "exited", started_at: 2.days.ago)

    assert_equal [ live ], @server.placements.current
  end

  test "an app that went down still shows, as its newest stopped container" do
    place(@server, "a" * 64, name: "web-web-production-v41", state: "exited", started_at: 1.day.ago)
    newest = place(@server, "b" * 64, name: "web-web-production-v42", state: "exited", started_at: 1.hour.ago)

    assert_equal [ newest ], @server.placements.current
  end

  test "each role, destination and accessory is its own current container" do
    web = place(@server, "a" * 64, role: "web", state: "exited")
    job = place(@server, "b" * 64, role: "job", state: "exited")
    staging = place(@server, "c" * 64, destination: "staging", state: "exited")
    db = place(@server, "d" * 64, name: "web-db", kind: "accessory", service: "web-db", role: nil, state: "exited")

    assert_equal [ web, job, staging, db ].sort_by(&:id), @server.placements.current.order(:id)
  end

  test "every running container counts, even two of one role mid-deploy" do
    old = place(@server, "a" * 64, name: "web-web-production-v41", started_at: 1.minute.ago)
    new = place(@server, "b" * 64, name: "web-web-production-v42", started_at: Time.current)

    assert_equal [ old, new ], @server.placements.current.order(:id)
  end
end
