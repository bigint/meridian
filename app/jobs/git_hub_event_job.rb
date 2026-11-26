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

    def workflow_run(repo, payload)
      run = payload["workflow_run"] or return
      Project.for_repo(repo)&.track_workflow_run(run)
    end

    # Previews follow pull requests in an app's source repository.
    def pull_request(repo, payload)
      pull = payload["pull_request"] or return
      apps = App.where("LOWER(source_repo) = ?", repo.to_s.downcase).to_a

      case payload["action"]
      when "opened", "reopened", "synchronize"
        # A late delivery for a pull request that has closed since.
        return if apps.empty? || pull["state"] == "closed" || from_fork?(repo, pull, payload)

        one_per_config(apps, payload["number"]).each do |app|
          previewing(app, payload) { Preview.deploy(app, number: payload["number"], head_sha: pull.dig("head", "sha"), url: pull["html_url"]) }
        end
      when "closed"
        apps.each { |app| previewing(app, payload) { app.previews.find_by(pr_number: payload["number"])&.close(reason: pull["merged"] ? "merged" : "closed") } }
      end
    end

    # The apps of one config (its staging and production destinations) would
    # all write <config>.pr-<n>.yml, so a config gets one preview: the one it
    # already runs, or else its first app's, by destination.
    def one_per_config(apps, number)
      apps.sort_by { [ it.destination, it.id ] }.group_by { [ it.project_id, it.config_path ] }.values.map do |siblings|
        siblings.find { it.previews.current.exists?(pr_number: number) } || siblings.first
      end
    end

    def previewing(app, payload)
      yield
    rescue ArgumentError, GitHost::Error => error
      Rails.logger.warn("Preview for #{app.name} ##{payload["number"]} skipped: #{error.message}")
    end

    # A fork's code is anyone's code: it never runs on the servers, with the
    # app's secrets. Said once in the activity log, when the pull request opens.
    def from_fork?(repo, pull, payload)
      head = pull.dig("head", "repo", "full_name")
      return false if head.to_s.casecmp?(repo.to_s)

      summary = "No preview for #{repo}##{payload["number"]}: it comes from #{head ? "the fork #{head}" : "a deleted fork"}"
      Rails.logger.info(summary)
      Event.record("preview.skipped", summary: summary, pull_request: pull["html_url"]) unless payload["action"] == "synchronize"
      true
    end
end
