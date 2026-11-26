# Acts on one GitHub webhook. Only fields Meridian uses are kept in arguments.
class GitHubEventJob < ApplicationJob
  queue_as :default
  limits_concurrency key: ->(_event, payload) { payload.dig("repository", "full_name").to_s.downcase }, group: "github_repository"

  def perform(event, payload)
    repo = payload.dig("repository", "full_name")

    case event
    when "push" then pushed(repo, payload)
    when "workflow_run" then workflow_run(repo, payload)
    when "pull_request" then pull_request(repo, payload)
    end
  end

  private
    def pushed(repo, payload)
      project = Project.for_repo(repo) or return
      project.sync if payload["ref"] == "refs/heads/#{project.default_branch}"
    end

    # Previews are matched within the run's repository, which the run names.
    def workflow_run(repo, payload)
      run = payload["workflow_run"] or return
      Project.for_repo(repo)&.track_workflow_run(run.reverse_merge("repository" => payload["repository"]))
    end

    # Previews follow pull requests in an app's source repository.
    def pull_request(repo, payload)
      pull = payload["pull_request"] or return
      App.where("LOWER(source_repo) = ?", repo.to_s.downcase).find_each do |app|
        case payload["action"]
        when "opened", "reopened", "synchronize"
          # A late delivery for a pull request that has closed since.
          next if pull["state"] == "closed"

          Preview.deploy(app, number: payload["number"], head_sha: pull.dig("head", "sha"), url: pull["html_url"])
        when "closed"
          app.previews.find_by(pr_number: payload["number"])&.close(reason: pull["merged"] ? "merged" : "closed")
        end
      rescue ArgumentError, GitHost::Error => error
        Rails.logger.warn("Preview for #{app.name} ##{payload["number"]} skipped: #{error.message}")
      end
    end
end
