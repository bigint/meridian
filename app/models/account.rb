# The single row of install-wide settings.
class Account < ApplicationRecord
  enum :preview_hostnames, { nested: "nested", flat: "flat" }, prefix: true, validate: true

  validates :name, presence: true
  validates :preview_ttl_days, numericality: { greater_than: 0 }
  validates :latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :longitude, numericality: { in: -180..180 }, allow_nil: true
  validate :preview_selector_is_labels

  def located?
    latitude && longitude
  end

  # Flat names sit one level below the domain, so one wildcard record and
  # Cloudflare's free certificate cover every app.
  def preview_hostname(service, number)
    preview_hostnames_flat? ? "pr-#{number}-#{service}.#{preview_domain}" : "pr-#{number}.#{service}.#{preview_domain}"
  end

  # "role=preview, region=sg" => { "role" => "preview", "region" => "sg" }.
  # A term that isn't key=value matches nothing, rather than every server.
  def preview_labels
    preview_selector_terms.select { it.size == 2 && it.none?(&:blank?) }.to_h
  end

  def self.current
    first_or_create!
  end

  private
    def preview_selector_terms
      preview_selector.to_s.split(/[\s,]+/).compact_blank.map { it.split("=", 2) }
    end

    def preview_selector_is_labels
      if preview_selector_terms.any? { it.size < 2 || it.any?(&:blank?) }
        errors.add(:preview_selector, "must be labels like role=preview, separated by commas")
      end
    end
end
