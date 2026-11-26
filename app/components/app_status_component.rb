# One line that answers "is this app running what Git says?"
class AppStatusComponent < ApplicationComponent
  def initialize(app:, cells:)
    @app, @cells = app, cells
  end

  def call
    return tag.span("Not assigned to any server yet.", class: "text-ink-muted") if @cells.empty?
    return render(Ui::BadgeComponent.new("No version file yet, so Meridian can't compare versions.")) unless @app.versioned?

    release = @app.latest_release&.version
    running = @cells.count { it.versions.include?(release) }
    quiet = @cells.count { it.state == "stale" }

    status = if running == @cells.size
      render Ui::BadgeComponent.new("✓ Running #{release} everywhere", tone: :ok)
    else
      render Ui::BadgeComponent.new("#{running} of #{helpers.pluralize(@cells.size, "server")} run #{release}", tone: :warn)
    end
    quiet.zero? ? status : status + tag.span(" · #{helpers.pluralize(quiet, "agent")} quiet, last report may be old", class: "text-xs text-ink-muted")
  end
end
