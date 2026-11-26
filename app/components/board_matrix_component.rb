# The board as one table. Apps × servers puts each region's servers under a
# shared heading; servers × apps groups the rows by region instead. Every
# cell is the version running there, tinted by its drift state.
class BoardMatrixComponent < ApplicationComponent
  def initialize(board:, selected: nil, inspect_url: nil)
    @board, @selected, @inspect_url = board, selected, inspect_url
  end

  private
    def apps_view? = @board.view == "apps"
    def groups = @board.groups
    def grouped? = @board.group_by.present?
    def group_title(group) = group.name || (grouped? ? "No #{@board.group_by}" : "All servers")

    # Servers × apps: every app that appears in any group, once.
    def all_apps = groups.flat_map(&:columns).uniq.sort_by(&:name)

    def cell(group, app, server) = group.cells[[ app.id, server.id ]]

    def release(app)
      groups.each { |group| group.cells.each_value { |c| return c.release if c.app == app } }
      nil
    end

    # Under a region heading the region part of a name is noise:
    # "aps2-az1-node-01" reads as "az1-01".
    def server_label(server)
      name = server.try(:short_name) || server.name
      parts = name.split("-")
      grouped? && parts.size > 2 ? (parts.drop(1) - [ "node" ]).join("-") : name
    end

    def row_link(app)
      url = @inspect_url ? @inspect_url.call(app) : helpers.app_path(app)
      link_to app.name, url, class: "block truncate font-medium text-ink hover:text-accent",
        data: (@inspect_url ? { turbo_frame: "inspector", turbo_action: "advance" } : {})
    end

    def selected?(app) = app.id == @selected

    def row_class(app) = selected?(app) ? "bg-accent-soft" : "group/row hover:bg-surface"

    def sticky_class(app)
      classes("sticky left-0 z-10 max-w-56 border-t border-line px-3 py-1.5 text-left font-normal",
        selected?(app) ? "bg-accent-soft" : "bg-canvas group-hover/row:bg-surface")
    end
end
