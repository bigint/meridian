class Session < ApplicationRecord
  belongs_to :user

  # Signed out, signed out everywhere by a new password, or removed: the
  # user's open cables go too. A cable doesn't know its session, so the
  # user's other sessions reconnect, and only those still valid get back in.
  after_destroy_commit { user.disconnect }
end
