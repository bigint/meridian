# Deploys that finished before Meridian recorded their outcome get one in the
# activity trail, at the time they finished.
class RecordPastDeployOutcomes < ActiveRecord::Migration[8.1]
  def up
    Deploy.where(status: "completed").includes(:app, :actor).find_each do |deploy|
      deploy.record_outcome(at: deploy.finished_at || deploy.updated_at)
    end
  end

  def down
    Event.where("action LIKE 'app.%.%'").delete_all
  end
end
