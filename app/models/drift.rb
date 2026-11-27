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
    "stale" => "The server's agent stopped reporting, so its last report may be out of date.",
    "unknown" => "Nothing to compare yet: no agent on the server, or no version file for the app."
  }.freeze

  # assigned: does Git place the app here?
  # versions: versions of the app's running containers on the server
  # release:  the newest release version, or nil if not comparable
  # server:   the server, for agent freshness
  def self.state(assigned:, versions:, release:, server:)
    if !server.reporting? then assigned ? "unknown" : nil
    elsif server.stale? then "stale"
    elsif !assigned then versions.empty? ? nil : "stray"
    elsif versions.empty? then "missing"
    elsif release.nil? then "unknown"
    elsif versions.all?(release) then "in_sync"
    else "drifted"
    end
  end

  # States that need a person, most urgent first. The board, the map and
  # worst all rank by this one list.
  ATTENTION = %w[ missing drifted stray stale ].freeze
  ATTENTION_RANK = ATTENTION.each_with_index.to_h.freeze
  SEVERITY = (ATTENTION + %w[ unknown in_sync ]).freeze

  # The state that needs attention first, when several cells share a place.
  def self.worst(states)
    states.compact.min_by { SEVERITY.index(it) }
  end
end
