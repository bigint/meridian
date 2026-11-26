# The form behind "New app". It renders a Kamal config from a template,
# checks it with Kamal itself, and proposes it to the infra repository.
class AppDraft
  include ActiveModel::Model
  include ActiveModel::Attributes

  PORTS = { "static" => 80, "node" => 3000, "rails" => 80, "other" => 3000 }.freeze
  DESCRIPTIONS = { "static" => "a static site served by nginx", "node" => "a Next.js app (standalone output)", "rails" => "a Rails app", "other" => "a container" }.freeze

  attribute :project_id, :integer
  attribute :service, :string
  attribute :source_repo, :string
  attribute :kind, :string, default: "node"
  attribute :hostname, :string
  attribute :server_ids, default: []
  attribute :label_selector, :string
  attribute :destination, :string
  attribute :app_port, :integer
  attribute :registry, :string, default: "ghcr.io"
  attribute :version, :string, default: "latest"
  attribute :tunnel, :boolean, default: false

  validates :project, :service, :source_repo, :hostname, presence: true
  validates :service, format: { with: /\A[a-z0-9][a-z0-9_-]{0,62}\z/, message: "must be lowercase letters, digits, - or _" }, allow_blank: true
  validates :source_repo, format: { with: %r{\A[\w.-]+/[\w.-]+\z}, message: "must look like owner/name" }, allow_blank: true
  validates :kind, inclusion: { in: App::KINDS }
  validates :hostname, format: { with: /\A[a-z0-9.-]+\.[a-z]{2,}\z/i, message: "must be a domain name" }, allow_blank: true
  validates :destination, format: { with: /\A[a-z0-9_-]+\z/ }, allow_blank: true
  validates :version, format: { with: /\A[\w.+:@-]{1,128}\z/ }
  validate :servers_chosen, :path_free, :kamal_accepts_it

  attr_writer :project
  def project = @project ||= Project.find_by(id: project_id)
  def port = app_port.presence || PORTS.fetch(kind, 3000)
  def image = source_repo.to_s.downcase
  def registry_username = source_repo.to_s.split("/").first.to_s.downcase

  def servers
    @servers ||= if label_selector.present?
      wanted = label_selector.split(/[\s,]+/).to_h { it.split("=", 2) }
      Server.ordered.select { |server| wanted.all? { |key, value| server.label(key) == value } }
    else
      Server.where(id: Array(server_ids).compact_blank).ordered.to_a
    end
  end

  # Where the config goes: the first config glob with the service in place of "*".
  def config_path
    prefix, suffix = (project&.config_globs&.find { it.include?("*") } || "config/deploy*.yml").split("*", 2)
    separator = prefix.empty? || prefix.end_with?("/", ".", "-", "_") ? "" : "-"
    "#{prefix}#{separator}#{service}#{suffix}"
  end

  def version_path = project.version_path(config_path, destination.presence)

  def files
    if destination.present?
      { config_path => config(with_servers: false), project.destination_path(config_path, destination) => destination_config, version_path => "#{version}\n" }
    else
      { config_path => config(with_servers: true), version_path => "#{version}\n" }
    end
  end

  def instructions
    Rails.root.join("templates/dockerfiles/#{kind}.md").read.gsub("<service>", service.to_s)
  end

  def manual_steps
    [
      *(tunnel ? tunnel_steps : dns_steps),
      "Add a Dockerfile to #{source_repo} (see below) and have its CI push #{registry}/#{image}:<tag>.",
      "Make sure the infra repository has the KAMAL_REGISTRY_PASSWORD secret#{" and RAILS_MASTER_KEY" if kind == "rails"}.",
      "Merge the pull request. Deploys then go through the app's Deploy button."
    ]
  end

  def pull_request_body
    <<~MARKDOWN
      Adds **#{service}**, #{DESCRIPTIONS.fetch(kind)}, from `#{source_repo}`.

      - Config: `#{config_path}`#{" (destination `#{destination}`)" if destination.present?}
      - Hosts: #{servers.map { "`#{it.hostname}`" }.join(", ")}
      - URL: https://#{hostname}
      - First version: `#{version}` in `#{version_path}`

      ### Before merging

      #{manual_steps.map { "- [ ] #{it}" }.join("\n")}

      ### Dockerfile

      #{instructions}
    MARKDOWN
  end

  def submit(actor)
    return false unless valid?

    project.propose(files: files, title: "feat(#{service}): add #{kind} app", body: pull_request_body, actor: actor, slug: "new-#{service}")
  end

  private
    def dns_steps
      [
        "Point DNS for #{hostname} at #{servers.map(&:hostname).to_sentence} (or at your tunnel or load balancer).",
        "If the servers are behind NAT, route #{hostname} through your tunnel to port 80/443 on them."
      ]
    end

    def tunnel_steps
      setup = Tunnel::Setup.new(App.new(service: service, config_path: config_path, destination: destination, hostnames: [ hostname ]))
      [
        "In Cloudflare, open Networking → Tunnels, click Create Tunnel and name it #{service}.",
        "On the tunnel's Overview, under Install cloudflared connector, choose Docker and copy the command. Keep only the token, the long value after --token. Don't run the command.",
        "Set the #{setup.secret_name} secret to that token on Meridian's Secrets page, and add `#{setup.secrets_line}` to .kamal/secrets.",
        "On the tunnel's Routes tab, click Add route → Published application. Hostname #{hostname}, Service URL http://kamal-proxy:80. Cloudflare creates the DNS record.",
        "After the first deploy, run `#{setup.boot_command}` once, with #{setup.secret_name} in the environment. `kamal deploy` doesn't start accessories."
      ]
    end

    # The tunnel goes in the base file: accessories with roles resolve after
    # Kamal merges the destination file.
    def config(with_servers:)
      base = Templates.render("kamal/app.yml",
        service: service, description: DESCRIPTIONS.fetch(kind), image: image, kind: kind, source_repo: source_repo,
        servers: with_servers ? servers_yaml + "\n" : "", proxy_host: with_servers ? "  host: #{hostname}\n" : "", app_port: port,
        env: kind == "rails" ? "\nenv:\n  secret:\n    - RAILS_MASTER_KEY\n" : "", registry: registry, registry_username: registry_username)
      tunnel ? "#{base}\n#{Tunnel.snippet(Tunnel.secret_name(service))}" : base
    end

    def servers_yaml
      "servers:\n  web:\n" + servers.map { "    - #{it.hostname}\n" }.join
    end

    def destination_config
      "# #{service} in #{destination}. Generated by Meridian.\n#{servers_yaml}\nproxy:\n  host: #{hostname}\n"
    end

    def servers_chosen
      errors.add(:base, "Choose at least one server, or a label selector that matches some") if servers.empty?
    end

    def path_free
      return unless project && service.present?
      if project.apps.exists?(config_path: config_path, destination: destination.to_s)
        errors.add(:service, "already has a config at #{config_path}")
      end
    end

    # Never propose a config Kamal would reject.
    def kamal_accepts_it
      return if errors.any? || project.nil?
      result = KamalConfig.parse(files, [ { "path" => config_path, "destination" => destination.presence } ]).sole
      errors.add(:base, "Kamal rejected the generated config: #{result.dig("error", "message")}") if result["error"]
    end
end
