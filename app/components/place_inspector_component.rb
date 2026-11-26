# The map's side panel: one place, what runs on each of its servers, and
# what it shares with other places.
class PlaceInspectorComponent < ApplicationComponent
  def initialize(map:, site:, place_url:)
    @map, @site, @place_url = map, site, place_url
  end

  private
    def deploying? = @map.deploying?(@site)
    def region = @site.servers.filter_map { it.label("region") }.tally.max_by(&:last)&.first
    def cells_for(server) = @site.cells.select { it.server == server }.sort_by { it.app.name }
    def neighbours = @map.neighbours(@site).sort_by { |site, apps| [ -apps.size, site.name ] }

    def coordinates
      server = @site.servers.find(&:located?)
      lat, lng = server.latitude, server.longitude
      format("%.2f°%s %.2f°%s", lat.abs, lat.negative? ? "S" : "N", lng.abs, lng.negative? ? "W" : "E")
    end

    def summary
      apps = @site.apps.map(&:name)
      servers = helpers.pluralize(@site.servers.size, "server")
      apps.any? ? "#{servers} running #{apps.to_sentence}" : "#{servers}, nothing assigned"
    end

    def agent(server)
      if !server.reporting? then [ "no agent yet", "text-ink-muted" ]
      elsif server.stale? then [ "quiet for #{helpers.time_ago_in_words(server.last_seen_at)}", "text-warn" ]
      elsif server.last_seen_at > 1.minute.ago then [ "reported just now", "text-ink-muted" ]
      else [ "reported #{helpers.time_ago_in_words(server.last_seen_at)} ago", "text-ink-muted" ]
      end
    end

    def note
      if deploying? then "A deploy is going out here now. The board shows each server as it picks up the new version."
      elsif @site.state.in?(Drift::ATTENTION_RANK.keys) then Drift::MEANINGS[@site.state]
      end
    end

    def board_url
      region ? helpers.board_path(region: region) : helpers.board_path
    end
end
