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

  # What it takes to put one app behind a tunnel, in that app's own names,
  # and which of those steps Meridian can see are done: the token set from
  # its Secrets page, the connector in the config, the connector running.
  # The steps in Cloudflare and in .kamal/secrets it can't see.
  class Setup
    attr_reader :app, :tunnel, :secret

    def self.for(app, tunnels: Tunnel.all)
      tunnel = tunnels.find { it.app == app }
      new(app, tunnel: tunnel, secret: app.project.secret_names.find_by(name: tunnel&.secret_name || Tunnel.secret_name(app.service)))
    end

    def initialize(app, tunnel: nil, secret: nil)
      @app, @tunnel, @secret = app, tunnel, secret
    end

    def secret_name = tunnel&.secret_name || Tunnel.secret_name(app.service)
    def secrets_line = "#{secret_name}=$#{secret_name}"
    def snippet = Tunnel.snippet(secret_name)
    def boot_command = Tunnel.boot_command(app, tunnel&.name || LEGACY_NAME)
    def hostname = app.hostnames.first

    def token_saved? = secret&.last_set_at.present?
    def in_config? = tunnel.present?
    def running? = tunnel&.state == :running
  end

  attr_reader :app, :accessory, :connectors, :secret

  # secret is the SecretName row for the token, if Meridian knows the name.
  def initialize(app, accessory, connectors, secret = nil)
    @app, @accessory, @connectors, @secret = app, accessory, connectors, secret
  end

  # One tunnel and one token per app: Cloudflare spreads a tunnel's requests
  # over all its connectors, so a tunnel shared by apps on different servers
  # would send requests to servers that don't run the app.
  def self.secret_name(service) = "#{service.to_s.upcase.gsub(/[^A-Z0-9]+/, "_")}_TUNNEL_TOKEN"

  def self.snippet(secret_name) = Templates.render("kamal/cloudflared.yml", secret: secret_name)

  def self.boot_command(app, accessory_name)
    "kamal accessory boot #{accessory_name} -c #{app.config_path}#{" -d #{app.destination}" if app.destination.present?}"
  end

  def name = accessory["name"]

  def secret_name = Tunnel.token_secret(app, accessory)

  def token_set? = secret&.last_set_at.present?

  def state = connectors.map(&:state).max_by { STATES.index(it) } || :unknown

  def missing? = connectors.any? { it.state == :missing }

  def boot_command = Tunnel.boot_command(app, name)

  # Problems first, then by app. Five queries however many tunnels there are.
  def self.all
    pairs = App.ordered.flat_map { |app| app.accessories.select { cloudflared?(it) }.map { |accessory| [ app, accessory ] } }
    servers = servers_by_host(pairs.flat_map { |_, accessory| accessory["hosts"] }.uniq)
    placements = Placement.where(kind: "accessory", service: pairs.map { |_, accessory| accessory["service"] }.uniq)
      .running_first.group_by { [ it.server_id, it.service ] }
    secrets = SecretName.where(name: pairs.filter_map { token_secret(*it) }.uniq).index_by { [ it.project_id, it.name ] }

    tunnels = pairs.map do |app, accessory|
      connectors = accessory["hosts"].map do |host|
        server = servers[host]
        Connector.new(host, server, server && placements[[ server.id, accessory["service"] ]]&.first)
      end
      new(app, accessory, connectors, secrets[[ app.project_id, token_secret(app, accessory) ]])
    end

    tunnels.sort_by.with_index { |tunnel, index| [ -STATES.index(tunnel.state), index ] }
  end

  # The repository secret a connector reads its token from. Configs synced
  # before the parser reported accessory secrets fall back to the app's.
  def self.token_secret(app, accessory)
    (accessory["secrets"] || app.secret_names).find { it.end_with?("TUNNEL_TOKEN") }
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
