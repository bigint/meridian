# A data table. Columns are declared once and rendered for every row:
#
#   render Ui::TableComponent.new(rows: servers) do |table|
#     table.with_column("Server", header: true) { |server| link_to server.name, server }
#     table.with_column("Agent", mono: true) { |server| server.agent_version }
#   end
class Ui::TableComponent < ApplicationComponent
  class Column < ApplicationComponent
    attr_reader :label, :align, :mono, :header, :nowrap

    def initialize(label, align: :left, mono: false, header: false, nowrap: false, cell: nil)
      @label, @align, @mono, @header, @nowrap, @cell = label, align, mono, header, nowrap, cell
    end

    def value(row) = @cell&.call(row)
    def call = ""
  end

  renders_many :columns, ->(label, **options, &cell) { Column.new(label, cell: cell, **options) }

  def initialize(rows:, empty: "Nothing here yet.", **html)
    @rows, @empty, @html = rows, empty, html
  end

  private
    def cell_class(column)
      classes("px-3 py-2 align-middle", ("text-right" if column.align == :right), ("font-mono text-xs" if column.mono), ("whitespace-nowrap" if column.nowrap))
    end
end
