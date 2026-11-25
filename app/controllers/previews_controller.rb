class PreviewsController < ApplicationController
  require_deployer only: :destroy

  def index
    @previews = Preview.current.includes(app: :project).ordered
    @recent = Preview.removed.includes(:app).order(updated_at: :desc).limit(10)
  end

  def destroy
    preview = Preview.find(params[:id])
    preview.close(actor: current_user, reason: "destroyed by #{current_user.display_name}")
    redirect_to previews_path, notice: "Asked CI to remove pr-#{preview.pr_number}. The overlay goes once it has."
  rescue GitHost::Error => error
    redirect_to previews_path, alert: "GitHub refused: #{error.message.truncate(200)}"
  end
end
