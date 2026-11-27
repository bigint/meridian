class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  validates :password, length: { minimum: 12 }, allow_nil: true
  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  # Creating the user needs this code, which only someone who can read
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

  # Hangs up every cable this user has open.
  def disconnect
    ActionCable.server.remote_connections.where(current_user: self, agent_token: nil).disconnect
  end
end
