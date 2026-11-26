# A pull request in an app's source repository, running as a Kamal
# destination `pr-<n>`. The overlay file sits next to the base config, where
# Kamal looks for destination files (see contributing/architecture.md). CI deploys and
# removes it; Meridian only commits the overlay and asks CI to run.
class Preview < ApplicationRecord
  STATES = %w[ deploying active failed removing removed ].freeze
  # Expiry asks CI this many times to remove a preview, then leaves it to a person.
  REMOVE_ATTEMPTS = 3

  belongs_to :app

  enum :state, STATES.index_by(&:itself), validate: true

  scope :current, -> { where.not(state: "removed") }
  scope :expired, -> { where(state: %w[ deploying active failed ], remove_attempts: ...REMOVE_ATTEMPTS).where(expires_at: ..Time.current) }
  scope :ordered, -> { order(created_at: :desc) }

  after_commit -> { broadcast_refresh_later_to :previews }

  class << self
    # Opened, reopened or pushed to: commit the overlay once (again after a
    # removal), deploy the head.
    def deploy(app, number:, head_sha:, url:)
      account = Account.current
      raise ArgumentError, "Set a preview domain in Settings first" if account.preview_domain.blank?

      preview = app.previews.find_or_initialize_by(pr_number: number)
      # Asked before the state below changes: a removed preview's overlay is gone.
      fresh = preview.new_record? || preview.removed?
      # One being removed, or past its time, comes back for a whole lifetime;
      # otherwise the next hourly expiry would take it down again.
      revived = fresh || preview.removing? || preview.expires_at.past?
      preview.assign_attributes(pr_url: url, head_sha: head_sha, state: "deploying", remove_attempts: 0)
      preview.expires_at = account.preview_ttl_days.days.from_now if revived
      if fresh
        preview.destination = "pr-#{number}"
        preview.hostname = account.preview_hostname(app.service, number)
        preview.overlay_path = app.project.destination_path(app.config_path, preview.destination)
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
      return true unless project

      preview = Preview.joins(:app).find_by(apps: { project_id: project.id, config_path: config }, destination: destination) or return true
      return true unless preview.current_run?(run) && run["status"] == "completed"
      # A run GitHub cancelled because a newer one queued says nothing.
      return true if run["conclusion"].in?(%w[ cancelled skipped ])

      success = run["conclusion"] == "success"
      # Only a preview still waiting on its removal is finished by one: a
      # remove run replayed by polling, or one that ends after the pull
      # request reopened, must not take down the preview deployed since.
      # A failed removal goes back to failed, where Destroy and expiry try again.
      if command == "remove" && preview.removing? then success ? preview.finish_removal : preview.removal_failed
      # Runs for one preview run one at a time, so the last to finish is the
      # newest, whether the state before it was deploying, active or failed.
      elsif command == "deploy" && !preview.removing? && !preview.removed? then preview.update!(state: success ? "active" : "failed")
      end
      true
    end

    # Hourly: closes expired previews, and drops the overlay of a removal whose
    # CI run never reported back after a day.
    def expire_all
      expired.find_each { expiring(it) { it.close(reason: "expired") } }
      where(state: "removing").where(updated_at: ..1.day.ago).find_each { expiring(it, &:finish_removal) }
    end

    private
      # One project GitHub refuses (an uninstalled App, a missing workflow)
      # mustn't stop every other preview from expiring.
      def expiring(preview)
        yield preview
      rescue GitHost::Error => error
        Rails.logger.warn("Preview #{preview.app.name} ##{preview.pr_number} not expired: #{error.message}")
      end
  end

  def url = "https://#{hostname}"
  def label = "#{app.source_repo}##{pr_number}" # as the Previews page lists it
  def project = app.project

  # Closed or expired: ask CI to `kamal app remove`, then drop the overlay once it has.
  def close(actor: nil, reason: "closed")
    return if removing? || removed?

    dispatch("remove")
    update!(state: "removing", remove_attempts: remove_attempts + 1)
    Event.record("preview.removing", subject: self, actor: actor, summary: "Removing #{app.service} preview for ##{pr_number} (#{reason})")
  end

  # Back to failed, overlay kept, so Destroy and expiry can ask again; after
  # REMOVE_ATTEMPTS failures expiry stops asking, and a person has to look.
  def removal_failed
    update!(state: "failed")
    return unless removal_given_up?

    Event.record("preview.removal_failed", subject: self,
      summary: "CI failed to remove the #{app.service} preview for ##{pr_number} #{remove_attempts} times; expiry has stopped trying. Check the runs, then Destroy it again or remove the #{app.service} #{destination} containers by hand")
  end

  def removal_given_up?
    failed? && remove_attempts >= REMOVE_ATTEMPTS
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

  # Its app's config left Git (see App#abandon_previews). The overlay is
  # deleted directly, and the activity log says which containers are left
  # to remove by hand, and where.
  def abandon
    existing = project.git.file_or_nil(overlay_path)
    hosts = existing ? overlay_hosts(existing.content) : []
    project.git.delete_file(overlay_path, sha: existing.sha, message: "chore(#{app.service}): remove preview pr-#{pr_number}, its config is gone") if existing
    left = "#{app.service} #{destination} containers#{" on #{hosts.to_sentence}" if hosts.any?}"
    Event.record("preview.abandoned", subject: self, summary: "#{app.config_path} left Git, so CI can't remove the #{app.service} preview for ##{pr_number}. Meridian deleted #{overlay_path}; remove the #{left} by hand")
  rescue GitHost::Error => error
    Event.record("preview.abandoned", subject: self, summary: "#{app.config_path} left Git, so CI can't remove the #{app.service} preview for ##{pr_number}, and GitHub refused to delete #{overlay_path} (#{error.message.truncate(100)}). Remove the file and the #{app.service} #{destination} containers by hand")
  end

  def commit_overlay
    content = overlay
    result = KamalConfig.parse({ app.config_path => base_config, overlay_path => content }, [ { "path" => app.config_path, "destination" => destination } ]).sole
    raise ArgumentError, "Kamal rejected the preview overlay: #{result.dig("error", "message")}" if result["error"]

    existing = project.git.file_or_nil(overlay_path)
    project.git.write_file(overlay_path, content: content, sha: existing&.sha, message: "chore(#{app.service}): preview pr-#{pr_number}")
    Event.record("preview.opened", subject: self, summary: "Preview of #{app.source_repo}##{pr_number} at #{hostname}")
  end

  # Every run seen so far was asked for before this dispatch, so none of them
  # speaks for it. Read from the database: a webhook job may have seen a
  # newer run than this copy knows.
  def dispatch(command, version: nil)
    seen = Preview.where(id: id).pick(:latest_run_id)
    project.git.dispatch_workflow(Project::Changes::WORKFLOW_FILE,
      inputs: { config: app.config_path, destination: destination, version: version.to_s, command: command })
    update_columns(dispatched_after_run_id: seen) if seen
  end

  # Polling replays the newest finished run, and GitHub may redeliver an old
  # one. A run from before the latest dispatch, such as the failed removal a
  # retry was asked for after, must not undo it. Run ids only grow.
  def current_run?(run)
    id = run["id"]&.to_i or return true
    return false if dispatched_after_run_id && id <= dispatched_after_run_id

    update_columns(latest_run_id: id) if latest_run_id.nil? || id > latest_run_id
    true
  end

  def server
    account = Account.current
    candidates = if account.preview_selector.blank? then app.servers.ordered.to_a
    elsif (labels = account.preview_labels).any? then Server.labelled(labels)
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
    # name it runs; then the preview's own server and hostname. The service
    # stays the app's: Kamal only boots an image whose service label matches it.
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
        "service" => app.service,
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

    # The servers an overlay runs on, from servers.<role> as a list or as a hash with hosts.
    def overlay_hosts(text)
      servers = load_yaml(text)["servers"]
      roles = servers.is_a?(Hash) ? servers.values : Array(servers)
      roles.flat_map { it.is_a?(Hash) ? Array(it["hosts"]) : Array(it) }.map(&:to_s).uniq
    end

    def load_yaml(text)
      YAML.safe_load(text, aliases: true).to_h
    rescue Psych::Exception
      {}
    end
end
