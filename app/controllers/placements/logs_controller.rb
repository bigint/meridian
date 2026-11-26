# One container's logs.
class Placements::LogsController < ApplicationController
  def show
    @placement = Placement.includes(:server).find(params[:placement_id])
    Event.record("logs.viewed", subject: @placement.server, container: @placement.name,
      summary: "Viewed the logs of #{@placement.name} on #{@placement.server.name}")
  end
end
