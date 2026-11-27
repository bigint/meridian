# An app's logs, merged across every server it runs on.
class Apps::LogsController < ApplicationController
  MAX_PLACEMENTS = LogsChannel::MAX_PLACEMENTS

  def show
    @app = App.find(params[:app_id])
    @placements = @app.placements.includes(:server).running_first.limit(MAX_PLACEMENTS).to_a
  end
end
