require "test_helper"

class WorldMapTest < ActiveSupport::TestCase
  setup do
    stub_github_repo(projects(:infra))
    projects(:infra).sync
    @now = Time.current
    locate "web-1.example.com", 1.35, 103.82
    locate "web-2.example.com", 1.36, 103.83
    locate "api-1.example.com", 50.11, 8.68
    locate "jobs-1.example.com", 40.71, -74.01
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

  test "only servers in one metro area share a place" do
    Server.find_by!(name: "api-1.example.com").update!(latitude: 52.37, longitude: 4.90) # Amsterdam
    Server.find_by!(name: "jobs-1.example.com").update!(latitude: 50.85, longitude: 4.35) # Brussels, 173 km away
    Server.find_by!(name: "web-2.example.com").update!(latitude: 1.30, longitude: 103.85) # 6 km from web-1

    places = WorldMap.new.sites.map { it.servers.map(&:name).sort }
    assert_includes places, [ "api-1.example.com" ]
    assert_includes places, [ "jobs-1.example.com" ]
    assert_includes places, %w[ web-1.example.com web-2.example.com ]
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
    boxes = map.labels(map.named_keys + map.sites.map(&:key)).values.map(&:box)
    dots = map.sites.map { [ it.x - map.radius(it), it.y - map.radius(it), it.x + map.radius(it), it.y + map.radius(it) ] }

    assert_equal map.sites.size + 1, boxes.size, "every place, plus Meridian itself"
    boxes.combination(2).each { |a, b| assert_not overlap?(a, b), "#{a} overlaps #{b}" }
    boxes.product(dots).each { |box, dot| assert_not overlap?(box, dot), "#{box} covers a dot" }
  end

  test "only places that need attention are named; the rest wait for a hover" do
    Server.find_by!(name: "jobs-1.example.com").update!(last_seen_at: 2.hours.ago)
    Server.create!(name: "spare-1.example.com", hostname: "spare-1.example.com", latitude: 35.68, longitude: 139.69, last_seen_at: @now)
    map = WorldMap.new
    new_york, singapore, frankfurt, tokyo = %w[ jobs-1 web-1 api-1 spare-1 ].map { |name| site(map, "#{name}.example.com") }

    assert_equal [ "stale", "missing", "missing", "in_sync" ], [ new_york, singapore, frankfurt, tokyo ].map(&:state)
    keys = map.named_keys
    assert_includes keys, new_york.key, "a quiet place is always named"
    assert_includes keys, singapore.key, "a place missing an app is named"
    assert_includes keys, frankfurt.key
    assert_not_includes keys, tokyo.key, "a place that matches Git waits for a hover"
    assert_equal keys.size, map.labels(keys).size
  end

  test "places list those that need attention first, worst first, then by name" do
    Server.find_by!(name: "jobs-1.example.com").update!(last_seen_at: 2.hours.ago)
    Server.create!(name: "spare-1.example.com", hostname: "spare-1.example.com", latitude: 35.68, longitude: 139.69, last_seen_at: @now)

    assert_equal %w[ api-1 web-2 jobs-1 spare-1 ], WorldMap.new.places.map(&:name)
  end

  test "a place being deployed to comes before others in the same state" do
    projects(:infra).apps.find_by!(service: "blog").deploys.create!(version: "b2", commit_sha: "f" * 40)

    assert_equal %w[ web-2 api-1 jobs-1 ], WorldMap.new.places.map(&:name), "blog runs in Singapore only"
  end

  test "problems are the places that need attention, by state, worst first" do
    Server.find_by!(name: "jobs-1.example.com").update!(last_seen_at: 2.hours.ago)
    problems = WorldMap.new.problems

    assert_equal %w[ missing stale ], problems.keys
    assert_equal [ %w[ api-1 web-2 ], %w[ jobs-1 ] ], problems.values.map { it.map(&:name).sort }
  end

  private
    def overlap?(a, b) = a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]

    def site(map, server_name) = map.sites.find { it.servers.map(&:name).include?(server_name) }

    def locate(name, lat, lng)
      Server.find_by!(name: name).update!(latitude: lat, longitude: lng, last_seen_at: @now)
    end
end
