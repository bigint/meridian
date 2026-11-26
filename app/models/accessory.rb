# One of an app's Kamal accessories (a database, a cache, a tunnel connector):
# where Git says it runs, and what the agents report there. Kamal names an
# accessory's containers <service>-<name> and labels them with that service,
# so the agents' placements find it on each host.
class Accessory
  # Least to most worrying.
  STATES = %i[ running unknown stopped missing ].freeze

  # Running, stopped, missing (the server reports, without it) or unknown (no
  # recent report to go by: a silent agent's last placements may be long
  # gone). Needs server and placement.
  module State
    def state
      if !server&.reporting? || server.stale? then :unknown
      elsif placement then placement.running? ? :running : :stopped
      else :missing
      end
    end
  end

  Instance = Data.define(:host, :server, :placement) { include State }

  attr_reader :app, :name, :service, :image, :instances

  def initialize(app, entry, instances)
    @app, @name, @service, @image, @instances = app, entry["name"], entry["service"], entry["image"], instances
  end

  def missing = instances.select { it.state == :missing }

  def boot_command = Accessory.boot_command(app, name)

  def self.boot_command(app, name)
    "kamal accessory boot #{name} -c #{app.config_path}#{" -d #{app.destination}" if app.destination.present?}"
  end

  # An app's accessories, each with an instance per host. Two queries.
  def self.for(app)
    entries = app.accessories
    servers = servers_by_host(entries.flat_map { it["hosts"] }.uniq)
    placements = Placement.where(kind: "accessory", service: entries.map { it["service"] }).running_first.group_by { [ it.server_id, it.service ] }

    entries.map do |entry|
      new(app, entry, entry["hosts"].map { |host|
        server = servers[host]
        Instance.new(host, server, server && placements[[ server.id, entry["service"] ]]&.first)
      })
    end
  end

  # Found the way Server.for_host finds them, without creating any.
  def self.servers_by_host(hosts)
    found = Server.where(hostname: hosts).or(Server.where(name: hosts)).to_a
    hosts.index_with { |host| found.find { it.hostname == host } || found.find { it.name == host } }.compact
  end
end
