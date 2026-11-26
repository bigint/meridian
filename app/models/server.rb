class Server < ApplicationRecord
  DEFAULT_INTERVAL = 15.seconds
  STALE_AFTER = DEFAULT_INTERVAL * 3
  # A host Meridian may write into a Kamal config: a DNS name or an IP. No
  # spaces, quotes, newlines or "<%", so it can't add YAML keys or ERB, which
  # Kamal evaluates whenever it reads the config.
  HOST_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,252}\z/

  has_many :assignments, dependent: :delete_all
  has_many :apps, -> { distinct }, through: :assignments
  has_many :projects, -> { distinct }, through: :apps
  has_many :placements, dependent: :delete_all
  has_many :agent_tokens, dependent: :nullify

  validates :name, :hostname, presence: true
  validates :latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :longitude, numericality: { in: -180..180 }, allow_nil: true

  scope :ordered, -> { order(:name) }
  scope :silent, -> { where(last_seen_at: ...STALE_AFTER.ago) }

  # Git names servers by the host Kamal SSHes to. Agents report the machine's
  # own hostname. Either finds the same row.
  def self.for_host(host)
    find_by(hostname: host) || find_by(name: host) || create!(name: host, hostname: host)
  end

  def located?
    latitude && longitude
  end

  def reporting?
    last_seen_at.present?
  end

  def stale?
    reporting? && last_seen_at < STALE_AFTER.ago
  end

  # "web-1.example.com" => "web-1"; IPs stay whole.
  def short_name
    name.match?(/\A[\d.:]+\z/) ? name : name.split(".").first
  end

  def label(key)
    labels[key.to_s]
  end

  def to_param
    [ id, name ].join("-").parameterize
  end
end
