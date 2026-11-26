# The agent's end of the line. It receives watch leases and sends stats
# frames, which are relayed to the browsers on that server's page.
# Snapshots stay the only writer: a server the agent has not created with
# a first snapshot is not found here, and the subscription is rejected.
class AgentChannel < ApplicationCable::Channel
  MIN_FRAME_GAP = 0.5
  RECHECK_TOKEN_EVERY = 60.seconds

  def subscribed
    @server = find_server or return reject
    stream_for @server

    remaining = LiveStats.lease_remaining(@server)
    transmit({ type: "watch", seconds: remaining }) if remaining.positive?
  end

  def stats(data)
    now = Time.current.to_f
    return if @last_relayed_at && now - @last_relayed_at < MIN_FRAME_GAP

    if frame = LiveStats.parse(data)
      @last_relayed_at = now
      ServerStatsChannel.broadcast_to(@server, frame)
    end
  end

  periodically every: RECHECK_TOKEN_EVERY do
    connection.close(reason: "unauthorized", reconnect: false) unless AgentToken.active.exists?(connection.agent_token.id)
  end

  private
    def find_server
      token, machine_id = connection.agent_token, params[:machine_id].to_s.strip.first(128).presence
      return unless token && machine_id

      server = token.server || Server.find_by(machine_id: machine_id)
      server if server&.machine_id == machine_id
    end
end
