# Changes Meridian proposes to the infra repository. A pull request by
# default; a direct commit when the project allows it and an admin asks.
module Project::Changes
  extend ActiveSupport::Concern

  Proposal = Data.define(:url, :number, :direct)
  WORKFLOW_FILE = "meridian-deploy.yml"

  def propose(files:, title:, body:, actor:, slug:)
    if direct_commits? && actor.admin?
      sha = files.each_with_object([]) { |(path, content), shas| shas << write(path, content, title, actor) }.last
      Event.record("project.committed", subject: self, actor: actor, summary: title, commit: sha, files: files.keys)
      Proposal.new(url: git.commit_url(sha), number: nil, direct: true)
    else
      branch = "meridian/#{slug}-#{SecureRandom.hex(3)}"
      git.create_branch(branch, from: git.head_sha)
      files.each { |path, content| write(path, content, title, actor, branch: branch) }
      number, url = git.create_pull_request(head: branch, title: title, body: body)
      Event.record("project.pull_request", subject: self, actor: actor, summary: title, pull_request: url, files: files.keys)
      Proposal.new(url: url, number: number, direct: false)
    end
  end

  def propose_workflow(actor:)
    propose(
      files: { ".github/workflows/#{WORKFLOW_FILE}" => workflow_template },
      title: "ci: deploy with Kamal when a version file changes",
      body: "Adds the workflow Meridian uses to ship deploys, rollbacks and redeploys. Every run is `kamal deploy` from this repository.\n\nBefore merging, add the `KAMAL_SSH_PRIVATE_KEY` and `KAMAL_REGISTRY_PASSWORD` repository secrets, plus any secrets your configs reference.",
      actor: actor, slug: "ci")
  end

  def workflow_template
    Templates.render("github/meridian-deploy.yml", branch: default_branch, kamal_version: KamalConfig::KAMAL_VERSION)
  end

  private
    def write(path, content, title, actor, branch: default_branch)
      existing = git.file_or_nil(path, ref: branch)
      git.write_file(path, content: content, sha: existing&.sha, branch: branch, message: "#{title}\n\n#{actor.commit_trailer}")
    end
end
