# One container's logs.
class Placements::LogsController < ApplicationController
  def show
    @placement = Placement.includes(:server).find(params[:placement_id])
  end
end
