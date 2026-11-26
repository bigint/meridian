# The board's side panel: one app at a glance, with what you can do to it.
class AppInspectorComponent < ApplicationComponent
  def initialize(app:, user:)
    @app, @user = app, user
  end

  private
    def cells
      @cells ||= begin
        group = Board.new(app_id: @app.id, group: "none").groups.first
        group ? group.columns.map { group.cell(@app, it) }.compact : []
      end
    end

    def releases = @releases ||= @app.releases.limit(3).to_a
    def place(server) = server.label("city") || server.label("region")
    def can_roll_back? = @user.can_deploy? && @app.versioned? && @app.releases.limit(2).count > 1
end
