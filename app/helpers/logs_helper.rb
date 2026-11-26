module LogsHelper
  TONES = 8

  # What the page's channel needs to stream what this viewing recorded (LiveLogs.grant).
  def live_grant(*subject)
    LiveLogs.grant(current_user, *subject)
  end

  # What the viewer needs to know about each container it merges: a short
  # name that tells them apart, and a colour that stays the same for the
  # same container whenever the set doesn't change.
  def log_sources(placements)
    per_server = placements.group_by(&:server_id).transform_values(&:size)
    tones = placements.sort_by { [ it.server.name, it.name ] }.each_with_index.to_h { |placement, index| [ placement.id, index % TONES ] }

    placements.map do |placement|
      label = [ placement.server.short_name, (placement.role.presence || placement.kind if per_server[placement.server_id] > 1) ].compact.join(" · ")
      { id: placement.id, label: label, server: placement.server.name, title: "#{placement.name} on #{placement.server.name}", tone: tones[placement.id] }
    end
  end

  # For kamal-proxy's request lines: the containers it can send a request to,
  # by the short id Kamal deploys them with (kamal v2.12.0,
  # Kamal::Cli::App::Boot#start_new_version), named with a short version.
  def log_targets(placements)
    servers = placements.select { it.kind == "proxy" }.map(&:server_id)
    return {} if servers.empty?

    Placement.where(server_id: servers, kind: "app").to_h do |placement|
      name = placement.version.present? ? placement.name.delete_suffix(placement.version) + placement.short_version : placement.name
      [ placement.container_id.first(12), name ]
    end
  end
end
