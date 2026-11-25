class User < ApplicationRecord
  include Role

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :identities, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  validates :password, length: { minimum: 12 }, allow_nil: true
  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  def display_name
    name.presence || email_address
  end
end
