module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :current_user
  end

  class_methods do
    def require_admin(**options)
      before_action(**options) { forbid unless current_user&.admin? }
    end

    def require_deployer(**options)
      before_action(**options) { forbid unless current_user&.can_deploy? }
    end
  end

  private
    def current_user
      Current.user
    end

    def forbid
      respond_to do |format|
        format.html { redirect_back_or_to main_app.root_path, alert: "You don't have permission to do that." }
        format.any { head :forbidden }
      end
    end
end
