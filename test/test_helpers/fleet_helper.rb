# Builds a large fleet with believable drift in a few inserts, for the tests
# that need scale: grouping, paging and keeping the board's queries flat.
# Uses example.com names only, and the same fleet for the same seed.
module FleetHelper
  REGIONS = %w[ ams fra lon nyc sfo sgp syd tor ].freeze
  CITIES = { "ams" => [ 52.37, 4.90 ], "fra" => [ 50.11, 8.68 ], "lon" => [ 51.51, -0.13 ], "nyc" => [ 40.71, -74.01 ],
             "sfo" => [ 37.77, -122.42 ], "sgp" => [ 1.35, 103.82 ], "syd" => [ -33.87, 151.21 ], "tor" => [ 43.65, -79.38 ] }.freeze
  PROVIDERS = %w[ hetzner ovh equinix homelab ].freeze
  WORDS = %w[ atlas beacon cedar delta ember fjord grove harbor iris juniper kestrel lumen meadow nova orbit pine quartz raven sierra tundra umber vale willow yarrow zephyr ].freeze

  def build_fleet(servers:, apps:, seed: 42)
    random = Random.new(seed)
    now = Time.current
    project = Project.create!(name: "Fleet", repo_full_name: "example/fleet", installation_id: 1, config_globs: [ "apps/*.yml" ], last_synced_sha: "f" * 40, synced_at: now)

    fleet_servers = fleet_servers(servers, random, now)
    fleet_apps = fleet_apps(project, apps, now)
    place_fleet(fleet_apps, fleet_servers, random, now)
    project
  end

  private
    def fleet_servers(count, random, now)
      rows = count.times.map do |index|
        region = REGIONS[index % REGIONS.size]
        seen = case random.rand(100)
        when 0..1 then nil
        when 2..4 then now - random.rand(120..3600)
        else now - random.rand(0..20)
        end
        name = format("fleet-%s-%03d.example.com", region, index)
        lat, lng = CITIES.fetch(region)
        { name: name, hostname: name, machine_id: (Digest::MD5.hexdigest(name) if seen),
          latitude: (lat + random.rand(-0.05..0.05)).round(4), longitude: (lng + random.rand(-0.05..0.05)).round(4),
          labels: { region: region, provider: PROVIDERS[random.rand(PROVIDERS.size)], role: %w[ web web web worker db ][random.rand(5)] },
          agent_version: ("0.1.0" if seen), last_seen_at: seen, created_at: now, updated_at: now }
      end
      Server.insert_all!(rows)
      Server.where("name LIKE ?", "fleet-%").order(:id).to_a
    end

    def fleet_apps(project, count, now)
      rows = count.times.map do |index|
        service = "#{WORDS[index % WORDS.size]}-#{index / WORDS.size}"
        { project_id: project.id, service: service, config_path: "apps/#{service}.yml", destination: "", kind: App::KINDS[index % 4],
          image: "example/#{service}", hostnames: [ "#{service}.example.com" ], roles: [], version_path: "apps/#{service}.version",
          created_at: now, updated_at: now }
      end
      App.insert_all!(rows)
      apps = project.apps.order(:id).to_a

      Release.insert_all!(apps.flat_map do |app|
        3.times.map { |n| { app_id: app.id, version: "v#{10 + n}", commit_sha: Digest::SHA1.hexdigest("#{app.id}-#{n}"), author: "Ada", committed_at: now - (3 - n).days, message: "deploy(#{app.service}): v#{10 + n}", created_at: now, updated_at: now } }
      end)
      apps
    end

    # Mostly in sync: about 3% missing, 6% a release behind, 3% of apps on a
    # server Git doesn't name, and a quarter of apps in a second region.
    def place_fleet(apps, servers, random, now)
      by_region = servers.group_by { it.labels["region"] }
      assignments, placements = [], []

      apps.each_with_index do |app, index|
        pool = by_region[REGIONS[index % REGIONS.size]]
        pool += by_region[REGIONS[(index + 1 + index % 3) % REGIONS.size]].first(2) if (index % 4).zero?
        pool.sample(random.rand(2..6), random: random).each do |server|
          assignments << { app_id: app.id, server_id: server.id, role: "web", created_at: now, updated_at: now }
          version = case random.rand(100)
          when 0..2 then nil
          when 3..8 then "v11"
          else "v12"
          end
          placements << fleet_placement(app, server, version, random, now) if version
        end

        if random.rand(100) < 3
          stray = servers.sample(random: random)
          placements << fleet_placement(app, stray, "v12", random, now) unless assignments.any? { it[:app_id] == app.id && it[:server_id] == stray.id }
        end
      end

      Assignment.insert_all!(assignments)
      hosts = assignments.group_by { it[:app_id] }.transform_values { |rows| rows.map { |row| servers.find { it.id == row[:server_id] }.hostname } }
      apps.each { |app| app.update_columns(roles: [ { "name" => "web", "hosts" => hosts.fetch(app.id, []), "proxy" => true } ]) }
      Placement.insert_all!(placements.uniq { [ it[:server_id], it[:container_id] ] }) if placements.any?
    end

    def fleet_placement(app, server, version, random, now)
      { server_id: server.id, app_id: app.id, container_id: Digest::SHA1.hexdigest("#{app.id}-#{server.id}").first(12), name: "#{app.service}-web-#{version}",
        service: app.service, role: "web", destination: "", kind: "app", image: "example/#{app.service}:#{version}", version: version,
        state: "running", health: (random.rand(50).zero? ? "unhealthy" : "healthy"), started_at: now - 3600, observed_at: now }
    end
end
