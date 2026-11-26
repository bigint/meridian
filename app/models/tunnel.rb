# An app that reaches the internet through Cloudflare Tunnel: one app with a
# cloudflared accessory. Git says which servers should run the connector, the
# agents say whether they do. Meridian never asks Cloudflare.
class Tunnel
  IMAGE = "cloudflare/cloudflared"
  LEGACY_NAME = "cloudflared"

  # Least to most worrying. A tunnel is as healthy as its worst connector.
  STATES = %i[ running unknown stopped missing ].freeze

  Connector = Data.define(:host, :server, :placement) do
    def state
      if placement then placement.running? ? :running : :stopped
      elsif server&.reporting? && !server.stale? then :missing
      else :unknown
      end
    end
  end

  attr_reader :app, :accessory, :connectors

  def initialize(app, accessory, connectors)
    @app, @accessory, @connectors = app, accessory, connectors
  end

  def name = accessory["name"]

  def state = connectors.map(&:state).max_by { STATES.index(it) } || :unknown

  def missing? = connectors.any? { it.state == :missing }

  def boot_command
    "kamal accessory boot #{name} -c #{app.config_path}#{" -d #{app.destination}" if app.destination.present?}"
  end

  # Problems first, then by app. Four queries however many tunnels there are.
  def self.all
    pairs = App.ordered.flat_map { |app| app.accessories.select { cloudflared?(it) }.map { |accessory| [ app, accessory ] } }
    servers = servers_by_host(pairs.flat_map { |_, accessory| accessory["hosts"] }.uniq)
    placements = Placement.where(kind: "accessory", service: pairs.map { |_, accessory| accessory["service"] }.uniq)
      .running_first.group_by { [ it.server_id, it.service ] }

    tunnels = pairs.map do |app, accessory|
      connectors = accessory["hosts"].map do |host|
        server = servers[host]
        Connector.new(host, server, server && placements[[ server.id, accessory["service"] ]]&.first)
      end
      new(app, accessory, connectors)
    end

    tunnels.sort_by.with_index { |tunnel, index| [ -STATES.index(tunnel.state), index ] }
  end

  # Configs synced before the parser reported images are found by name.
  def self.cloudflared?(accessory)
    accessory["image"] ? accessory["image"].start_with?(IMAGE) : accessory["name"] == LEGACY_NAME
  end

  # Found the way Server.for_host finds them, without creating any.
  def self.servers_by_host(hosts)
    found = Server.where(hostname: hosts).or(Server.where(name: hosts)).to_a
    hosts.index_with { |host| found.find { it.hostname == host } || found.find { it.name == host } }.compact
  end
  private_class_method :servers_by_host
end
