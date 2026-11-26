# One group of the board: apps × servers (or servers × apps), every cell a
# drift state and the version running there.
class BoardGridComponent < ApplicationComponent
  def initialize(board:, group:)
    @board, @group = board, group
  end

  private
    def title
      @board.group_by ? "#{@board.group_by.capitalize}: #{@group.name || "unlabelled"}" : "All servers"
    end

    def counts
      rows, columns = @board.view == "apps" ? %w[ app server ] : %w[ server app ]
      "#{helpers.pluralize(@group.rows.size, rows)} × #{helpers.pluralize(@group.columns.size, columns)}"
    end

    def column_name(column) = column.try(:short_name) || column.name
end
