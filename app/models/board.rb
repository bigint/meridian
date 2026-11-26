# The apps × servers grid. Builds every cell from four plucks, then filters,
# groups and paginates in memory, so the page renders only what it shows.
class Board
  PER_PAGE = 25
  LABELS = %w[ region provider role ].freeze
  VIEWS = %w[ apps servers ].freeze
  AUTO_GROUP_ABOVE = 30

  # state is the worst of role_states: each role Git assigns here, and each
  # role running here that Git doesn't assign, has a state of its own.
  Cell = Data.define(:app, :server, :state, :versions, :roles, :health, :release, :role_states) do
    def initialize(role_states: {}, **) = super

    # What the server reported running, never Git's version standing in for it.
    def version = versions.compact.first
    def roles_in(state) = role_states.select { |_, it| it == state }.keys

    # Every container here runs release: a server with an old container left,
    # or a role down, doesn't. Quiet agents count by their last report.
    def runs?(release) = state == "in_sync" || (state.in?(%w[ stale stray ]) && versions.any? && versions.all?(release))
  end

  Group = Data.define(:name, :rows, :columns, :cells) do
    def cell(row, column)
      row.is_a?(App) ? cells[[ row.id, column.id ]] : cells[[ column.id, row.id ]]
    end

    def key = name.to_s.parameterize.presence || "all"
  end

  # Something a person should look at, in the order they should look at it.
  # A silent agent is one item for its server, not one per app on it.
  Attention = Data.define(:state, :app, :server, :count, :cell)

  attr_reader :filters

  def initialize(filters = {})
    @filters = filters.to_h.symbolize_keys.compact_blank
  end

  def view = VIEWS.include?(filters[:view]) ? filters[:view] : "apps"
  def state = (filters[:state] if Drift::STATES.include?(filters[:state]))
  def page = filters[:page].to_i.clamp(1, pages)

  def group_by
    if filters[:group] == "none" then nil
    elsif LABELS.include?(filters[:group]) then filters[:group]
    elsif servers.size > AUTO_GROUP_ABOVE || regions_in_use > 1 then "region"
    end
  end

  # Counts per drift state, ignoring the state filter so the strip can be used to pick one.
  def summary
    @summary ||= all_cells.group_by(&:state).transform_values(&:count)
  end

  # The sidebar's count, cached briefly since every page shows it.
  def self.attention_count
    Rails.cache.fetch("attention-count", expires_in: 15.seconds) { new.attention.size }
  end

  def attention
    @attention ||= begin
      items = all_cells.select { it.state.in?(%w[ missing drifted stray ]) }.map { Attention.new(state: it.state, app: it.app, server: it.server, count: 1, cell: it) }
      quiet = all_cells.select { it.state == "stale" }.group_by(&:server)
      items += if quiet.size > 3
        [ Attention.new(state: "stale", app: nil, server: nil, count: quiet.size, cell: nil) ]
      else
        quiet.map { |server, cells| Attention.new(state: "stale", app: nil, server: server, count: cells.size, cell: cells.first) }
      end
      items.sort_by { [ Drift::ATTENTION_RANK.fetch(it.state), it.app&.name.to_s, it.server&.name.to_s ] }
    end
  end

  def cells
    @cells ||= state ? all_cells.select { it.state == state } : all_cells
  end

  def rows
    @rows ||= view == "apps" ? cells.map(&:app).uniq.sort_by(&:name) : cells.map(&:server).uniq.sort_by { [ group_name(it).to_s, it.name ] }
  end

  def pages = [ (rows.size / PER_PAGE.to_f).ceil, 1 ].max
  def page_rows = rows.slice((page - 1) * PER_PAGE, PER_PAGE) || []

  # The newest release of an app, from any of its cells.
  def release_for(app)
    groups.each { |group| group.cells.each_value { |cell| return cell.release if cell.app == app } }
    nil
  end

  def groups
    @groups ||= begin
      visible = page_rows.to_set
      shown = cells.select { visible.include?(view == "apps" ? it.app : it.server) }

      shown.group_by { group_name(it.server) }.sort_by { |name, _| name.to_s }.map do |name, group_cells|
        rows = group_cells.map { view == "apps" ? it.app : it.server }.uniq
        columns = group_cells.map { view == "apps" ? it.server : it.app }.uniq.sort_by(&:name)
        Group.new(name: name, rows: page_rows.select { rows.include?(it) }, columns: columns, cells: group_cells.index_by { [ it.app.id, it.server.id ] })
      end
    end
  end

  # The values each label takes across the fleet, for the filter menus.
  def label_values(key)
    Server.distinct.pluck(Arel.sql("json_extract(labels, '$.#{key}')")).compact.sort if LABELS.include?(key)
  end

  def servers
    @servers ||= begin
      scope = Server.all
      scope = scope.where(id: filters[:server_id]) if filters[:server_id]
      LABELS.each { |key| scope = scope.where("json_extract(labels, ?) = ?", "$.#{key}", filters[key.to_sym]) if filters[key.to_sym] }
      scope.to_a.index_by(&:id)
    end
  end

  def apps
    @apps ||= begin
      scope = App.deployable.includes(:project)
      scope = scope.where(id: filters[:app_id]) if filters[:app_id]
      scope = scope.where(project_id: filters[:project]) if filters[:project]
      scope = scope.where("apps.service LIKE ? ESCAPE '\\'", "%#{App.sanitize_sql_like(filters[:app])}%") if filters[:app]
      scope = scope.where(service: filters[:service]) if filters[:service]
      scope.to_a.index_by(&:id)
    end
  end

  # Live updates: one Turbo stream per region, refreshed at most once a second
  # however many snapshots arrive. The page morphs in place.
  STREAM_LABEL = "region"
  REFRESH_EVERY = 1.second

  def self.stream_key(server, labels = server.labels)
    labels.to_h[STREAM_LABEL].to_s.parameterize.presence || "all"
  end

  # A server that just moved region is refreshed in the region it left too,
  # so its old column goes away there.
  def self.refresh_later(server)
    keys = [ stream_key(server) ]
    keys << stream_key(server, server.labels_before_last_save) if server.saved_change_to_labels? && !server.previously_new_record?
    keys.uniq.each { refresh_stream_later(it) }
  end

  # The first change in a window refreshes at once. Later ones in the same
  # window share one refresh when it ends, so the last change always reaches
  # open pages, even when it landed after they re-read the board.
  def self.refresh_stream_later(key)
    if Rails.cache.write([ "board-refresh", key ], true, unless_exist: true, expires_in: REFRESH_EVERY)
      Turbo::StreamsChannel.broadcast_refresh_later_to(:board, key)
    elsif Rails.cache.write([ "board-refresh-trailing", key ], true, unless_exist: true, expires_in: REFRESH_EVERY)
      BoardRefreshJob.set(wait: REFRESH_EVERY).perform_later(key)
    end
  end

  # The window's closing refresh opens the next window, so a steady stream of
  # changes still refreshes about once a second.
  def self.refresh_now(key)
    Rails.cache.write([ "board-refresh", key ], true, expires_in: REFRESH_EVERY)
    Rails.cache.delete([ "board-refresh-trailing", key ])
    Turbo::StreamsChannel.broadcast_refresh_to(:board, key)
  end

  def stream_keys
    groups.flat_map { [ *it.rows, *it.columns ] }.grep(Server).map { self.class.stream_key(it) }.uniq.presence || [ "all" ]
  end

  private
    def regions_in_use
      @regions_in_use ||= servers.values.filter_map { it.label("region") }.uniq.size
    end

    def group_name(server)
      server.label(group_by) if group_by
    end

    def all_cells
      @all_cells ||= begin
        app_ids, server_ids = apps.keys, servers.keys
        assigned = Assignment.where(app_id: app_ids, server_id: server_ids).pluck(:app_id, :server_id, :role).group_by { it.first(2) }
        running = Placement.running.where(app_id: app_ids, server_id: server_ids).pluck(:app_id, :server_id, :role, :version, :health).group_by { it.first(2) }
        releases = Release.latest_per_app.where(app_id: apps.values.select(&:versioned?).map(&:id)).pluck(:app_id, :version).to_h

        (assigned.keys | running.keys).filter_map do |pair|
          app, server = apps[pair.first], servers[pair.last]
          wanted = Array(assigned[pair]).map(&:third)
          by_role = Array(running[pair]).group_by(&:third)
          role_states = (wanted | by_role.keys).index_with do |role|
            Drift.state(assigned: wanted.include?(role), versions: Array(by_role[role]).map { it[3] }.uniq, release: releases[app.id], server: server)
          end.compact
          state = Drift.worst(role_states.values)
          next unless state

          versions = Array(running[pair]).map { it[3] }.uniq
          health = Array(running[pair]).map { it[4] }.compact.min_by { %w[ unhealthy starting healthy ].index(it) || 3 }
          Cell.new(app: app, server: server, state: state, versions: versions, roles: role_states.keys.compact.sort, health: health,
            release: releases[app.id], role_states: role_states)
        end
      end
    end
end
