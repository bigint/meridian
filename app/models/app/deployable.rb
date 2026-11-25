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
    commit = project.git.write_file(version_file_path, content: "#{version}\n", sha: current&.sha,
      message: commit_message("deploy", version, actor))
    record_deploy("deploy", version, commit, actor)
  end

  # Reverts the newest release: the version file goes back to what it held
  # before that release's commit.
  def roll_back(release, actor:)
    raise ArgumentError, "Only the newest release can be rolled back" unless release == latest_release

    parent = project.git.parent_sha(release.commit_sha)
    previous = project.git.file(version_file_path, ref: parent).content.strip
    current = read_version_file

    commit = project.git.write_file(version_file_path, content: "#{previous}\n", sha: current&.sha,
      message: commit_message("rollback", previous, actor, body: "This reverts commit #{release.commit_sha}."))
    record_deploy("rollback", previous, commit, actor)
  end

  # Runs the CI workflow again for the current version, e.g. after a secret
  # was rotated. CI still runs Kamal; Meridian only asks it to.
  def redeploy(actor:)
    version = latest_release&.version or raise ArgumentError, "Nothing to redeploy yet"
    project.git.dispatch_workflow(Project::Changes::WORKFLOW_FILE, inputs: { config: config_path, destination: destination, version: version, command: "deploy" })
    Event.record("app.redeploy", subject: self, actor: actor, summary: "Redeployed #{name} at #{version}", version: version)
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

    def commit_message(verb, version, actor, body: nil)
      [ "#{verb}(#{service}#{"-#{destination}" if destination.present?}): #{version}", body, "Meridian-Actor: #{actor.display_name} <#{actor.email_address}>" ].compact.join("\n\n")
    end

    def record_deploy(kind, version, commit, actor)
      deploy = deploys.create!(kind: kind, version: version, commit_sha: commit, actor: actor)
      Event.record("app.#{kind}", subject: self, actor: actor, summary: "#{{ "deploy" => "Deployed", "rollback" => "Rolled back" }.fetch(kind)} #{name} to #{version}", commit: commit, version: version)
      deploy
    end
end
