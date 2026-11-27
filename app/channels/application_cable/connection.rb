module ApplicationCable
  # Two kinds of client: a signed-in browser (session cookie) and an agent
  # (Bearer token, the one snapshots use). A Bearer header means an agent
  # and nothing else; it never falls back to a cookie.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :agent_token

    def connect
      if request.authorization.present?
        self.agent_token = AgentToken.authenticate(bearer_token) || reject_unauthorized_connection
      else
        self.current_user = user_from_session || reject_unauthorized_connection
      end
    end

    private
      def bearer_token
        request.authorization.to_s[/\ABearer (.+)\z/, 1]
      end

      def user_from_session
        Session.resume(cookies.signed[:session_id])&.user
      end
  end
end
