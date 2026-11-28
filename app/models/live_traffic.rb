# Requests, as kamal-proxy logs them: an app's, or every app's at once (the
# fleet). Reading traffic tails kamal-proxy on each server it covers, with the
# same lease as reading logs, and AgentChannel hands every kamal-proxy batch
# here. Only request lines logged under one of a watched app's services reach
# that app's readers; the fleet's readers get every request line, whichever
# service it was logged under. kamal-proxy's own lines stop here. Nothing is
# stored.
module LiveTraffic
  MAX_PROXIES = LiveLogs::MAX_PLACEMENTS
  STATUS_KEYS = %w[ dropped ended off refused ].freeze
  # What the Traffic page in the sidebar reads, in place of an app.
  FLEET = "fleet"

  module_function

  # kamal-proxy on each server the app is placed on or assigned to, or for
  # the fleet, on every server, the first MAX_PROXIES of them.
  def proxies(subject)
    scope = Placement.includes(:server).where(kind: "proxy")
    scope = scope.where(server_id: subject.placements.distinct.pluck(:server_id) | subject.assignments.pluck(:server_id)) unless subject == FLEET
    scope.order(:server_id).limit(MAX_PROXIES).to_a
  end

  # How many servers report kamal-proxy, read or not.
  def proxy_servers = Placement.where(kind: "proxy").distinct.count(:server_id)

  # The names kamal-proxy logs the app's requests under. Kamal deploys each
  # role as "<service>-<role>[-<destination>]" (kamal v2.12.0,
  # Kamal::Configuration::Role#container_prefix).
  def services(app)
    app.roles.to_set { [ app.service, it["name"], app.destination.presence ].compact.join("-") }
  end

  # Someone is reading the app's traffic, or the fleet's. Renewed with the
  # tail leases.
  def watch(subject, proxies)
    Rails.cache.write(watch_key(subject), true, expires_in: LiveLogs::LEASE)
    proxies.each { Rails.cache.write(server_key(it.server_id), true, expires_in: LiveLogs::LEASE) }
  end

  # A batch from kamal-proxy on server, as LiveLogs.parse left it. Each app
  # being read gets its own requests, the fleet being read gets them all, and
  # each gets kamal-proxy's notices (logs off, refused, stopped, lines
  # dropped) since they are about its traffic too. Traffic is live only: a
  # backlog's lines, asked for by someone reading kamal-proxy's logs or by an
  # agent's reconnect, are history and stop here.
  def relay(server, proxy, batch)
    return unless Rails.cache.read(server_key(server.id))

    apps = watched_apps(server)
    fleet = Rails.cache.read(watch_key(FLEET))
    return if apps.empty? && !fleet

    requests = batch["backlog"] ? [] : Array(batch["lines"]).filter_map { |line| request_service(line["m"])&.then { [ it, line ] } }
    status = batch.slice(*STATUS_KEYS)

    owners = apps.each_with_object({}) { |app, owners| services(app).each { owners[it] = app } }
    by_app = requests.group_by { |service, _| owners[service] }
    apps.each { deliver(it, batch, proxy, by_app[it]&.map(&:last), status) }
    deliver(FLEET, batch, proxy, requests.map(&:last).presence, status) if fleet
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

  def deliver(subject, batch, proxy, lines, status)
    return if lines.nil? && status.empty?

    TrafficChannel.broadcast_to(subject, { "container" => batch["container"], "source" => proxy.id, "lines" => lines, **status }.compact)
  end
  private_class_method :deliver

  def watched_apps(server)
    ids = Placement.where(server: server).where.not(app_id: nil).distinct.pluck(:app_id) | Assignment.where(server: server).pluck(:app_id)
    watched = Rails.cache.read_multi(*ids.map { watch_key(it) })
    App.where(id: ids.select { watched[watch_key(it)] }).to_a
  end
  private_class_method :watched_apps

  # An app's key by its id, so watched_apps can look apps up without loading them.
  def watch_key(subject) = [ "live-traffic", subject.is_a?(App) ? subject.id : subject ]
  def server_key(server_id) = [ "live-traffic-server", server_id ]
  private_class_method :watch_key, :server_key
end
