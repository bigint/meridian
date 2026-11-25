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
    # A "city" label reads best; otherwise the most common region, then a server.
    def name
      %w[ city region ].each do |key|
        common = servers.filter_map { it.label(key) }.tally.max_by(&:last)&.first
        return common if common
      end
      servers.first.short_name
    end
    def apps = cells.map(&:app).uniq
  end

  Link = Data.define(:from, :to, :apps) do
    def weight = apps.size
  end

  Flow = Data.define(:from, :to, :kind, :live) # kind: "report" | "deploy"

  # Where a name goes: its centre, how it is anchored, its box, and the
  # point a leader line starts from when it had to move away from its dot.
  Label = Data.define(:text, :x, :y, :anchor, :box, :leader)

  CHAR_WIDTH = 6.2  # map units per character at the label size
  LABEL_HEIGHT = 11
  HUB_RADIUS = 6

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

  def radius(site) = (4.5 + Math.sqrt(site.servers.size) * 1.6).round(1)
  def hub_name = account.location_name.presence || "Meridian"
  def hub_label = labels[:hub]
  def label(site) = labels[site.key]

  # Places every name where it overlaps no other name and no dot. Bigger
  # places choose first; each tries beside its dot, then further out with a
  # leader line, and keeps its first spot if nothing is free.
  def labels
    @labels ||= begin
      dots = sites.map { |site| box_around(site.x, site.y, radius(site)) }
      dots << box_around(*hub, HUB_RADIUS) if hub

      items = sites.sort_by { [ -it.servers.size, it.key ] }.map { [ it.key, [ it.x, it.y ], radius(it), it.name ] }
      items.unshift([ :hub, hub, HUB_RADIUS, hub_name ]) if hub

      taken = []
      items.to_h do |key, (x, y), r, text|
        own = box_around(x, y, r)
        candidates = label_positions(text, x, y, r)
        choice = candidates.find { |label| (taken + dots - [ own ]).none? { overlap?(label.box, it) } } || candidates.first
        taken << choice.box
        [ key, choice ]
      end
    end
  end

  def stream_keys
    board.servers.values.map { Board.stream_key(it) }.uniq.presence || [ "all" ]
  end

  private
    def box_around(x, y, r) = [ x - r, y - r, x + r, y + r ]

    def overlap?(a, b)
      a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]
    end

    # Beside the dot first (above, below, right, left), then twice as far
    # in eight directions, each with a leader line back to the dot.
    def label_positions(text, x, y, r)
      w, h, gap = text.length * CHAR_WIDTH, LABEL_HEIGHT, 3
      near = [
        [ x, y - r - gap - h / 2.0, "middle" ], [ x, y + r + gap + h / 2.0, "middle" ],
        [ x + r + gap, y, "start" ], [ x - r - gap, y, "end" ]
      ].map { |cx, cy, anchor| build_label(text, cx, cy, anchor, w, h, nil) }

      far = [ [ 0, -1 ], [ 0, 1 ], [ 1, 0 ], [ -1, 0 ], [ 1, -1 ], [ -1, -1 ], [ 1, 1 ], [ -1, 1 ] ].flat_map do |dx, dy|
        [ 18, 30 ].map do |distance|
          cx, cy = x + dx * (r + distance), y + dy * (r + distance * 0.6)
          anchor = dx.positive? ? "start" : dx.negative? ? "end" : "middle"
          build_label(text, cx, cy, anchor, w, h, [ x + dx * r * 0.7, y + dy * r * 0.7 ])
        end
      end
      near + far
    end

    def build_label(text, cx, cy, anchor, w, h, leader)
      left = { "start" => cx, "end" => cx - w, "middle" => cx - w / 2.0 }.fetch(anchor)
      Label.new(text: text, x: cx.round(1), y: cy.round(1), anchor: anchor, box: [ left, cy - h / 2.0, left + w, cy + h / 2.0 ], leader: leader&.map { it.round(1) })
    end

    def board
      @board ||= Board.new(filters.slice(:project, :app, *Board::LABELS.map(&:to_sym)).merge(group: "none"))
    end
end
