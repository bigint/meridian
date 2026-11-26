# Live stats are never stored. An agent streams a frame a second into
# AgentChannel, and only while some browser watches: ServerStatsChannel
# renews a short lease, and the agent stops when the lease runs out.
module LiveStats
  HOST_KEYS = %w[ cpu_cores cores memory_used memory_total load1 disk_used disk_total ].freeze
  CONTAINER_KEYS = %w[ cpu_cores memory_used memory_limit net_rx net_tx disk_read disk_write ].freeze
  CONTAINER_ID = /\A[0-9a-f]{12,64}\z/
  MAX_CONTAINERS = 500

  LEASE = 30.seconds
  RENEW_EVERY = 5.seconds

  module_function

  # The boundary: whatever an agent sent in, only the contract's keys come
  # out, as finite non-negative numbers. Returns nil for anything that is not
  # a frame. The agent's "action" is dropped; browsers get host and containers.
  def parse(data)
    return unless data.is_a?(Hash)

    frame = { "containers" => Array(data["containers"]).first(MAX_CONTAINERS).filter_map { container(it) } }
    host = numbers(data["host"], HOST_KEYS)
    frame["host"] = host if host.any?
    frame
  end

  # Someone is watching this server. Tells its agent to stream for LEASE
  # seconds, at most once per RENEW_EVERY however many people watch.
  def watch(server)
    return unless Rails.cache.write([ "live-renew", server.id ], true, unless_exist: true, expires_in: RENEW_EVERY)

    Rails.cache.write([ "live-lease", server.id ], LEASE.from_now.to_f, expires_in: LEASE)
    AgentChannel.broadcast_to(server, { type: "watch", seconds: LEASE.to_i })
  end

  # Whole seconds left on the lease, for an agent that just subscribed. 0 when nobody watches.
  def lease_remaining(server)
    lease_ends = Rails.cache.read([ "live-lease", server.id ])
    lease_ends ? [ (lease_ends - Time.current.to_f).ceil, 0 ].max : 0
  end

  def container(raw)
    return unless raw.is_a?(Hash) && raw["id"].is_a?(String) && raw["id"].match?(CONTAINER_ID)
    { "id" => raw["id"] }.merge(numbers(raw, CONTAINER_KEYS))
  end
  private_class_method :container

  def numbers(raw, keys)
    return {} unless raw.is_a?(Hash)
    raw.slice(*keys).select { |_, value| value.is_a?(Numeric) && value.finite? && value >= 0 }
  end
  private_class_method :numbers
end
