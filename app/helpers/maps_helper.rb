module MapsHelper
  LEGEND_STATES = %w[ in_sync drifted missing stale ].freeze

  # Where a place leads: its server when it has one, else the board for its region.
  def place_path(site)
    return server_path(site.servers.first) if site.servers.one?
    (region = site.label("region")) ? board_path(region: region) : board_path
  end

  def site_class(map, site)
    [ "site", site.state, ("deploying" if map.deploying?(site)) ].compact.join(" ")
  end

  # Several servers: how many. One: its state's icon, or an arrow while a
  # deploy goes out.
  def site_mark(map, site)
    return tag.text(site.servers.size, class: "symbol", dy: "0.35em") if site.servers.size > 1
    state = map.deploying?(site) && site.state == "in_sync" ? :deploying : site.state
    state_icon(state, class: "symbol", x: -3.5, y: -3.5, width: 7, height: 7)
  end

  def site_title(map, site)
    state = map.deploying?(site) ? "deploying" : Drift::LABELS[site.state].downcase
    "#{site.name}: #{pluralize(site.servers.size, "server")}, #{state}"
  end

  def flow_title(flow)
    flow.kind == "report" ? "#{flow.from.name}: agent reports #{flow.live ? "arriving" : "have stopped"}" : "Deploying to #{flow.to.name}"
  end

  # Only some places are named (WorldMap#named_keys); the rest on hover.
  def map_labels(map)
    placed = map.labels(map.named_keys)
    list = map.sites.filter_map { |site| [ placed[site.key], site ] if placed[site.key] }
    placed[:hub] ? list.unshift([ placed[:hub], nil ]) : list
  end
end
