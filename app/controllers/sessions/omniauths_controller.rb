# Sign in through any OpenID Connect provider (Pocket ID, Authentik, Google...).
class Sessions::OmniauthsController < ApplicationController
  allow_unauthenticated_access
  rate_limit to: 10, within: 3.minutes

  def create
    if user = Identity.sign_in(request.env["omniauth.auth"])
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "Your identity provider didn't share an email address."
    end
  end

  def failure
    redirect_to new_session_path, alert: "Single sign-on failed. Try again."
  end
end
