module ApplicationCable
  class Channel < ActionCable::Channel::Base
    private
      # The signed-in user as the database has them now, not as they were when
      # the cable opened: a role taken away or a user removed must end a stream
      # already open, not only the next one.
      def reader
        User.find_by(id: connection.current_user&.id)
      end

      # Hangs up, so the browser reconnects and every channel asks again.
      def hang_up
        connection.close(reason: ActionCable::INTERNAL[:disconnect_reasons][:unauthorized])
      end
  end
end
