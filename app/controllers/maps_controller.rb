class MapsController < ApplicationController
  def show
    @map = WorldMap.new(params.permit(:project, :app, *Board::LABELS))
    @projects = Project.order(:name)
  end
end
