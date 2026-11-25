# Compares what Git says with what agents report. Computed, never stored.
module Drift
  STATES = %w[ in_sync drifted missing stray stale unknown ].freeze

  SYMBOLS = { "in_sync" => "✓", "drifted" => "≠", "missing" => "✕", "stray" => "?", "stale" => "…", "unknown" => "–" }.freeze
  LABELS = { "in_sync" => "In sync", "drifted" => "Drifted", "missing" => "Missing", "stray" => "Stray", "stale" => "Stale", "unknown" => "Unknown" }.freeze
  MEANINGS = {
    "in_sync" => "Running exactly the version Git says.",
    "drifted" => "Running, but not the version Git says. A deploy may be rolling out, or stopped part-way.",
    "missing" => "Git says it should run here, but nothing is running.",
    "stray" => "Running here, but Git doesn't put it here.",
    "stale" => "The server's agent has gone quiet, so Meridian can't tell what runs there right now.",
    "unknown" => "Nothing to compare yet: no agent on the server, or no version file for the app."
  }.freeze

  # assigned: does Git place the app here?
  # versions: versions of the app's running containers on the server
  # release:  the newest release version, or nil if not comparable
  # server:   the server, for agent freshness
  def self.state(assigned:, versions:, release:, server:)
    if !server.reporting? then assigned ? "unknown" : nil
    elsif server.stale? then "stale"
    elsif !assigned then versions.any? ? "stray" : nil
    elsif versions.empty? then "missing"
    elsif release.nil? then "unknown"
    elsif versions.all?(release) then "in_sync"
    else "drifted"
    end
  end

  # The state that needs attention first, when several roles share a cell.
  def self.worst(states)
    states.compact.min_by { %w[ missing drifted stale stray unknown in_sync ].index(it) }
  end
end
