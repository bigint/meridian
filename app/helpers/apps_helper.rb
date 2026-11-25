module AppsHelper
  # One line that answers "is it running what Git says?"
  def app_status(app, cells)
    return tag.span("Not assigned to any server yet.", class: "muted") if cells.empty?
    return tag.span("No version file yet, so Meridian can't compare versions.", class: "state unknown") unless app.versioned?

    release = app.latest_release&.version
    running = cells.count { it.versions.include?(release) }
    quiet = cells.count { it.state == "stale" }

    status = if running == cells.size
      tag.span("✓ Running #{release} everywhere", class: "state in_sync")
    else
      tag.span("#{running} of #{pluralize(cells.size, "server")} run #{release}", class: "state drifted")
    end
    quiet.zero? ? status : safe_join([ status, tag.span(" · #{pluralize(quiet, "agent")} quiet, last report may be old", class: "meta") ])
  end
end
