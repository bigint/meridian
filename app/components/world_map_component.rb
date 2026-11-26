# Servers on a world map: places, shared-app links, and Meridian's own
# traffic flowing in and out. Geometry comes from WorldMap.
class WorldMapComponent < ApplicationComponent
  LEGEND_STATES = %w[ in_sync drifted missing stale ].freeze

  def initialize(map:)
    @map = map
    @sites, @links, @flows, @hub = map.sites, map.links, map.flows, map.hub
  end

  private
    def site_href(site)
      site.servers.one? ? helpers.server_path(site.servers.first) : helpers.board_path(region: site.servers.first.label("region"))
    end

    def flow_title(flow)
      flow.kind == "report" ? "#{flow.from.name}: agent reports #{flow.live ? "arriving" : "have stopped"}" : "Deploying to #{flow.to.name}"
    end

    def labels
      list = @sites.map { [ @map.label(it), it ] }
      @hub ? list.unshift([ @map.hub_label, nil ]) : list
    end
end
