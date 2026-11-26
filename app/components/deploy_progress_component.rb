# The current deploy of an app: who, what, CI, and each server's progress as
# its agent reports the new version running.
class DeployProgressComponent < ApplicationComponent
  def initialize(deploy:, app:)
    @deploy, @app = deploy, app
  end

  private
    def heading
      verb = { "rollback" => "Rollback to", "redeploy" => "Redeploy of" }.fetch(@deploy.kind, "Deploy of")
      safe_join([ verb, " ", tag.code(@deploy.version), " · ", @deploy.state_label ])
    end

    def tone
      return :info unless @deploy.finished?
      @deploy.succeeded? ? :ok : :bad
    end
end
