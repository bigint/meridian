# A browser watching a server's page. Subscribing, and every ten seconds
# after, renews the lease that makes the server's agent stream.
class ServerStatsChannel < ApplicationCable::Channel
  RENEW_EVERY = 10.seconds

  periodically every: RENEW_EVERY do
    next hang_up unless reader

    LiveStats.watch(@server)
  end

  private
    def subscribed
      @server = Server.find_by(id: params[:server_id]) if reader
      return reject unless @server

      stream_for @server
      LiveStats.watch(@server)
    end
end
