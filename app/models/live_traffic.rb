# An app's requests, as kamal-proxy logs them. Reading an app's traffic tails
# kamal-proxy on each of its servers, with the same lease as reading logs, and
# AgentChannel hands every kamal-proxy batch here. Only request lines logged
# under one of a watched app's services reach that app's readers; every other
# app's requests and kamal-proxy's own lines stop here. Nothing is stored.
module LiveTraffic
  MAX_PROXIES = LogsChannel::MAX_PLACEMENTS
  STATUS_KEYS = %w[ dropped ended off refused ].freeze

  module_function

  # kamal-proxy on each server the app is placed on or assigned to.
  def proxies(app)
    server_ids = app.placements.distinct.pluck(:server_id) | app.assignments.pluck(:server_id)
    Placement.includes(:server).where(kind: "proxy", server_id: server_ids).order(:server_id).limit(MAX_PROXIES).to_a
  end

  # The names kamal-proxy logs the app's requests under. Kamal deploys each
  # role as "<service>-<role>[-<destination>]" (kamal v2.12.0,
  # Kamal::Configuration::Role#container_prefix).
  def services(app)
    roles = app.roles.map { it["name"] }.presence || [ "web" ]
    roles.to_set { |role| [ app.service, role, app.destination.presence ].compact.join("-") }
  end

  # Someone is reading the app's traffic. Renewed with the tail leases.
  def watch(app, proxies)
    Rails.cache.write(app_key(app.id), true, expires_in: LiveLogs::LEASE)
    proxies.each { Rails.cache.write(server_key(it.server_id), true, expires_in: LiveLogs::LEASE) }
  end

  # A batch from kamal-proxy on server, as LiveLogs.parse left it. Each app
  # being read gets its own requests, and kamal-proxy's notices (logs off,
  # refused, stopped, lines dropped) since they are about its traffic too.
  def relay(server, proxy, batch)
    return unless Rails.cache.read(server_key(server.id))

    apps = watched_apps(server)
    return if apps.empty?

    owners = apps.each_with_object({}) { |app, owners| services(app).each { owners[it] = app } }
    lines = Array(batch["lines"]).group_by { owners[request_service(it["m"])] }
    status = batch.slice(*STATUS_KEYS)

    apps.each do |app|
      mine = lines[app]
      next if mine.nil? && status.empty?

      TrafficChannel.broadcast_to(app, { "container" => batch["container"], "source" => proxy.id, "backlog" => batch["backlog"], "lines" => mine, **status }.compact)
    end
  end

  # kamal-proxy's request lines are one JSON object with msg "Request"
  # (kamal-proxy v0.10.3, internal/server/logging_middleware.go).
  def request_service(message)
    return unless message.start_with?("{") && message.include?('"Request"')

    # kamal-proxy appends a req_/resp_ field per logged header after its own,
    # so logging Content-Type repeats req_content_type.
    object = JSON.parse(message, allow_duplicate_key: true)
    object["service"] if object.is_a?(Hash) && object["msg"] == "Request"
  rescue JSON::ParserError
    nil
  end

  def watched_apps(server)
    ids = Placement.where(server: server).where.not(app_id: nil).distinct.pluck(:app_id) | Assignment.where(server: server).pluck(:app_id)
    watched = Rails.cache.read_multi(*ids.map { app_key(it) })
    App.where(id: ids.select { watched[app_key(it)] }).to_a
  end
  private_class_method :watched_apps

  def app_key(app_id) = [ "live-traffic", app_id ]
  def server_key(server_id) = [ "live-traffic-server", server_id ]
  private_class_method :app_key, :server_key
end
