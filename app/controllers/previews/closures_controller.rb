# Destroy on the Previews page: asks CI to remove the preview, then drops
# its overlay once CI has. The row stays, as a removed preview.
class Previews::ClosuresController < ApplicationController
  require_deployer

  def create
    preview = Preview.find(params[:preview_id])
    preview.close(actor: current_user, reason: "destroyed by #{current_user.display_name}")
    redirect_to previews_path, notice: "Asked CI to remove pr-#{preview.pr_number}. The overlay goes once it has."
  rescue GitHost::Error => error
    redirect_to previews_path, alert: "GitHub refused: #{error.message.truncate(200)}"
  end
end
