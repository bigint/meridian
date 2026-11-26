class User < ApplicationRecord
  include Role

  has_secure_password
  has_many :sessions, dependent: :destroy
  # What they did stays on record when they are removed, by nobody in particular.
  has_many :deploys, foreign_key: :actor_id, inverse_of: :actor, dependent: :nullify
  has_many :events, foreign_key: :actor_id, inverse_of: :actor, dependent: :nullify
  has_many :secret_names_set, class_name: "SecretName", foreign_key: :last_set_by_id, inverse_of: :last_set_by, dependent: :nullify

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  validates :password, length: { minimum: 12 }, allow_nil: true
  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  # A cable opened before a role change keeps that role's streams until it
  # reconnects, so a new role hangs up every open cable. Signing out does the
  # same through Session.
  after_update_commit :disconnect, if: :saved_change_to_role?

  # Creating the first admin needs this code, which only someone who can read
  # the server's log or run a command on it can get. Derived from
  # SECRET_KEY_BASE, so it needs no storage and no setting.
  def self.setup_code
    Rails.application.key_generator.generate_key("meridian first run", 10).unpack1("H*")
  end

  def display_name
    name.presence || email_address
  end

  # Ends every commit Meridian makes for this person.
  def commit_trailer = "Meridian-Actor: #{display_name} <#{email_address}>"

  # Hangs up every cable this user has open; each reconnects, or doesn't, as
  # who they are now allows.
  def disconnect
    ActionCable.server.remote_connections.where(current_user: self, agent_token: nil).disconnect
  end
end
