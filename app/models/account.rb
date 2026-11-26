# The single row of install-wide settings.
class Account < ApplicationRecord
  enum :preview_hostnames, { nested: "nested", flat: "flat" }, prefix: true, validate: true

  validates :name, presence: true
  validates :preview_ttl_days, numericality: { greater_than: 0 }
  validates :latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :longitude, numericality: { in: -180..180 }, allow_nil: true

  def located?
    latitude && longitude
  end

  # Flat names sit one level below the domain, so one wildcard record and
  # Cloudflare's free certificate cover every app.
  def preview_hostname(service, number)
    preview_hostnames_flat? ? "pr-#{number}-#{service}.#{preview_domain}" : "pr-#{number}.#{service}.#{preview_domain}"
  end

  def self.current
    first_or_create!
  end
end
