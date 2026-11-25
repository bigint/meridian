# The single row of install-wide settings.
class Account < ApplicationRecord
  validates :name, presence: true
  validates :preview_ttl_days, numericality: { greater_than: 0 }
  validates :latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :longitude, numericality: { in: -180..180 }, allow_nil: true

  def located?
    latitude && longitude
  end

  def self.current
    first_or_create!
  end
end
