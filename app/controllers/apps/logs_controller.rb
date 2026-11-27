# An app's logs, merged across every server it runs on.
class Apps::LogsController < ApplicationController
  include AppScoped

  def show
    @placements = @app.placements.current.includes(:server).running_first.limit(LogsChannel::MAX_PLACEMENTS).to_a
  end
end
