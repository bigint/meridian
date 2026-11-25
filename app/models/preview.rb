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
        preview.hostname = "pr-#{number}.#{app.service}.#{account.preview_domain}"
        preview.overlay_path = app.project.destination_path(app.config_path, preview.destination)
        preview.expires_at = account.preview_ttl_days.days.from_now
        preview.commit_overlay
      end
      preview.save!
      preview.dispatch("deploy", version: head_sha)
      preview
    end

    # Matches a workflow run to a preview by its run name: "<command> <config> pr-<n>".
    def track(run)
      command, config, destination = run["display_title"].to_s.split(" ", 3)
      return unless destination.to_s.match?(Project::Syncable::PREVIEW_DESTINATION)
      return true unless run["status"] == "completed"

      preview = Preview.joins(:app).find_by(apps: { config_path: config }, destination: destination) or return true
      success = run["conclusion"] == "success"
      if command == "remove" && success then preview.finish_removal
      elsif command == "deploy" && preview.deploying? then preview.update!(state: success ? "active" : "failed")
      end
      true
    end
  end

  def url = "https://#{hostname}"
  def project = app.project

  # Closed or expired: ask CI to `kamal remove`, then drop the overlay once it has.
  def close(actor: nil, reason: "closed")
    return if removing? || removed?

    dispatch("remove")
    update!(state: "removing")
    Event.record("preview.removing", subject: self, actor: actor, summary: "Removing #{app.service} preview for ##{pr_number} (#{reason})")
  end

  def finish_removal
    existing = project.git.file(overlay_path)
    project.git.delete_file(overlay_path, sha: existing.sha, message: "chore(#{app.service}): remove preview pr-#{pr_number}")
  rescue GitHost::NotFound
    nil
  ensure
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
    selector = Account.current.preview_selector.to_s.split(/[\s,]+/).to_h { it.split("=", 2) }
    candidates = selector.any? ? Server.ordered.select { |s| selector.all? { |k, v| s.label(k) == v } } : app.servers.ordered.to_a
    candidates.min_by { |s| [ s.placements.count, s.id ] } or raise ArgumentError, "No server matches the preview selector"
  end

  private
    def base_config
      @base_config ||= project.git.file(app.config_path).content
    end

    # The app's destination file, if it has one, minus where and under which
    # name it runs; then the preview's own service, server and hostname.
    def overlay
      inherited = app.destination.present? ? load_yaml(project.git.file(project.destination_path(app.config_path, app.destination)).content) : {}
      proxy = inherited.fetch("proxy", {}).except("host", "hosts")
      proxy_key = [ load_yaml(base_config), inherited ].any? { it.dig("proxy", "hosts") } ? "hosts" : "host"
      roles = app.roles.map { it["name"] }.presence || [ "web" ]

      settings = inherited.except("service", "servers", "proxy").merge(
        "service" => "#{app.service}-pr-#{pr_number}",
        "servers" => roles.index_with { [ server.hostname ] },
        "proxy" => proxy.merge(proxy_key => proxy_key == "hosts" ? [ hostname ] : hostname)
      )

      "# Preview of #{app.source_repo}##{pr_number}. Generated by Meridian.\n" \
        "# Removed when the pull request closes, or on #{expires_at.to_date.iso8601}.\n" +
        YAML.dump(settings).delete_prefix("---\n")
    end

    def load_yaml(text)
      YAML.safe_load(text, aliases: true).to_h
    rescue Psych::Exception
      {}
    end
end
