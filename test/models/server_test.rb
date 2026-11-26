require "test_helper"

class ServerTest < ActiveSupport::TestCase
  test "stale after three of the agent's intervals, never under 45 seconds" do
    default = Server.create!(name: "a", hostname: "a", last_seen_at: 50.seconds.ago)
    slow = Server.create!(name: "b", hostname: "b", last_seen_at: 150.seconds.ago, interval_seconds: 60)
    quick = Server.create!(name: "c", hostname: "c", last_seen_at: 30.seconds.ago, interval_seconds: 5)
    slow_and_gone = Server.create!(name: "d", hostname: "d", last_seen_at: 200.seconds.ago, interval_seconds: 60)

    assert default.stale?
    assert_not slow.stale?
    assert_not quick.stale?
    assert slow_and_gone.stale?
    assert_equal [ default, slow_and_gone ], Server.silent.order(:id).to_a
  end

  test "Git's host takes over the server its agent made before Git listed it" do
    agent = Server.create!(name: "web-1", hostname: "web-1", machine_id: "m-1", last_seen_at: Time.current)

    assert_equal agent, Server.for_host("web-1.example.com")
    assert_equal [ "web-1.example.com", "web-1.example.com" ], [ agent.reload.name, agent.hostname ]
    assert_equal agent, Server.for_host("web-1.example.com")
  end

  test "an agent's server that Git already places, or an IP, is never taken over" do
    placed = Server.create!(name: "web-1", hostname: "web-1", machine_id: "m-1")
    App.new(project: projects(:infra), service: "x", config_path: "config/x.yml").save!(validate: false)
    Assignment.create!(app: App.last, server: placed, role: "web")
    Server.create!(name: "10.0.0.5", hostname: "10.0.0.5", machine_id: "m-2")

    assert_not_equal placed, Server.for_host("web-1.example.com")
    assert_equal "10.0.0.9", Server.for_host("10.0.0.9").name
  end
end
