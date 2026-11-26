# Adds the CI workflow that runs Kamal to the infra repository.
class Projects::WorkflowsController < AdminController
  def create
    project = Project.find(params[:project_id])
    proposal = project.propose_workflow(actor: current_user)
    redirect_to project, notice: proposal.direct ? "Committed the workflow." : "Opened a pull request: #{proposal.url}"
  rescue GitHost::Error => error
    redirect_to project, alert: "GitHub refused: #{error.message.truncate(200)}"
  end
end
