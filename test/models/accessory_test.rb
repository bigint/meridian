require "test_helper"

class AccessoryTest < ActiveSupport::TestCase
  setup do
    @project = projects(:infra)
  end

  test "each accessory runs, stopped, missing or unknown on each host Git names" do
    primary, replica = %w[ a b ].map { Server.create!(name: "#{it}.example.com", hostname: "#{it}.example.com", last_seen_at: 1.second.ago) }
    Server.create!(name: "c.example.com", hostname: "c.example.com", last_seen_at: 1.second.ago)
    app = @project.apps.create!(service: "umami", config_path: "deploy/umami.yml", accessories: [
      { "name" => "db", "service" => "umami-db", "image" => "postgres:17-alpine", "hosts" => [ "a.example.com" ] },
      { "name" => "db-replica", "service" => "umami-db-replica", "image" => "postgres:17-alpine", "hosts" => [ "b.example.com", "c.example.com", "gone.example.com" ] }
    ])
    primary.placements.create!(container_id: "c1", name: "umami-db", kind: "accessory", service: "umami-db", state: "running", observed_at: Time.current)
    replica.placements.create!(container_id: "c2", name: "umami-db-replica", kind: "accessory", service: "umami-db-replica", state: "exited", observed_at: Time.current)

    accessories = Accessory.for(app).index_by(&:name)

    assert_equal "postgres:17-alpine", accessories["db"].image
    assert_equal [ :running ], accessories["db"].instances.map(&:state)
    assert_equal({ "b.example.com" => :stopped, "c.example.com" => :missing, "gone.example.com" => :unknown }, accessories["db-replica"].instances.to_h { [ it.host, it.state ] })
    assert_equal "kamal accessory boot db-replica -c deploy/umami.yml", accessories["db-replica"].boot_command
  end
end
