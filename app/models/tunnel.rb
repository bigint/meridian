# A Cloudflare Tunnel: every cloudflared accessory in a project that reads
# the same token, usually one per server in an accessories-only config
# (templates/kamal/edge.yml). Git says where the connectors should run and
# which apps run beside them; the agents say whether the connectors run.
# Meridian never asks Cloudflare.
#
# The tunnel routes each app's hostname to http://kamal-proxy:80 on whichever
# connector Cloudflare picks, usually the nearest. So an app is safe to serve
# through the tunnel only if it runs on every connector's server; anywhere
# else kamal-proxy answers 404.
class Tunnel
  IMAGE = "cloudflare/cloudflared"
  SECRET = "CLOUDFLARE_TUNNEL_TOKEN"

  STATES = Accessory::STATES

  Connector = Data.define(:host, :server, :placement, :accessory, :config) do
    include Accessory::State
    def name = accessory["name"]
    def boot_command = config.accessory_command("boot", name)
  end

  # An app with a hostname and the connector hosts it doesn't run on. None
  # missing means Cloudflare can send its requests to any connector.
  Coverage = Data.define(:app, :missing, :total) do
    def full? = missing.empty?
    def none? = missing.size == total
    def partial? = !full? && !none?
  end

  # The apps in #coverage that every connector's server runs (served), that
  # only some do (gaps), and that none does (elsewhere).
  module Covering
    def served = coverage.select(&:full?)
    def gaps = coverage.select(&:partial?)
    def elsewhere = coverage.select(&:none?)
  end
  include Covering

  attr_reader :project, :secret_name, :connectors, :secret

  def initialize(project, secret_name, connectors, secret:, apps:, servers:)
    @project, @secret_name, @connectors, @secret, @apps, @servers = project, secret_name, connectors, secret, apps, servers
  end

  # One tunnel per token. Its name is the config its connectors live in.
  def name = configs.one? ? configs.first.service : secret_name
  def configs = connectors.map(&:config).uniq
  def connector_hosts = connectors.map(&:host).uniq
  def token_set? = secret&.last_set_at.present?

  def state = connectors.map(&:state).max_by { STATES.index(it) } || :unknown
  def missing = connectors.select { it.state == :missing }

  def coverage = @coverage ||= Tunnel.coverage(@apps, connector_hosts, @servers)
  # Meridian can't see Cloudflare's routes, so an app missing from a
  # connector's server is advice, not a problem: it may not be routed here.
  def problems? = state != :running

  # Problems first. A handful of queries however many tunnels there are.
  def self.all(project: nil)
    configs = project ? project.apps : App.all
    pairs = configs.ordered.includes(:project).flat_map { |app| app.accessories.select { cloudflared?(it) }.map { |accessory| [ app, accessory ] } }
    return [] if pairs.empty?

    servers = Accessory.servers_by_host(pairs.flat_map { |_, accessory| accessory["hosts"] }.uniq)
    placements = Placement.where(kind: "accessory", service: pairs.map { |_, accessory| accessory["service"] }.uniq)
      .running_first.group_by { [ it.server_id, it.service ] }
    groups = pairs.group_by { |app, accessory| [ app.project, token_secret(accessory) || "#{app.service}/#{accessory["name"]}" ] }
    secrets = SecretName.where(name: groups.keys.map(&:last)).index_by { [ it.project_id, it.name ] }
    apps = App.deployable.where(project_id: groups.keys.map(&:first)).includes(:servers).ordered.group_by(&:project_id)

    tunnels = groups.map do |(project, secret_name), members|
      connectors = members.flat_map do |config, accessory|
        accessory["hosts"].map do |host|
          server = servers[host]
          Connector.new(host, server, server && placements[[ server.id, accessory["service"] ]]&.first, accessory, config)
        end
      end
      new(project, secret_name, connectors, secret: secrets[[ project.id, secret_name ]], apps: apps.fetch(project.id, []), servers: servers)
    end

    tunnels.sort_by.with_index { |tunnel, index| [ tunnel.problems? ? 0 : 1, -STATES.index(tunnel.state), index ] }
  end

  # The project's tunnel, if it has one: Meridian sets up one per project.
  def self.for(project) = all(project: project).first

  # Every app with a hostname, and the hosts among these it doesn't run on.
  # Only roles behind kamal-proxy count: on a server that runs just the
  # app's workers, kamal-proxy has no route for it and answers 404.
  def self.coverage(apps, hosts, servers = Accessory.servers_by_host(hosts))
    wanted = hosts.to_h { [ it, servers[it]&.id ] }
    apps.select { it.hostnames.any? }.map do |app|
      on = proxied_servers(app).map(&:id)
      Coverage.new(app, wanted.reject { |_, id| id && on.include?(id) }.keys, hosts.size)
    end
  end

  def self.proxied_servers(app)
    hosts = app.roles.select { it["proxy"] }.flat_map { it["hosts"] }
    app.servers.select { hosts.include?(it.hostname) || hosts.include?(it.name) }
  end
  private_class_method :proxied_servers

  # The repository secret a connector reads its token from.
  def self.token_secret(accessory)
    accessory["secrets"].find { it.end_with?("TUNNEL_TOKEN") }
  end

  # The name a connector on this host goes by: the first DNS label, or a
  # whole IP address, whose first part is shared by its neighbours.
  def self.label_for(host)
    Server.ip?(host) ? host.tr(".:", "-") : host.split(".").first
  end

  def self.cloudflared?(accessory)
    accessory["image"].to_s.start_with?(IMAGE)
  end
end
