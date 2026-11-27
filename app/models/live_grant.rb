# A page hands its channel a grant for exactly what it shows, and LogsChannel
# and TrafficChannel stream nothing a page didn't grant. A grant is bound to
# its reader, so it can't be passed on; a reconnect reuses it. It lapses after
# EXPIRES_IN, so one page load isn't a way to read for good: a page still
# open then is turned down when it next reconnects, and asks for a reload,
# which checks access again.
module LiveGrant
  EXPIRES_IN = 12.hours

  module_function

  def grant(user, *subject)
    verifier.generate([ user.id, *subject ], purpose: :live, expires_in: EXPIRES_IN)
  end

  def granted?(grant, user, *subject)
    user.present? && grant.is_a?(String) && verifier.verified(grant, purpose: :live) == [ user.id, *subject ]
  end

  def verifier = Rails.application.message_verifier(:live_grants)
  private_class_method :verifier
end
