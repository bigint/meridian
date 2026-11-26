# A pull request in an app's source repository, running as a Kamal
# destination `pr-<n>`. The overlay file sits next to the base config, where
# Kamal looks for destination files (see docs/architecture.md). CI deploys and
# removes it; Meridian only commits the overlay and asks CI to run.
class Preview < ApplicationRecord
  STATES = %w[ deploying active failed removing removed ].freeze

  belongs_to :app

  enum :state, STATES.index_by(&:itself), validate: true

  scope :current, -> { where.not(state: "removed") }
  scope :expired, -> { where(state: %w[ deploying active failed ]).where(expires_at: ..Time.current) }
  scope :ordered, -> { order(created_at: :desc) }

  after_commit -> { broadcast_refresh_later_to :previews }

  class << self
    # Opened, reopened or pushed to: commit the overlay once, deploy the head.
    def deploy(app, number:, head_sha:, url:)
      account = Account.current
      raise ArgumentError, "Set a preview domain in Settings first" if account.preview_domain.blank?

      preview = app.previews.find_or_initialize_by(pr_number: number)
      preview.assign_attributes(pr_url: url, head_sha: head_sha, state: "deploying")
      if preview.new_record? || preview.removed?
        preview.destination = "pr-#{number}"
        preview.hostname = account.preview_hostname(app.service, number)
        preview.overlay_path = app.project.destination_path(app.config_path, preview.destination)
        preview.expires_at = account.preview_ttl_days.days.from_now
        preview.commit_overlay
      end
      preview.save!
      begin
        preview.dispatch("deploy", version: head_sha)
      rescue GitHost::Error
        preview.update!(state: "failed")
        raise
      end
      preview
    end

    # Matches a workflow run to a preview by its run name: "<command> <config> pr-<n>",
    # within the run's own repository: many repositories have a config/deploy.yml.
    def track(run, project = Project.for_repo(run.dig("repository", "full_name")))
      command, config, destination = run["display_title"].to_s.split(" ", 3)
      return unless destination.to_s.match?(Project::Syncable::PREVIEW_DESTINATION)
      return true unless run["status"] == "completed" && project

      preview = Preview.joins(:app).find_by(apps: { project_id: project.id, config_path: config }, destination: destination) or return true
      # A run GitHub cancelled because a newer one queued says nothing.
      return true if run["conclusion"].in?(%w[ cancelled skipped ])

      success = run["conclusion"] == "success"
      # Only a preview still waiting on its removal is finished by one: a
      # remove run replayed by polling, or one that ends after the pull
      # request reopened, must not take down the preview deployed since.
      # A failed removal goes back to failed, where Destroy and expiry try again.
      if command == "remove" && preview.removing? then success ? preview.finish_removal : preview.update!(state: "failed")
      # Runs for one preview run one at a time, so the last to finish is the
      # newest, whether the state before it was deploying, active or failed.
      elsif command == "deploy" && !preview.removing? && !preview.removed? then preview.update!(state: success ? "active" : "failed")
      end
      true
    end
  end

  def url = "https://#{hostname}"
  def project = app.project

  # Closed or expired: ask CI to `kamal app remove`, then drop the overlay once it has.
  def close(actor: nil, reason: "closed")
    return if removing? || removed?

    dispatch("remove")
    update!(state: "removing")
    Event.record("preview.removing", subject: self, actor: actor, summary: "Removing #{app.service} preview for ##{pr_number} (#{reason})")
  end

  # Removed once the overlay is gone. If GitHub refuses the delete, the
  # preview stays in removing, and the hourly job tries again.
  def finish_removal
    existing = project.git.file(overlay_path)
    project.git.delete_file(overlay_path, sha: existing.sha, message: "chore(#{app.service}): remove preview pr-#{pr_number}")
    update!(state: "removed")
  rescue GitHost::NotFound
    update!(state: "removed")
  end

  def commit_overlay
    content = overlay
    result = KamalConfig.parse({ app.config_path => base_config, overlay_path => content }, [ { "path" => app.config_path, "destination" => destination } ]).sole
    raise ArgumentError, "Kamal rejected the preview overlay: #{result.dig("error", "message")}" if result["error"]

    existing = begin
      project.git.file(overlay_path)
    rescue GitHost::NotFound
      nil
    end
    project.git.write_file(overlay_path, content: content, sha: existing&.sha, message: "chore(#{app.service}): preview pr-#{pr_number}")
    Event.record("preview.opened", subject: self, summary: "Preview of #{app.source_repo}##{pr_number} at #{hostname}")
  end

  def dispatch(command, version: nil)
    project.git.dispatch_workflow(Project::Changes::WORKFLOW_FILE,
      inputs: { config: app.config_path, destination: destination, version: version.to_s, command: command })
  end

  def server
    account = Account.current
    candidates = if account.preview_selector.blank? then app.servers.ordered.to_a
    elsif (labels = account.preview_labels).any? then Server.ordered.select { |s| labels.all? { |k, v| s.label(k) == v } }
    else []
    end
    # Its hostname goes into the overlay, where Kamal evaluates ERB.
    candidates = candidates.select { it.hostname.match?(Server::HOST_FORMAT) }
    candidates.min_by { |s| [ s.placements.count, s.id ] } or raise ArgumentError, "No server matches the preview selector"
  end

  private
    def base_config
      @base_config ||= project.git.file(app.config_path).content
    end

    # The app's destination file, if it has one, minus where and under which
    # name it runs; then the preview's own service, server and hostname.
    # Each role keeps its settings (cmd, env, options) from the base config
    # and the destination file, and runs on the preview server.
    def overlay
      base = load_yaml(base_config)
      inherited = app.destination.present? ? load_yaml(project.git.file(project.destination_path(app.config_path, app.destination)).content) : {}
      proxy = inherited.fetch("proxy", {}).except("host", "hosts")
      roles = (app.roles.map { it["name"] }.presence || [ "web" ]).index_with { |role| [ base, inherited ].map { role_options(it, role) }.reduce(:deep_merge) }
      proxy_key = [ base, inherited, *roles.values ].any? { it["proxy"].is_a?(Hash) && it["proxy"].key?("hosts") } ? "hosts" : "host"
      host = proxy_key == "hosts" ? [ hostname ] : hostname
      preview_server = server.hostname

      servers = roles.to_h do |role, options|
        # A role's own proxy host is the real app's, so the preview takes its place.
        options = options.merge("proxy" => options["proxy"].except("host", "hosts").merge(proxy_key => host)) if options["proxy"].is_a?(Hash) && options["proxy"].keys.intersect?(%w[ host hosts ])
        [ role, options.empty? ? [ preview_server ] : options.merge("hosts" => [ preview_server ]) ]
      end

      settings = inherited.except("service", "servers", "proxy").merge(
        "service" => "#{app.service}-pr-#{pr_number}",
        "servers" => servers,
        "proxy" => proxy.merge(proxy_key => host)
      )

      "# Preview of #{app.source_repo}##{pr_number}. Generated by Meridian.\n" \
        "# Removed when the pull request closes, or on #{expires_at.to_date.iso8601}.\n" +
        YAML.dump(settings).delete_prefix("---\n")
    end

    # servers.<role> as a hash, minus its hosts; a plain list of hosts has none.
    def role_options(config, role)
      options = config["servers"].is_a?(Hash) ? config["servers"][role] : nil
      options.is_a?(Hash) ? options.except("hosts") : {}
    end

    def load_yaml(text)
      YAML.safe_load(text, aliases: true).to_h
    rescue Psych::Exception
      {}
    end
end
