# Releases come from Git history. With a version file next to the config,
# each commit that changed it is a release of the version it wrote. Without
# one, each commit to the config is a release named by its short SHA.
module App::Releases
  extend ActiveSupport::Concern

  HISTORY = 20

  def versioned?
    version_path.present?
  end

  # The commits that are releases Meridian doesn't know yet, read from Git,
  # newest first as GitHub lists them.
  # Nothing is written, so sync can call this outside its transaction.
  def fetch_releases
    known = releases.pluck(:commit_sha).to_set

    project.git.commits(path: release_source_path, limit: HISTORY).reject { known.include?(it.sha) }.map do |commit|
      {
        version: versioned? ? read_version(commit.sha) : commit.sha.first(7),
        commit_sha: commit.sha, author: commit.author, committed_at: commit.committed_at, message: commit.message.lines.first.to_s.strip
      }
    end
  end

  def record_releases(fetched)
    # Oldest first, so the newest of commits in the same second has the highest id.
    releases.create!(fetched.reverse)
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
