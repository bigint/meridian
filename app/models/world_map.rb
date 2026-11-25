# Servers on a world map, from what Meridian already knows:
#
# - sites: located servers, grouped when they sit within a few kilometres;
# - links: two sites run the same app (thicker when they share more apps);
# - flows: agents reporting to Meridian, and deploys going out from it.
#
# Meridian sees containers, not packets, so flows are its own traffic, never
# guessed traffic between servers. Equirectangular, cropped to inhabited
# latitudes, so a point is two lines of arithmetic.
class WorldMap
  WIDTH = 1000.0
  NORTH, SOUTH = 84.0, -58.0
  HEIGHT = (WIDTH * (NORTH - SOUTH) / 360.0).round(1)
  MERGE_WITHIN = 6.0 # map units; about 60 km at the equator

  Site = Data.define(:key, :x, :y, :servers, :cells) do
    def state = Drift.worst(cells.map(&:state)) || (servers.any?(&:reporting?) ? "in_sync" : "unknown")
    def stale? = servers.all? { !it.reporting? || it.stale? }
    def name = servers.map { it.label("region") }.compact.tally.max_by(&:last)&.first || servers.first.short_name
    def apps = cells.map(&:app).uniq
  end

  Link = Data.define(:from, :to, :apps) do
    def weight = apps.size
  end

  Flow = Data.define(:from, :to, :kind, :live) # kind: "report" | "deploy"

  def self.project(latitude, longitude)
    x = (longitude + 180.0) / 360.0 * WIDTH
    y = (NORTH - latitude.clamp(SOUTH, NORTH)) / (NORTH - SOUTH) * HEIGHT
    [ x.round(1), y.round(1) ]
  end

  # A gentle arc between two points as an SVG path. Links bow towards the
  # pole and flows towards the equator, so the two never sit on each other.
  def self.arc(from, to, bend: 0.22)
    (x1, y1), (x2, y2) = from, to
    lift = Math.hypot(x2 - x1, y2 - y1) * bend
    "M#{x1} #{y1} Q#{((x1 + x2) / 2).round(1)} #{((y1 + y2) / 2 - lift).round(1)} #{x2} #{y2}"
  end

  attr_reader :filters

  def initialize(filters = {})
    @filters = filters.to_h.symbolize_keys.compact_blank
  end

  def account = @account ||= Account.current
  def hub = (self.class.project(account.latitude, account.longitude) if account.located?)
  def unlocated = board.servers.values.reject(&:located?)

  def sites
    @sites ||= begin
      cells_by_server = board.cells.group_by { it.server.id }
      groups = []
      board.servers.values.select(&:located?).sort_by(&:id).each do |server|
        point = self.class.project(server.latitude, server.longitude)
        group = groups.find { |g| Math.hypot(g[:point][0] - point[0], g[:point][1] - point[1]) <= MERGE_WITHIN }
        group ? group[:servers] << server : groups << { point: point, servers: [ server ] }
      end
      groups.map do |group|
        Site.new(key: group[:servers].first.id, x: group[:point][0], y: group[:point][1], servers: group[:servers],
          cells: group[:servers].flat_map { cells_by_server.fetch(it.id, []) })
      end
    end
  end

  # One link per pair of sites that share apps. Each app joins its sites in a
  # chain from west to east, so a twenty-site app draws nineteen lines, not 190.
  def links
    @links ||= begin
      site_of = sites.flat_map { |site| site.servers.map { [ it.id, site ] } }.to_h
      pairs = Hash.new { |h, k| h[k] = [] }
      board.cells.select { it.state != "stray" }.group_by(&:app).each do |app, cells|
        app_sites = cells.filter_map { site_of[it.server.id] }.uniq.sort_by(&:x)
        app_sites.each_cons(2) { |a, b| pairs[[ a, b ].sort_by(&:key)] << app }
      end
      pairs.map { |(a, b), apps| Link.new(from: a, to: b, apps: apps.uniq) }
    end
  end

  def flows
    return [] unless hub

    reports = sites.map { |site| Flow.new(from: site, to: nil, kind: "report", live: !site.stale?) }
    deploys = Deploy.active.includes(app: :servers).flat_map do |deploy|
      deploy.app.servers.filter_map { |server| sites.find { it.servers.include?(server) } }.uniq
    end.uniq.map { |site| Flow.new(from: nil, to: site, kind: "deploy", live: true) }
    reports + deploys
  end

  def stream_keys
    board.servers.values.map { Board.stream_key(it) }.uniq.presence || [ "all" ]
  end

  private
    def board
      @board ||= Board.new(filters.slice(:project, :app, *Board::LABELS.map(&:to_sym)).merge(group: "none"))
    end
end
