# Servers on a world map: places, shared-app links, and Meridian's own
# traffic flowing in and out. Geometry comes from WorldMap.
class WorldMapComponent < ApplicationComponent
  LEGEND_STATES = %w[ in_sync drifted missing stale ].freeze

  # place_url: where a place's dot leads; with one, dots pick the place for
  # the side panel. A whole-page visit, since the ring and names move too.
  def initialize(map:, selected: nil, place_url: nil)
    @map, @selected, @place_url = map, selected, place_url
    @sites, @links, @flows, @hub = map.sites, map.links, map.flows, map.hub
  end

  private
    def site_href(site)
      return @place_url.call(site) if @place_url
      site.servers.one? ? helpers.server_path(site.servers.first) : helpers.board_path(region: site.servers.first.label("region"))
    end

    def site_class(site)
      classes("site", site.state, ("deploying" if @map.deploying?(site)), ("selected" if site == @selected))
    end

    # Several servers: how many. One: its state's symbol, or ↗ while a deploy goes out.
    def site_text(site)
      return site.servers.size.to_s if site.servers.size > 1
      @map.deploying?(site) && site.state == "in_sync" ? "↗" : Drift::SYMBOLS[site.state]
    end

    def site_title(site)
      state = @map.deploying?(site) ? "deploying" : Drift::LABELS[site.state].downcase
      "#{site.name}: #{helpers.pluralize(site.servers.size, "server")}, #{state}"
    end

    def flow_title(flow)
      flow.kind == "report" ? "#{flow.from.name}: agent reports #{flow.live ? "arriving" : "have stopped"}" : "Deploying to #{flow.to.name}"
    end

    # Only some places are named (see WorldMap#named_keys); the rest on hover.
    def labels
      placed = @map.labels(@map.named_keys(@selected))
      list = @sites.filter_map { |site| [ placed[site.key], site ] if placed[site.key] }
      placed[:hub] ? list.unshift([ placed[:hub], nil ]) : list
    end
end
