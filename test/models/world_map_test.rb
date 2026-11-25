require "test_helper"

class WorldMapTest < ActiveSupport::TestCase
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
    @now = Time.current
    place "web-1.example.com", 1.35, 103.82
    place "web-2.example.com", 1.36, 103.83
    place "api-1.example.com", 50.11, 8.68
    place "jobs-1.example.com", 40.71, -74.01
  end

  test "projects latitude and longitude onto the map" do
    assert_equal [ 0.0, 0.0 ], WorldMap.project(84, -180)
    assert_equal [ 500.0, (84 / 142.0 * WorldMap::HEIGHT).round(1) ], WorldMap.project(0, 0)
    assert_equal WorldMap::HEIGHT, WorldMap.project(-80, 0).last, "clamped to the map's southern edge"
  end

  test "nearby servers become one place, and places sharing an app are linked" do
    map = WorldMap.new
    singapore = map.sites.find { it.servers.map(&:name).include?("web-1.example.com") }

    assert_equal %w[ web-1.example.com web-2.example.com ], singapore.servers.map(&:name).sort
    assert map.links.any? { |link| [ link.from, link.to ].include?(singapore) && link.apps.map(&:service).include?("api") },
      "api runs on web-2 (Singapore) and api-1 (Frankfurt)"
    assert_includes map.unlocated.map(&:name), "staging-1.example.com"
  end

  test "flows need Meridian's own location: agent reports in, deploys out" do
    assert_empty WorldMap.new.flows

    Account.current.update!(latitude: 51.5, longitude: -0.1)
    projects(:infra).apps.find_by!(service: "api").deploys.create!(version: "v2", commit_sha: "f" * 40)
    flows = WorldMap.new.flows

    assert_equal 3, flows.count { it.kind == "report" }
    assert flows.select { it.kind == "report" }.all?(&:live)
    assert_equal 2, flows.count { it.kind == "deploy" }, "api is on Singapore and Frankfurt"
  end

  test "agents can report their location as labels" do
    token = AgentToken.create!(label: "x")
    payload = { "machine_id" => "m1", "hostname" => "staging-1", "labels" => { "lat" => "48.85", "lng" => "2.35" }, "containers" => [] }
    Snapshot.new(payload, token: token).ingest

    server = Server.find_by!(name: "staging-1.example.com")
    assert_equal [ 48.85, 2.35 ], [ server.latitude, server.longitude ]
  end

  test "places are named by city, then region" do
    Server.find_by!(name: "web-1.example.com").update!(labels: { "region" => "ap-southeast-1", "city" => "Singapore" })
    Server.find_by!(name: "api-1.example.com").update!(labels: { "region" => "eu-central-1" })
    names = WorldMap.new.sites.map(&:name)

    assert_includes names, "Singapore"
    assert_includes names, "eu-central-1"
  end

  test "names in a crowded region never overlap each other or a dot" do
    Account.current.update!(location_name: "Meridian (dev)", latitude: 51.5, longitude: -0.1)
    { "web-1" => [ 51.51, -0.13, "London" ], "web-2" => [ 48.86, 2.35, "Paris" ], "api-1" => [ 52.37, 4.90, "Amsterdam" ],
      "jobs-1" => [ 50.11, 8.68, "Frankfurt" ], "staging-1" => [ 50.85, 4.35, "Brussels" ] }.each do |host, (lat, lng, city)|
      Server.find_by!(name: "#{host}.example.com").update!(latitude: lat, longitude: lng, labels: { "city" => city }, last_seen_at: @now)
    end
    map = WorldMap.new
    boxes = map.labels.values.map(&:box)
    dots = map.sites.map { [ it.x - map.radius(it), it.y - map.radius(it), it.x + map.radius(it), it.y + map.radius(it) ] }

    assert_equal map.sites.size + 1, boxes.size, "every place, plus Meridian itself"
    boxes.combination(2).each { |a, b| assert_not overlap?(a, b), "#{a} overlaps #{b}" }
    boxes.product(dots).each { |box, dot| assert_not overlap?(box, dot), "#{box} covers a dot" }
  end

  private
    def overlap?(a, b) = a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]

    def place(name, lat, lng)
      Server.find_by!(name: name).update!(latitude: lat, longitude: lng, last_seen_at: @now)
    end
end
