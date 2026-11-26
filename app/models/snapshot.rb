# What one agent saw on one server at one moment. Validated in the request,
# ingested in a job: the server row is found or claimed, its placements are
# upserted and the gone ones deleted, all in one transaction.
class Snapshot
  include ActiveModel::Validations

  MAX_CONTAINERS = 2_000
  STATES = %w[ created running paused restarting removing exited dead ].freeze
  KINDS = %w[ app accessory proxy ].freeze
  # The placement columns pages show. observed_at moves on every snapshot.
  SHOWN = %i[ container_id name kind app_id service role destination image version state health started_at ].freeze

  class Rejected < StandardError; end

  attr_reader :payload, :token

  validates :machine_id, :hostname, presence: true
  # New app writes a server's hostname into a Kamal config.
  validates :hostname, format: { with: Server::HOST_FORMAT, message: "must be a host name" }, allow_blank: true
  validate :containers_shape, :labels_shape, :token_fits_machine

  def initialize(payload, token:)
    @payload = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
    @token = token
  end

  def machine_id = payload["machine_id"].to_s.strip.first(128).presence
  def hostname = payload["hostname"].to_s.strip.first(255).presence
  def agent_version = payload["agent_version"].to_s.first(64)
  def truncated? = payload["truncated"] == true
  # The agent's configured interval, before jitter. Older agents don't send it.
  def interval_seconds = (payload["interval_seconds"] if payload["interval_seconds"].is_a?(Integer) && payload["interval_seconds"].between?(1, 1.day))

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
    payload.slice("machine_id", "hostname", "agent_version", "labels", "truncated", "interval_seconds")
      .merge("containers" => containers.map { it.slice(*%w[ id name image service role destination version kind state health started_at ]) })
  end

  def ingest_later
    SnapshotIngestJob.perform_later(token, to_job)
  end

  # Returns the server, and redraws its pages if any now draw differently: a
  # placement came, went or changed, the server's labels or place moved, or a
  # quiet agent is back. Most snapshots change nothing.
  def ingest
    changed = false
    server = Server.transaction do
      server = claim_server
      was_quiet = !server.reporting? || server.stale?
      server.assign_attributes(machine_id: machine_id, labels: labels, agent_version: agent_version, interval_seconds: interval_seconds, **location)
      server_changed = server.changed?
      server.update!(last_seen_at: Time.current)
      changed = record_placements(server) || server_changed || was_quiet
      server
    end
    Board.refresh_later(server) if changed
    server
  end

  private
    def containers_shape
      errors.add(:containers, "must be a list") unless payload["containers"].is_a?(Array)
      errors.add(:containers, "has more than #{MAX_CONTAINERS}") if Array(payload["containers"]).size > MAX_CONTAINERS
    end

    def labels_shape
      errors.add(:labels, "must be an object") unless payload["labels"].nil? || payload["labels"].is_a?(Hash)
    end

    # Refused in the request, so the agent hears it, not only the job.
    def token_fits_machine
      if machine_id && bound_elsewhere?
        errors.add(:base, "This token belongs to another server. Give each server its own token, or use a fleet token")
      end
    end

    # Another machine's token, while that machine may still be alive. Once its
    # server is reclaimable, the token's new machine (a rebuild, booted with
    # the same secret) takes the server back.
    def bound_elsewhere?
      bound = token.server
      bound&.machine_id.present? && bound.machine_id != machine_id && !bound.reclaimable?
    end

    def claim_server
      raise Rejected, "This token belongs to another server" if bound_elsewhere?

      server = token.server || Server.find_by(machine_id: machine_id) || unclaimed_server || Server.create!(name: hostname, hostname: hostname)
      # A rebuild that reported before the old machine had been silent long
      # enough made a row of its own. Once it has, that row moves onto Git's.
      server = reclaimable_server || server if server.machine_id == machine_id && server.assignments.none?
      release_machine_id(server)
      token.update!(server: server) unless token.fleet?
      server
    end

    # Machine ids are unique, so the row this machine made, which Git doesn't
    # place, goes when the machine moves onto another.
    def release_machine_id(server)
      Server.where(machine_id: machine_id).where.not(id: server.id).find_each do |own|
        raise Rejected, "This machine already reports as #{own.name}" if own.assignments.exists?
        own.destroy!
      end
    end

    # Git knows servers by the host Kamal SSHes to; the agent knows its own
    # hostname. Match exactly, or by the first DNS label when that is unique
    # (never for IPs, whose first label is shared).
    def unclaimed_server
      candidates = Server.where(machine_id: nil)
      candidates.find_by(hostname: hostname) || candidates.find_by(name: hostname) || reclaimable_server || begin
        return if Server.ip?(hostname)

        short = hostname.split(".").first
        matches = candidates.select { [ it.hostname, it.name ].any? { |name| !Server.ip?(name) && name.split(".").first == short } }
        matches.sole if matches.one?
      end
    end

    # A server Git places whose agent has gone silent (Server#reclaimable?)
    # was rebuilt, with a new machine id. Only an exact host takes it: a first
    # DNS label is shared too easily to hand over a server with a history.
    def reclaimable_server
      Server.where(hostname: hostname).or(Server.where(name: hostname)).where(id: Assignment.select(:server_id))
        .where.not(machine_id: [ nil, machine_id ]).sort_by { it.hostname == hostname ? 0 : 1 }.find(&:reclaimable?)
    end

    def record_placements(server)
      now = Time.current
      rows = containers.filter_map { placement_row(server, it, now) }.uniq { it[:container_id] }
      before = server.placements.pluck(*SHOWN).to_set

      Placement.upsert_all(rows, unique_by: %i[ server_id container_id ]) if rows.any?
      server.placements.where.not(container_id: rows.map { it[:container_id] }).delete_all unless truncated?
      server.placements.pluck(*SHOWN).to_set != before
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
        started_at: started_at(container), observed_at: now
      }
    end

    # The agent sends RFC 3339. Anything else is left out, not guessed.
    def started_at(container)
      Time.iso8601(container["started_at"].to_s)
    rescue ArgumentError
      nil
    end

    def app_for(server, service, destination)
      @apps ||= Hash.new do |cache, key|
        candidates = App.where(service: key.first, destination: key.last).to_a
        cache[key] = candidates.find { |app| app.assignments.exists?(server_id: server.id) } || candidates.first
      end
      @apps[[ service, destination ]]&.id
    end
end
