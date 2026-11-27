class MapsController < ApplicationController
  def show
    @map = WorldMap.new(params.permit(:project, :app, :service, *Board::LABELS))
    @projects = Project.ordered
  end
end
