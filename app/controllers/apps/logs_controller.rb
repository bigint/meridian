# An app's logs, merged across every server it runs on.
class Apps::LogsController < ApplicationController
  MAX_PLACEMENTS = LogsChannel::MAX_PLACEMENTS

  require_deployer

  def show
    @app = App.find(params[:app_id])
    @placements = @app.placements.includes(:server).running_first.limit(MAX_PLACEMENTS).to_a
    Event.record("logs.viewed", subject: @app,
      summary: "Viewed the logs of #{@app.name} (#{helpers.pluralize(@placements.size, "container")} on #{helpers.pluralize(@placements.map(&:server_id).uniq.size, "server")})")
  end
end
