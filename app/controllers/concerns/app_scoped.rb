# The controllers under an app. Each change ends on the app's page, saying
# what happened or why it didn't.
module AppScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_app

    # Searched last to first, so a conflict is a conflict, not any refusal.
    rescue_from(App::Refused) { |error| redirect_to @app, alert: error.message }
    rescue_from(GitHost::Error) { |error| redirect_to @app, alert: github_refused(error) }
    rescue_from GitHost::Conflict, with: :version_file_moved
  end

  private
    def set_app
      @app = App.find(params[:app_id])
    end

    def version_file_moved
      @app.project.sync_later
      redirect_to @app, alert: "The version file changed in Git since this page loaded. Meridian is re-reading it; check the new state and try again."
    end
end
