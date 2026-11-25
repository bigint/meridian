# What one agent saw on one server at one moment. Validated in the request,
# ingested in a job: the server row is found or claimed, its placements are
# upserted and the gone ones deleted, all in one transaction.
class Snapshot
  include ActiveModel::Validations

  MAX_CONTAINERS = 2_000
  STATES = %w[ created running paused restarting removing exited dead ].freeze
  KINDS = %w[ app accessory proxy ].freeze

  class Rejected < StandardError; end

  attr_reader :payload, :token

  validates :machine_id, :hostname, presence: true
  validate :containers_shape

  def initialize(payload, token:)
    @payload = payload.to_h.deep_stringify_keys
    @token = token
  end

  def machine_id = payload["machine_id"].to_s.strip.first(128).presence
  def hostname = payload["hostname"].to_s.strip.first(255).presence
  def agent_version = payload["agent_version"].to_s.first(64)
  def truncated? = payload["truncated"] == true

  def labels
    Hash(payload["labels"]).to_h { |key, value| [ key.to_s.first(64), value.to_s.first(128) ] }.first(32).to_h
  end

  # MERIDIAN_LABELS=lat=1.35,lng=103.82 (or latitude/longitude/lon).
  def location
    lat = Float(labels["lat"] || labels["latitude"], exception: false)
    lng = Float(labels["lng"] || labels["lon"] || labels["longitude"], exception: false)
    lat && lng && lat.between?(-90, 90) && lng.between?(-180, 180) ? { latitude: lat, longitude: lng } : {}
  end

  def containers
    Array(payload["containers"]).grep(Hash).first(MAX_CONTAINERS)
  end

  # Only what Meridian needs survives into the job: never env, commands or mounts.
  def to_job
    payload.slice("machine_id", "hostname", "agent_version", "labels", "truncated")
      .merge("containers" => containers.map { it.slice(*%w[ id name image service role destination version kind state health started_at ]) })
  end

  def ingest
    Server.transaction do
      server = claim_server
      server.update!(machine_id: machine_id, labels: labels, agent_version: agent_version, last_seen_at: Time.current, **location)
      record_placements(server)
      server
    end
  end

  private
    def containers_shape
      errors.add(:containers, "must be a list") unless payload["containers"].is_a?(Array)
      errors.add(:containers, "has more than #{MAX_CONTAINERS}") if Array(payload["containers"]).size > MAX_CONTAINERS
    end

    def claim_server
      server = token.server || Server.find_by(machine_id: machine_id) || unclaimed_server || Server.create!(name: hostname, hostname: hostname)

      if server.machine_id.present? && server.machine_id != machine_id
        raise Rejected, "This token belongs to another server"
      end

      token.update!(server: server) unless token.fleet? || token.server
      server
    end

    # Git knows servers by the host Kamal SSHes to; the agent knows its own
    # hostname. Match exactly, or by the first DNS label when that is unique.
    def unclaimed_server
      candidates = Server.where(machine_id: nil)
      candidates.find_by(hostname: hostname) || candidates.find_by(name: hostname) || begin
        short = hostname.split(".").first
        matches = candidates.select { [ it.hostname, it.name ].any? { |name| name.split(".").first == short } }
        matches.sole if matches.one?
      end
    end

    def record_placements(server)
      now = Time.current
      rows = containers.filter_map { placement_row(server, it, now) }.uniq { it[:container_id] }

      Placement.upsert_all(rows, unique_by: %i[ server_id container_id ]) if rows.any?
      server.placements.where.not(container_id: rows.map { it[:container_id] }).delete_all unless truncated?
    end

    def placement_row(server, container, now)
      id = container["id"].to_s.first(64).presence or return
      kind = KINDS.include?(container["kind"]) ? container["kind"] : "app"
      service, destination = container["service"].to_s.first(128), container["destination"].to_s.first(64)

      {
        server_id: server.id, container_id: id, name: container["name"].to_s.first(255), kind: kind,
        app_id: (app_for(server, service, destination) if kind == "app"),
        service: service.presence, role: container["role"].to_s.first(64).presence, destination: destination,
        image: container["image"].to_s.first(255), version: container["version"].to_s.first(128).presence,
        state: (container["state"] if STATES.include?(container["state"])), health: container["health"].to_s.first(16).presence,
        started_at: (Time.iso8601(container["started_at"]) rescue nil), observed_at: now
      }
    end

    def app_for(server, service, destination)
      @apps ||= Hash.new do |cache, key|
        candidates = App.where(service: key.first, destination: key.last).to_a
        cache[key] = candidates.find { |app| app.assignments.exists?(server_id: server.id) } || candidates.first
      end
      @apps[[ service, destination ]]&.id
    end
end
