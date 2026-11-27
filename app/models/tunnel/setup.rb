# What it takes to serve a project's apps through one Cloudflare Tunnel, in
# the project's own names: which servers run a connector, the edge config
# that starts them, and which apps the tunnel can serve from those servers.
# Steps Meridian can see tick themselves off (the token set from its Secrets
# page, the connectors in Git, the connectors running); the ones in
# Cloudflare and .kamal/secrets it can't see.
class Tunnel::Setup
  include Tunnel::Covering

  SERVICE = "edge"

  attr_reader :project, :tunnel

  def self.for(project, hosts: nil)
    tunnel = Tunnel.for(project)
    new(project, tunnel: tunnel, hosts: hosts.presence || tunnel&.connector_hosts)
  end

  def initialize(project, tunnel:, hosts:)
    @project, @tunnel, @requested_hosts = project, tunnel, hosts
  end

  def name = tunnel&.name || project.name.parameterize
  def secret_name = tunnel&.secret_name || Tunnel::SECRET
  def secrets_line = "#{secret_name}=$#{secret_name}"
  def config_path = tunnel&.configs&.first&.config_path || project.config_path_for(SERVICE)
  def boot_command = "kamal accessory boot all -c #{config_path}"

  # Every server that runs one of the project's apps, and the ones picked
  # for connectors: by default the tunnel's, or every candidate. Picks come
  # from the URL and go into a config to commit, so only host names count.
  def candidates = apps.flat_map(&:servers).uniq.sort_by(&:name)
  def hosts = @hosts ||= (@requested_hosts.presence || candidates.map(&:hostname)).grep(Server::HOST_FORMAT)

  def apps = @apps ||= project.apps.deployable.includes(:servers).ordered.to_a
  def coverage = @coverage ||= Tunnel.coverage(apps, hosts)

  def edge_config
    Templates.render("kamal/edge.yml", tunnel: name, secret: secret_name, config_path: config_path, service: SERVICE,
      hosts: hosts.map { "      - #{it}\n" }.join,
      accessories: hosts.map { connector_yaml(it) }.join("\n"))
  end

  def secret = @secret ||= project.secret_names.find_by(name: secret_name)
  def token_saved? = secret&.last_set_at.present?
  def in_config? = tunnel.present?
  def running? = tunnel&.state == :running

  private
    # One accessory per server, named after it, so Cloudflare lists each
    # replica under the server's name. Servers whose short names clash
    # (web.sgp.example.com and web.fra.example.com) go by their whole name.
    def connector_yaml(host)
      label = labels.fetch(host)
      "  cloudflared-#{label}:\n    <<: *cloudflared\n    host: #{host}\n    options:\n      hostname: #{label}\n"
    end

    def labels
      @labels ||= hosts.index_with { Tunnel.label_for(it) }.then do |short|
        short.to_h { |host, label| [ host, short.values.count(label) > 1 ? host.tr(".:", "-") : label ] }
      end
    end
end
