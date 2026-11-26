# Deploy and roll back are commits to the app's version file. CI does the rest.
module App::Deployable
  extend ActiveSupport::Concern

  included do
    has_many :deploys, -> { recent }, dependent: :delete_all
  end

  def version_file_path
    version_path || project.version_path(config_path, destination.presence)
  end

  # Writes `version` to the version file. Passing the blob SHA we read makes a
  # concurrent change by someone else fail instead of being overwritten.
  def deploy(version, actor:)
    version = version.to_s.strip
    raise ArgumentError, "Version can't be blank" if version.blank?
    raise ArgumentError, "Version must be one line without spaces" unless version.match?(/\A[\w.+:@-]{1,128}\z/)

    current = read_version_file
    # The commit would change no file, so the workflow would never run and
    # the deploy would wait forever.
    raise ArgumentError, "#{version} is already in #{version_file_path}. Use Redeploy to run it again." if current&.content&.strip == version

    commit = project.git.write_file(version_file_path, content: "#{version}\n", sha: current&.sha,
      message: commit_message("deploy", version, actor))
    record_deploy("deploy", version, commit, actor)
  end

  # Reverts the newest release: the version file goes back to what it held
  # before that release's commit. If Git has moved on since the last sync,
  # the release isn't the newest any more and reverting it would discard the
  # newer change, so that's a conflict.
  def roll_back(release, actor:)
    raise ArgumentError, "Only the newest release can be rolled back" unless release == latest_release
    raise GitHost::Conflict, "#{version_file_path} changed after #{release.short_sha}" unless newest_release_sha == release.commit_sha

    parent = project.git.parent_sha(release.commit_sha)
    previous = begin
      project.git.file(version_file_path, ref: parent).content.strip
    rescue GitHost::NotFound
      raise ArgumentError, "Nothing to roll back to: #{version_file_path} didn't exist before #{release.short_sha}. Deploy a version instead."
    end
    current = read_version_file

    commit = project.git.write_file(version_file_path, content: "#{previous}\n", sha: current&.sha,
      message: commit_message("rollback", previous, actor, body: "This reverts commit #{release.commit_sha}."))
    record_deploy("rollback", previous, commit, actor)
  end

  # Runs the CI workflow again for the version in the version file, e.g.
  # after a secret was rotated. CI still runs Kamal; Meridian only asks it to.
  # The file is read now, not from the last sync, so a version that just
  # landed is never replaced by the one before it. Without a version file
  # there is no image tag to give Kamal. Returns the version.
  def redeploy(actor:)
    version = read_version_file&.content.to_s.strip.presence
    raise ArgumentError, "#{name} has no version file yet: deploy a version first" unless version

    project.git.dispatch_workflow(Project::Changes::WORKFLOW_FILE, inputs: { config: config_path, destination: destination, version: version, command: "deploy" })
    Event.record("app.redeploy", subject: self, actor: actor, summary: "Redeployed #{name} at #{version}", version: version)
    version
  end

  def current_deploy
    deploys.first
  end

  private
    def read_version_file
      project.git.file(version_file_path)
    rescue GitHost::NotFound
      nil
    end

    def newest_release_sha
      project.git.commits(path: version_file_path, limit: 1).first&.sha
    end

    def commit_message(verb, version, actor, body: nil)
      [ "#{verb}(#{service}#{"-#{destination}" if destination.present?}): #{version}", body, "Meridian-Actor: #{actor.display_name} <#{actor.email_address}>" ].compact.join("\n\n")
    end

    def record_deploy(kind, version, commit, actor)
      deploy = deploys.create!(kind: kind, version: version, commit_sha: commit, actor: actor)
      Event.record("app.#{kind}", subject: self, actor: actor, summary: "#{{ "deploy" => "Deployed", "rollback" => "Rolled back" }.fetch(kind)} #{name} to #{version}", commit: commit, version: version)
      deploy
    end
end
