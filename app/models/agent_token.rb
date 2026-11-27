# A bearer token for agents. Only its SHA-256 digest is stored; the token is
# shown once, when it is created.
class AgentToken < ApplicationRecord
  PREFIX = "meridian_"
  # Every snapshot authenticates, so last_used_at moves at most this often.
  TOUCH_EVERY = 1.minute

  belongs_to :server, optional: true

  validates :label, presence: true

  scope :active, -> { where(revoked_at: nil) }
  scope :ordered, -> { order(revoked_at: :desc, created_at: :desc) }

  attr_reader :token

  before_validation :generate, on: :create

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  def self.authenticate(token)
    return if token.blank?
    active.find_by(digest: digest(token))&.tap { it.touch(:last_used_at) if it.last_used_at.nil? || it.last_used_at < TOUCH_EVERY.ago }
  end

  # Agents on an open cable are hung up now, not at the next recheck.
  def revoke
    update!(revoked_at: Time.current)
    AgentChannel.disconnect(self)
  end

  def revoked?
    revoked_at.present?
  end

  private
    def generate
      @token = PREFIX + SecureRandom.base58(40)
      self.digest = self.class.digest(@token)
    end
end
