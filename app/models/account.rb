# The single row of install-wide settings.
class Account < ApplicationRecord
  validates :name, presence: true
  validates :preview_ttl_days, numericality: { greater_than: 0 }

  def self.current
    first_or_create!
  end
end
