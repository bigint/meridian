# The form behind "New app". It renders a Kamal config from a template,
# checks it with Kamal itself, and proposes it to the infra repository.
class AppDraft
  include ActiveModel::Model
  include ActiveModel::Attributes

  PORTS = { "static" => 80, "node" => 3000, "rails" => 80, "other" => 3000 }.freeze
  DESCRIPTIONS = { "static" => "a static site served by nginx", "node" => "a Next.js app (standalone output)", "rails" => "a Rails app", "other" => "a container" }.freeze
  # Behind a Cloudflare Tunnel, kamal-proxy sees cloudflared, not the
  # visitor. These headers put the visitor, their country and the Cloudflare
  # location on each request line, which the app's Traffic page shows.
  PROXY_LOGGING = <<~YAML.indent(2)
    logging:
      request_headers:
        - Cf-Connecting-Ip
        - Cf-Ipcountry
        - Cf-Ray
  YAML

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

  validates :project, :service, :source_repo, :hostname, presence: true
  validates :service, format: { with: /\A[a-z0-9][a-z0-9_-]{0,62}\z/, message: "must be lowercase letters, digits, - or _" }, allow_blank: true
  validates :source_repo, format: { with: %r{\A[\w.-]+/[\w.-]+\z}, message: "must look like owner/name" }, allow_blank: true
  validates :kind, inclusion: { in: App::KINDS }
  validates :hostname, format: { with: /\A[a-z0-9.-]+\.[a-z]{2,}\z/i, message: "must be a domain name" }, allow_blank: true
  validates :destination, format: { with: /\A[a-z0-9_-]+\z/ }, allow_blank: true
  validates :version, format: { with: App::VERSION_FORMAT }
  validates :app_port, numericality: { only_integer: true, in: 1..65_535 }, allow_nil: true
  validates :registry, format: { with: %r{\A[a-z0-9][a-z0-9.-]*(:\d{1,5})?(/[a-z0-9._-]+)*\z}i, message: "must be a registry host, such as ghcr.io" }
  validate :servers_chosen, :path_free, :names_free, :kamal_accepts_it

  attr_writer :project
  def project = @project ||= Project.find_by(id: project_id)
  def port = app_port.presence || PORTS.fetch(kind, 3000)
  def image = source_repo.to_s.downcase
  def registry_username = source_repo.to_s.split("/").first.to_s.downcase

  def servers
    @servers ||= if label_selector.present?
      wanted = selector_terms.select { it.size == 2 }.to_h
      wanted.empty? ? [] : Server.ordered.select { |server| wanted.all? { |key, value| server.label(key) == value } }
    else
      Server.where(id: Array(server_ids).compact_blank).ordered.to_a
    end
  end

  def selector_terms = label_selector.to_s.split(/[\s,]+/).compact_blank.map { it.split("=", 2) }

  def config_path = (project || Project.new).config_path_for(service)

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
      *dns_steps,
      *tunnel_steps,
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
    return false unless valid? && absent_from_git?

    project.propose(files: files, title: "feat(#{service}): add #{kind} app", body: pull_request_body, actor: actor, slug: "new-#{service}")
  end

  private
    def dns_steps
      [
        "Point DNS for #{hostname} at #{servers.map(&:hostname).to_sentence} (or at your tunnel or load balancer).",
        "If the servers are behind NAT, route #{hostname} through your tunnel to port 80/443 on them."
      ]
    end

    # The project's shared tunnel can serve the app only from servers that
    # run a connector, and only if the app runs on all of them.
    def tunnel_steps
      return [] unless tunnel
      [ "To serve it through Cloudflare Tunnel #{tunnel.name}, run it on #{tunnel.connector_hosts.to_sentence} and add a route for #{hostname} to http://kamal-proxy:80 on the tunnel." ]
    end

    def tunnel
      return @tunnel if defined?(@tunnel)
      @tunnel = Tunnel.all.find { it.project == project }
    end

    def config(with_servers:)
      Templates.render("kamal/app.yml",
        service: service, description: DESCRIPTIONS.fetch(kind), image: image, kind: kind, source_repo: source_repo,
        servers: with_servers ? servers_yaml + "\n" : "", proxy_host: with_servers ? "  host: #{hostname}\n" : "", app_port: port,
        proxy_logging: tunnel ? PROXY_LOGGING : "", env: kind == "rails" ? "\nenv:\n  secret:\n    - RAILS_MASTER_KEY\n" : "", registry: registry, registry_username: registry_username)
    end

    def servers_yaml
      "servers:\n  web:\n" + servers.map { "    - #{it.hostname}\n" }.join
    end

    def destination_config
      "# #{service} in #{destination}. Generated by Meridian.\n#{servers_yaml}\nproxy:\n  host: #{hostname}\n"
    end

    # Agents report the hostnames of servers they create, and Kamal
    # evaluates ERB in the config they are written into.
    def servers_chosen
      errors.add(:label_selector, "must be labels like role=web, separated by commas") if selector_terms.any? { it.size < 2 }
      errors.add(:base, "Choose at least one server, or a label selector that matches some") if servers.empty?
      bad = servers.reject { it.hostname.match?(Server::HOST_FORMAT) }
      errors.add(:base, "Can't write these servers into a config, their hostnames aren't host names: #{bad.map(&:name).to_sentence}") if bad.any?
    end

    # Any destination counts: a new destination of an existing config would
    # rewrite the config the existing app deploys from.
    def path_free
      return unless project && service.present?
      unless project.config_paths([ config_path ]).key?(config_path)
        return errors.add(:base, "#{config_path} isn't matched by the project's config paths (#{project.config_globs.join(", ")}), so Meridian would never see it. Add a path with a * to the project.")
      end
      paths = [ config_path, (project.destination_path(config_path, destination) if destination.present?) ].compact
      if (taken = project.apps.where(config_path: paths).pick(:config_path))
        errors.add(:service, "already has a config at #{taken}")
      end
    end

    # Two configs with one service (and destination) name the same containers
    # and kamal-proxy service, and kamal-proxy gives a host to one service.
    def names_free
      if project && service.present? && (twin = project.apps.find_by(service: service, destination: destination.to_s))
        errors.add(:service, "is already the service of #{twin.name}, in #{twin.config_path}")
      end
      if hostname.present? && (owner = App.where.not(hostnames: []).find { it.hostnames.any? { |taken| taken.casecmp?(hostname) } })
        errors.add(:hostname, "is already served by #{owner.name}")
      end
    end

    # A new app never replaces a file, even one Meridian doesn't list as an
    # app, such as a config Kamal can't parse.
    def absent_from_git?
      taken = files.keys.select do |path|
        project.git.file(path)
        true
      rescue GitHost::NotFound
        false
      end
      errors.add(:base, "#{taken.to_sentence} already #{taken.one? ? "exists" : "exist"} in #{project.repo_full_name}") if taken.any?
      taken.empty?
    end

    # Never propose a config Kamal would reject.
    def kamal_accepts_it
      return if errors.any? || project.nil?
      result = KamalConfig.parse(files, [ { "path" => config_path, "destination" => destination.presence } ]).sole
      errors.add(:base, "Kamal rejected the generated config: #{result.dig("error", "message")}") if result["error"]
    end
end
