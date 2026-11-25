# The seam between Meridian and a Git host. GitHub is the only implementation;
# GitLab or Forgejo would implement the same handful of methods.
module GitHost
  Commit = Data.define(:sha, :author, :committed_at, :message)
  Entry = Data.define(:path, :sha)
  Content = Data.define(:path, :content, :sha)

  class Error < StandardError; end
  class Conflict < Error; end
  class NotFound < Error; end

  def self.for(project)
    case project.git_host
    when "github" then GitHost::GitHub.new(project)
    else raise ArgumentError, "Unknown git host: #{project.git_host}"
    end
  end
end
