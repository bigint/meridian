# Releases come from Git history. With a version file next to the config,
# each commit that changed it is a release of the version it wrote. Without
# one, each commit to the config is a release named by its short SHA.
module App::Releases
  extend ActiveSupport::Concern

  HISTORY = 20

  def versioned?
    version_path.present?
  end

  def record_releases
    known = releases.pluck(:commit_sha).to_set

    project.git.commits(path: release_source_path, limit: HISTORY).each do |commit|
      next if known.include?(commit.sha)

      releases.create!(
        version: versioned? ? read_version(commit.sha) : commit.sha.first(7),
        commit_sha: commit.sha, author: commit.author, committed_at: commit.committed_at, message: commit.message.lines.first.to_s.strip
      )
    end
  end

  def release_source_path
    if versioned? then version_path
    elsif destination.present? then project.destination_path(config_path, destination)
    else config_path
    end
  end

  private
    def read_version(sha)
      project.git.file(version_path, ref: sha).content.strip.presence || sha.first(7)
    rescue GitHost::NotFound
      sha.first(7)
    end
end
