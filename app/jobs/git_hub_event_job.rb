# Acts on one GitHub webhook. Only fields Meridian uses are kept in arguments.
class GitHubEventJob < ApplicationJob
  queue_as :default
  limits_concurrency key: ->(_event, payload) { payload.dig("repository", "full_name").to_s.downcase }, group: "github_repository"

  def perform(event, payload)
    repo = payload.dig("repository", "full_name")

    case event
    when "push" then pushed(repo, payload)
    when "workflow_run" then workflow_run(repo, payload)
    end
  end

  private
    def pushed(repo, payload)
      project = Project.for_repo(repo) or return
      project.sync if payload["ref"] == "refs/heads/#{project.default_branch}"
    end

    def workflow_run(repo, payload)
      run = payload["workflow_run"] or return
      Project.for_repo(repo)&.track_workflow_run(run)
    end
end
