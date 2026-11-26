class BoardsController < ApplicationController
  def show
    @board = Board.new(filter_params)
    @projects = Project.order(:name)
    @inspected = inspected_app
  end

  private
    def filter_params
      params.permit(:project, :app, :state, :group, :view, :page, *Board::LABELS)
    end

    # The app in the side panel: the one asked for, else the first that needs
    # attention, else the first in the grid.
    def inspected_app
      return App.includes(:project).find_by(id: params[:inspect]) if params[:inspect].present?
      (@board.attention.find(&:app)&.app || @board.page_rows.first) if @board.view == "apps"
    end
end
