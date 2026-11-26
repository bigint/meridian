# The agent's end of the line. It receives watch and tail leases and sends
# stats frames and log batches, which are relayed to the browsers reading them.
# Snapshots stay the only writer: a server the agent has not created with
# a first snapshot is not found here, and the subscription is rejected.
class AgentChannel < ApplicationCable::Channel
  MIN_FRAME_GAP = 0.5
  # An agent sends a batch per container at most every 250 ms and tails at
  # most 20 containers: 80 a second at full tilt. Past this, it is misbehaving.
  MAX_LOG_FRAMES_PER_SECOND = 100
  RECHECK_TOKEN_EVERY = 60.seconds

  def subscribed
    @server = find_server or return reject
    stream_for @server

    remaining = LiveStats.lease_remaining(@server)
    transmit({ type: "watch", seconds: remaining }) if remaining.positive?
    LiveLogs.open_tails(@server).each { transmit it }
  end

  def stats(data)
    now = Time.current.to_f
    return if @last_relayed_at && now - @last_relayed_at < MIN_FRAME_GAP

    if frame = LiveStats.parse(data)
      @last_relayed_at = now
      ServerStatsChannel.broadcast_to(@server, frame)
    end
  end

  # A log batch, or the agent saying it won't tail a container. Only
  # containers placed on this agent's server are relayed, and nothing is stored.
  def logs(data)
    return unless within_log_budget?

    batch = LiveLogs.parse(data) or return
    placement = @server.placements.find_by(container_id: batch["container"]) or return
    LogsChannel.broadcast_to(placement, batch.merge("source" => placement.id))
  end

  periodically every: RECHECK_TOKEN_EVERY do
    connection.close(reason: "unauthorized", reconnect: false) unless AgentToken.active.exists?(connection.agent_token.id)
  end

  private
    # A chatty or broken agent can't flood the cable: past this, frames are dropped.
    def within_log_budget?
      now = Time.current.to_f
      @log_frames ||= []
      @log_frames.shift while @log_frames.first && @log_frames.first <= now - 1
      @log_frames.push(now) if @log_frames.size < MAX_LOG_FRAMES_PER_SECOND
    end

    def find_server
      token, machine_id = connection.agent_token, params[:machine_id].to_s.strip.first(128).presence
      return unless token && machine_id

      server = token.server || Server.find_by(machine_id: machine_id)
      server if server&.machine_id == machine_id
    end
end
