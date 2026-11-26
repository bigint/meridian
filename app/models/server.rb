class Server < ApplicationRecord
  include Locatable

  DEFAULT_INTERVAL = 15.seconds
  # Silent for three of its agent's intervals, and never less than this.
  STALE_AFTER = DEFAULT_INTERVAL * 3
  # Silent this long, a server Git places can be claimed by a new machine id.
  RECLAIM_AFTER = 10.minutes
  # A host Meridian may write into a Kamal config: a DNS name or an IP. No
  # spaces, quotes, newlines or "<%", so it can't add YAML keys or ERB, which
  # Kamal evaluates whenever it reads the config.
  HOST_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,252}\z/
  # Labels that say where a server is, shown in a column of their own.
  PLACE_LABELS = %w[ city region lat lng ].freeze

  has_many :assignments, dependent: :delete_all
  has_many :apps, -> { distinct }, through: :assignments
  has_many :projects, -> { distinct }, through: :apps
  has_many :placements, dependent: :delete_all
  has_many :agent_tokens, dependent: :nullify

  validates :name, :hostname, presence: true

  scope :ordered, -> { order(:name) }
  scope :search, ->(query) { where("name LIKE :q ESCAPE '\\' OR hostname LIKE :q ESCAPE '\\'", q: "%#{sanitize_sql_like(query.to_s)}%") }
  scope :silent, -> {
    where(last_seen_at: ...STALE_AFTER.ago)
      .where("julianday(last_seen_at) < julianday(:now) - MAX(:floor, 3 * COALESCE(interval_seconds, :default)) / 86400.0",
        now: Time.current, floor: STALE_AFTER.to_i, default: DEFAULT_INTERVAL.to_i)
  }

  # The servers with every one of these labels, such as { "role" => "web" }.
  def self.labelled(labels) = ordered.select { |server| labels.all? { |key, value| server.label(key) == value } }

  # Git names servers by the host Kamal SSHes to. Agents report the machine's
  # own hostname. Either finds the same row.
  def self.for_host(host)
    find_by(hostname: host) || find_by(name: host) || reported_as(host) || create!(name: host, hostname: host)
  end

  # An agent that reported before Git listed its host made its own row,
  # named by the machine's hostname. When exactly one such row shares the
  # host's first DNS label, Git's name takes it over, as a claim would have.
  # A row already named by another of Git's hosts is that host's, even before
  # a sync writes its assignment (web-1.sgp and web-1.fra in one config).
  def self.reported_as(host)
    return if ip?(host)

    short = host.split(".").first
    matches = where.not(machine_id: nil).where.missing(:assignments).select { [ it.hostname, it.name ].any? { |name| !ip?(name) && name.split(".").first == short } }
    matches -= matches.select { git_hosts.include?(it.name) } if matches.any?
    matches.sole.tap { it.update!(name: host, hostname: host) } if matches.one?
  end

  # Every host a config lists, for its roles or its accessories.
  def self.git_hosts
    App.pluck(:roles, :accessories).flatten.filter_map { it["hosts"] if it.is_a?(Hash) }.flatten.to_set
  end

  def self.ip?(host)
    host.to_s.match?(/\A[\d.:]+\z/)
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

  # Silent past RECLAIM_AFTER, and stale too: an agent that reports every
  # 15 minutes is alive between its snapshots, not rebuilt.
  def reclaimable?
    reporting? && last_seen_at < [ RECLAIM_AFTER, stale_after ].max.ago
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
