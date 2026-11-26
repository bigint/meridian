module MapsHelper
  LEGEND_STATES = %w[ in_sync drifted missing stale ].freeze

  # The map with this place in the side panel, keeping the filters.
  def map_place_path(site) = map_path(request.query_parameters.merge(place: site.key))

  def site_class(map, site, selected)
    [ "site", site.state, ("deploying" if map.deploying?(site)), ("selected" if site == selected) ].compact.join(" ")
  end

  # Several servers: how many. One: its state's symbol, or ↗ while a deploy goes out.
  def site_text(map, site)
    return site.servers.size.to_s if site.servers.size > 1
    map.deploying?(site) && site.state == "in_sync" ? "↗" : Drift::SYMBOLS[site.state]
  end

  def site_title(map, site)
    state = map.deploying?(site) ? "deploying" : Drift::LABELS[site.state].downcase
    "#{site.name}: #{pluralize(site.servers.size, "server")}, #{state}"
  end

  def flow_title(flow)
    flow.kind == "report" ? "#{flow.from.name}: agent reports #{flow.live ? "arriving" : "have stopped"}" : "Deploying to #{flow.to.name}"
  end

  # Only some places are named (WorldMap#named_keys); the rest on hover.
  def map_labels(map, selected)
    placed = map.labels(map.named_keys(selected))
    list = map.sites.filter_map { |site| [ placed[site.key], site ] if placed[site.key] }
    placed[:hub] ? list.unshift([ placed[:hub], nil ]) : list
  end

  def place_coordinates(site)
    server = site.servers.find(&:located?)
    lat, lng = server.latitude, server.longitude
    format("%.2f°%s %.2f°%s", lat.abs, lat.negative? ? "S" : "N", lng.abs, lng.negative? ? "W" : "E")
  end

  def place_summary(site)
    apps = site.apps.map(&:name)
    servers = pluralize(site.servers.size, "server")
    apps.any? ? "#{servers} running #{apps.to_sentence}" : "#{servers}, nothing assigned"
  end

  # How recently a server's agent reported, and whether that is worrying.
  def agent_status(server)
    if !server.reporting? then tag.span("no agent yet", class: "txt-small txt-muted")
    elsif server.stale? then tag.span("quiet for #{time_ago_in_words(server.last_seen_at)}", class: "txt-small txt-warn")
    elsif server.last_seen_at > 1.minute.ago then tag.span("reported just now", class: "txt-small txt-muted")
    else tag.span("reported #{time_ago_in_words(server.last_seen_at)} ago", class: "txt-small txt-muted")
    end
  end

  def place_note(map, site)
    if map.deploying?(site) then "A deploy is going out here now. The board shows each server as it picks up the new version."
    elsif site.state.in?(Drift::ATTENTION_RANK.keys) then Drift::MEANINGS[site.state]
    end
  end
end
