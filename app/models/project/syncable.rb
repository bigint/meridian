# Reads the project's Kamal configs from Git and records what should run where.
#
# Only blobs whose SHA changed are fetched; everything else comes from cache.
# Parsing is done by Kamal itself (see KamalConfig).
module Project::Syncable
  extend ActiveSupport::Concern

  PREVIEW_DESTINATION = /\Apr-\d+\z/
  DESTINATION_FILE = /\.([^.\/]+)\.yml\z/

  def sync(force: false)
    sha = git.head_sha
    return false if sha == last_synced_sha && !force

    tree = git.tree(sha).index_by(&:path)
    configs = config_paths(tree.keys)
    entries = configs.flat_map { |path, destinations| destinations.map { |destination| { "path" => path, "destination" => destination } } }
    files = (configs.keys + configs.flat_map { |path, destinations| destinations.compact.map { destination_path(path, it) } })
      .index_with { |path| read_blob(tree.fetch(path)) }

    results = begin
      entries.any? ? KamalConfig.parse(files, entries) : []
    rescue KamalConfig::Error => error
      # One config that hangs or kills the parser stops them all. Nothing
      # parsed, so no app can be told apart from a removed one: keep them
      # all, and say why on the project.
      update!(last_synced_sha: sha, synced_at: Time.current, config_errors: [ { "class" => error.class.name, "message" => error.message, "file" => nil, "line" => nil } ])
      return true
    end

    # Everything that reads GitHub happens before the transaction: SQLite has
    # one writer, and a write lock held across hundreds of API calls would
    # stall every snapshot and sign-in until they were done.
    found = results.map { |result| [ result, app_for(result) ] }
    parsed = found.reject { |result, _| result["error"] }.map { |result, app| app.assign_config(result, tree) }
    releases = parsed.index_with { it.releases_due? ? it.fetch_releases : [] }
    # A config that fails to parse keeps its app, with its deploys, releases
    # and previews, until it parses again; only a config gone from Git goes.
    gone = apps.where.not(id: found.filter_map { |_, app| app.id }).to_a
    gone.each(&:abandon_previews)

    transaction do
      parsed.each { it.record_config(releases[it]) }
      gone.each(&:destroy)
      SecretName.record(self)
      update!(last_synced_sha: sha, synced_at: Time.current, config_errors: results.filter_map { it["error"] })
    end
    true
  end

  def sync_later
    ProjectSyncJob.perform_later(self)
  end

  # { "deploy/web.yml" => ["production", "staging"], "deploy/blog.yml" => [nil] }
  def config_paths(paths)
    matched = paths.select { |path| config_globs.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) } }
    # A preview overlay is only ever a destination: without its base config
    # it is a leftover, not a config of its own.
    matched = matched.select { it.end_with?(".yml", ".yaml") }.reject { destination_of(it)&.match?(PREVIEW_DESTINATION) }

    bases = matched.reject { |path| base_for(path, matched) }
    bases.sort.index_with do |base|
      destinations = matched.filter_map { |path| destination_of(path) if base_for(path, matched) == base }
      destinations.sort.presence || [ nil ]
    end
  end

  def destination_path(path, destination)
    path.sub(/\.ya?ml\z/, ".#{destination}.yml")
  end

  def version_path(path, destination)
    path.sub(/\.ya?ml\z/, [ destination, "version" ].compact.map { ".#{it}" }.join)
  end

  private
    # Not built through `apps`: an unsaved app there would be validated, and
    # fail, when the project is saved.
    def app_for(result)
      attributes = { config_path: result["path"], destination: result["destination"].to_s }
      apps.find_by(attributes) || App.new(project: self, **attributes)
    end

    # "deploy/web.staging.yml" is a destination file when "deploy/web.yml"
    # (or .yaml) exists. Kamal only ever looks for <base>.<destination>.yml.
    def base_for(path, matched)
      return unless path.match?(DESTINATION_FILE)
      %w[ .yml .yaml ].map { path.sub(DESTINATION_FILE, it) }.find { matched.include?(it) }
    end

    def destination_of(path)
      path[DESTINATION_FILE, 1]
    end

    def read_blob(entry)
      Rails.cache.fetch([ "git-blob", entry.sha ]) { git.blob(entry.sha) }
    end
end
