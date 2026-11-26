# The single row of install-wide settings.
class Account < ApplicationRecord
  include Locatable

  validates :name, presence: true

  def self.current
    first_or_create!
  end
end
