class MapsController < ApplicationController
  def show
    @map = WorldMap.new(params.permit(:project, :app, :service, *Board::LABELS))
    @projects = Project.order(:name)
    @selected = @map.site(params[:place]) || @map.default_site
  end
end
