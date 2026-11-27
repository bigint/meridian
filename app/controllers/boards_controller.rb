class BoardsController < ApplicationController
  def show
    @board = Board.new(filter_params)
    @projects = Project.order(:name)
  end

  private
    def filter_params
      params.permit(:project, :app, :state, :group, :view, :page, *Board::LABELS)
    end
end
