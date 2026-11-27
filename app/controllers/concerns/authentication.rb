module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    # An expired session is as good as none. A used one moves its cookie's
    # expiry on with it.
    def find_session_by_cookie
      Session.resume(cookies.signed[:session_id])&.tap { set_session_cookie(it) if it.touched? }
    end

    # Only a whole page is worth coming back to: a form's POST has no page at
    # its URL, and a turbo-frame GET is a bare frame.
    def request_authentication
      session[:return_to_after_authenticating] = request.url if request.get? && !request.headers["Turbo-Frame"]
      redirect_to main_app.new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || main_app.root_url
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        set_session_cookie(session)
      end
    end

    def set_session_cookie(session)
      cookies.signed[:session_id] = { value: session.id, expires: session.expires_at, httponly: true, same_site: :lax }
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
