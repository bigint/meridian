class Session < ApplicationRecord
  # Unused this long, a session is over: a cookie left on a borrowed laptop
  # or copied off a disk stops working. Used, it still ends at MAX_AGE.
  IDLE_TIMEOUT = 14.days
  MAX_AGE = 90.days
  # A request moves updated_at at most this often, not on every page.
  TOUCH_EVERY = 1.hour

  belongs_to :user

  scope :active, -> { where(updated_at: IDLE_TIMEOUT.ago..).where(created_at: MAX_AGE.ago..) }
  scope :expired, -> { where(updated_at: ...IDLE_TIMEOUT.ago).or(where(created_at: ...MAX_AGE.ago)) }

  # Signed out, signed out everywhere by a new password, or removed: the
  # user's open cables go too. A cable doesn't know its session, so the
  # user's other sessions reconnect, and only those still valid get back in.
  after_destroy_commit { user.disconnect }

  # The session a cookie names, if it is still active. Returns it with
  # touched? set when this use moved it on, so the cookie can be renewed.
  def self.resume(id)
    active.find_by(id: id)&.tap(&:keep_alive) if id
  end

  def keep_alive
    @touched = updated_at < TOUCH_EVERY.ago && touch
  end

  def touched? = !!@touched

  # When the cookie should lapse: when the session would, unused.
  def expires_at
    [ updated_at + IDLE_TIMEOUT, created_at + MAX_AGE ].min
  end
end
