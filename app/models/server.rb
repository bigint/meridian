class Server < ApplicationRecord
  DEFAULT_INTERVAL = 15.seconds
  # Silent for three of its agent's intervals, and never less than this.
  STALE_AFTER = DEFAULT_INTERVAL * 3
  # Silent this long, a server Git places can be claimed by a new machine id.
  RECLAIM_AFTER = 10.minutes
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
  scope :silent, -> {
    where(last_seen_at: ...STALE_AFTER.ago)
      .where("julianday(last_seen_at) < julianday(:now) - MAX(:floor, 3 * COALESCE(interval_seconds, :default)) / 86400.0",
        now: Time.current, floor: STALE_AFTER.to_i, default: DEFAULT_INTERVAL.to_i)
  }

  # Git names servers by the host Kamal SSHes to. Agents report the machine's
  # own hostname. Either finds the same row.
  def self.for_host(host)
    find_by(hostname: host) || find_by(name: host) || reported_as(host) || create!(name: host, hostname: host)
  end

  # An agent that reported before Git listed its host made its own row,
  # named by the machine's hostname. When exactly one such row shares the
  # host's first DNS label, Git's name takes it over, as a claim would have.
  def self.reported_as(host)
    return if ip?(host)

    short = host.split(".").first
    matches = where.not(machine_id: nil).where.missing(:assignments).select { [ it.hostname, it.name ].any? { |name| !ip?(name) && name.split(".").first == short } }
    matches.sole.tap { it.update!(name: host, hostname: host) } if matches.one?
  end

  def self.ip?(host)
    host.to_s.match?(/\A[\d.:]+\z/)
  end

  def located?
    latitude && longitude
  end

  def reporting?
    last_seen_at.present?
  end

  def stale?
    reporting? && last_seen_at < stale_after.ago
  end

  def stale_after
    [ (interval_seconds || DEFAULT_INTERVAL.to_i).seconds * 3, STALE_AFTER ].max
  end

  # "web-1.example.com" => "web-1"; IPs stay whole.
  def short_name
    self.class.ip?(name) ? name : name.split(".").first
  end

  def label(key)
    labels[key.to_s]
  end

  def to_param
    [ id, name ].join("-").parameterize
  end
end
