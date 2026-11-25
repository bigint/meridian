# Adds the CI workflow that runs Kamal to the infra repository.
class Projects::WorkflowsController < AdminController
  def create
    project = Project.find(params[:project_id])
    proposal = project.propose(
      files: { ".github/workflows/#{Project::Changes::WORKFLOW_FILE}" => project.workflow_template },
      title: "ci: deploy with Kamal when a version file changes",
      body: "Adds the workflow Meridian uses to ship deploys, rollbacks and previews. Every run is `kamal deploy` (or `kamal remove`) from this repository.\n\nBefore merging, add the `KAMAL_SSH_PRIVATE_KEY` and `KAMAL_REGISTRY_PASSWORD` repository secrets, plus any secrets your configs reference.",
      actor: current_user, slug: "ci")
    redirect_to project, notice: proposal.direct ? "Committed the workflow." : "Opened a pull request: #{proposal.url}"
  rescue GitHost::Error => error
    redirect_to project, alert: "GitHub refused: #{error.message.truncate(200)}"
  end
end
