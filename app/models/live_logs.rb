# Container logs are never stored. A browser reading a container's logs
# holds a short tail lease with that server's agent (LogsChannel renews it),
# and the agent streams batches into AgentChannel only while a lease runs.
module LiveLogs
  CONTAINER_ID = LiveStats::CONTAINER_ID
  # The most containers one page reads at once, merged.
  MAX_PLACEMENTS = 20
  MAX_LINES = 1000
  MAX_TIME = 40
  MAX_MESSAGE = 8192 + 1 # the agent cuts at 8192 bytes and adds an ellipsis
  MAX_REASON = 80
  STREAMS = %w[ out err ].freeze

  BACKLOG = 200
  LEASE = 30.seconds
  RENEW_EVERY = 5.seconds

  module_function

  # The boundary: whatever an agent sent in, only the contract's keys come
  # out. Returns nil for anything that is not about a container or says
  # nothing (an empty batch). Lines that break the contract are dropped one
  # by one; the agent's "action" is dropped too. "off" and "refused" are
  # the agent's answers to a tail it won't serve.
  def parse(data)
    return unless data.is_a?(Hash) && data["container"].is_a?(String) && data["container"].match?(CONTAINER_ID)

    batch = { "container" => data["container"] }
    lines = Array(data["lines"]).first(MAX_LINES).filter_map { line(it) }
    batch["lines"] = lines if lines.any?
    batch["backlog"] = true if data["backlog"] == true
    batch["dropped"] = data["dropped"] if data["dropped"].is_a?(Integer) && data["dropped"].positive?
    batch["ended"] = true if data["ended"] == true
    batch["off"] = true if data["off"] == true
    batch["refused"] = data["refused"] if data["refused"].is_a?(String) && data["refused"].present? && data["refused"].length <= MAX_REASON

    batch if (batch.keys - %w[ container backlog ]).any?
  end

  # Someone is reading this container's logs. Tells its server's agent to
  # follow it for LEASE seconds. A new reader (backlog) always gets through;
  # renewals go out at most once per RENEW_EVERY however many people read.
  def tail(placement, backlog:)
    key = [ "live-tail", placement.id ]
    if backlog.positive?
      Rails.cache.write(key, true, expires_in: RENEW_EVERY)
    else
      return unless Rails.cache.write(key, true, unless_exist: true, expires_in: RENEW_EVERY)
    end

    Rails.cache.write(lease_key(placement.id), LEASE.from_now.to_f, expires_in: LEASE)
    AgentChannel.broadcast_to(placement.server, { type: "tail", container: placement.container_id, seconds: LEASE.to_i, backlog: backlog })
  end

  # For an agent that just (re)connected: a tail, with history, for each of
  # its server's containers someone is still reading. A tail sent while the
  # agent was away was lost, and renewals ask only for new lines. Browsers
  # skip lines they already hold, so a repeated history is harmless.
  def open_tails(server)
    containers = server.placements.pluck(:id, :container_id).to_h
    leases = Rails.cache.read_multi(*containers.keys.map { lease_key(it) })
    containers.filter_map do |id, container|
      remaining = leases[lease_key(id)].to_f - Time.current.to_f
      { type: "tail", container: container, seconds: remaining.ceil, backlog: BACKLOG } if remaining.positive?
    end
  end

  def lease_key(placement_id) = [ "live-tail-lease", placement_id ]
  private_class_method :lease_key

  def line(raw)
    return unless raw.is_a?(Hash) && STREAMS.include?(raw["s"])
    return unless raw["t"].is_a?(String) && raw["t"].length <= MAX_TIME
    return unless raw["m"].is_a?(String) && raw["m"].length <= MAX_MESSAGE

    raw.slice("t", "s", "m")
  end
  private_class_method :line
end
