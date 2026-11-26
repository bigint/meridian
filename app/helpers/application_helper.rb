module ApplicationHelper
  # Whether this browser collapsed the sidebar to its icon rail.
  def sidebar_collapsed? = cookies[:sidebar] == "collapsed"

  # The theme this browser asked for: "light", "dark", or nil for the system's.
  def theme = cookies[:theme].presence_in(%w[ light dark ])

  # How many things need attention, for the sidebar. Cached briefly: it is
  # shown on every page and the board refreshes itself anyway.
  def sidebar_link(name, path, icon_name, count = nil)
    current = path == root_path ? request.path.in?([ root_path, board_path ]) : request.path.start_with?(path)
    link_to path, class: "sidebar__link", data: { tooltip: name }, aria: { current: (current ? "page" : nil) } do
      safe_join([
        icon(icon_name),
        tag.span(name, class: "sidebar__label"),
        (tag.span(count, class: "sidebar__count", aria: { label: "#{pluralize(count, "thing")} need attention" }) if count.to_i.positive?)
      ].compact)
    end
  end

  def attention_count
    Rails.cache.fetch("attention-count", expires_in: 15.seconds) { Board.new.attention.size }
  end

  def time_ago(time)
    return tag.span("never", class: "txt-faint") unless time
    tag.time("#{time_ago_in_words(time)} ago", datetime: time.iso8601, data: { tooltip: time.to_fs(:long) })
  end

  def short_sha(sha)
    tag.code(sha.to_s.first(7))
  end

  # Labels other than the place ones, which have a column of their own.
  PLACE_LABELS = %w[ city region lat lng ].freeze

  def labels_list(labels, except: [])
    safe_join(labels.except(*except).sort.map { |key, value| badge("#{key}=#{value}", mono: true) }, " ")
  end

  def place(server)
    city, region = server.label("city"), server.label("region")
    return tag.span("–", class: "txt-faint") unless city || region
    safe_join([ city, (tag.span(region, class: "mono txt-small txt-muted") if region) ].compact, " ")
  end

  # A page's title, a line of context, and its actions (the block).
  def page_header(title, meta: nil, tabs: nil, &actions)
    tag.header class: "page-header" do
      row = tag.div(class: "page-header__row") do
        safe_join([
          tag.h1(title, class: "page-header__title"),
          (tag.span(meta, class: "page-header__meta") if meta),
          (tag.div(capture(&actions), class: "page-header__actions") if actions)
        ].compact)
      end
      tabs ? row + tabs : row
    end
  end

  # A titled block of a page, labelled for screen readers by its heading.
  def titled_section(title, count: nil, id: nil, actions: nil, **html, &body)
    id ||= "section-#{title.parameterize}"
    tag.section class: [ "section", html.delete(:class) ], aria: { labelledby: id }, **html do
      heading = tag.h2(id: id, class: "section__title") { safe_join([ title, (tag.span(count, class: "section__count") if count) ].compact) }
      header = tag.div(safe_join([ heading, actions ].compact), class: "section__header")
      header + capture(&body)
    end
  end

  def badge(text, tone: nil, mono: false, **html)
    tag.span text, class: [ "badge", ("badge--#{tone}" if tone), ("badge--mono" if mono), html.delete(:class) ], **html
  end

  # A drift state as a symbol and a word: never colour alone.
  def state_badge(state)
    return tag.span("–", class: "txt-faint", data: { tooltip: "Nothing here" }) unless state
    tag.span class: "badge", data: { state: state } do
      safe_join([ tag.span(Drift::SYMBOLS[state], aria: { hidden: true }), Drift::LABELS[state] ], " ")
    end
  end

  CHIP_TONES = { "in_sync" => "txt-ok", "drifted" => "txt-warn", "missing" => "txt-bad", "stray" => "txt-info", "stale" => "txt-muted", "unknown" => "txt-muted" }.freeze

  # A count with its meaning; with href, a filter you toggle.
  def chip(label, count, state: nil, symbol: nil, tone: nil, href: nil, current: false)
    symbol ||= Drift::SYMBOLS[state] if state
    body = safe_join([
      (tag.span(symbol, class: [ "chip__symbol", tone || CHIP_TONES[state] ], aria: { hidden: true }) if symbol),
      tag.span(label),
      (tag.span(count, class: "chip__count") if count)
    ].compact)
    href ? link_to(body, href, class: "chip", aria: { current: (current ? "true" : nil) }) : tag.span(body, class: "chip")
  end

  # One app on one server: the version it runs, tinted by its drift state.
  def version_cell(cell)
    running = cell.versions.join(", ")
    text = case cell.state
    when "missing" then "✕"
    when "unknown" then "?"
    when "drifted" then "≠#{cell.versions.first&.first(10)}"
    else cell.version&.first(10) || "–"
    end
    title = "#{cell.app.name} on #{cell.server.name}: #{Drift::LABELS[cell.state]}#{", running #{running}" if running.present?}"
    tag.span class: "cell", data: { cell: true, state: cell.state, tooltip: title } do
      safe_join([ tag.span("#{Drift::LABELS[cell.state]}: ", class: "sr-only"), text ])
    end
  end

  # Initials on a tint that stays the same for the same name, or a drift
  # state's symbol when the avatar stands for a problem.
  def avatar(name = nil, state: nil, small: false)
    text = state ? Drift::SYMBOLS[state] : initials(name.to_s)
    data = state ? { state: state } : { tone: Zlib.crc32(name.to_s) % 5 }
    tag.span text, class: [ "avatar", ("avatar--small" if small) ], data: data, aria: { hidden: true }
  end

  # Sub-pages: [ label, url, current ] items.
  def tabs(label, items)
    tag.nav class: "tabs", aria: { label: label } do
      safe_join(items.map { |text, url, current| link_to text, url, aria: { current: (current ? "page" : nil) } })
    end
  end

  # Views of the same thing: [ label, url, current ] items.
  def segmented(label, items)
    tag.nav class: "segmented", aria: { label: label } do
      safe_join(items.map { |text, url, current| link_to text, url, aria: { current: (current ? "true" : nil) } })
    end
  end

  def disclosure(summary, open: false, &body)
    tag.details class: "disclosure", open: open do
      tag.summary { icon(:chevron) + summary } + tag.div(capture(&body), class: "disclosure__body")
    end
  end

  ALERT_ICONS = { ok: :ok, warn: :warn, bad: :bad }.freeze

  # A message in the flow of the page. Errors are announced at once; the
  # rest politely.
  def alert_box(tone = nil, title: nil, &body)
    tag.div class: [ "alert", ("alert--#{tone}" if tone) ], role: (tone == :bad ? "alert" : "status") do
      icon(ALERT_ICONS.fetch(tone, :info), class: "alert__icon") +
        tag.div(safe_join([ (tag.p(title, class: "alert__title") if title), capture(&body) ].compact), class: "alert__body")
    end
  end

  # A short value to paste somewhere else, with a copy button beside it.
  def copyable(text)
    tag.span class: "copyable", data: { controller: "clipboard" } do
      tag.code(text, class: "copyable__value", data: { clipboard_target: "source" }) +
        tag.button(type: "button", class: "copyable__copy", data: { action: "clipboard#copy", clipboard_target: "button" }, aria: { label: "Copy #{text}" }) do
          icon(:copy, class: "copyable__idle") + icon(:copied, class: "copyable__done") + tag.span("Copy", class: "sr-only", data: { clipboard_target: "label" })
        end
    end
  end

  def empty_state(title, icon_name: nil, &body)
    tag.div class: "empty" do
      safe_join([
        (icon(icon_name) if icon_name),
        tag.p(title, class: "empty__title"),
        (tag.div(capture(&body), class: "empty__body") if body)
      ].compact)
    end
  end

  def pagination(label:, previous_url: nil, next_url: nil, previous_label: "Previous", next_label: "Next")
    return unless previous_url || next_url
    tag.nav class: "pagination", aria: { label: "Pages" } do
      safe_join([
        (previous_url ? link_to(icon(:previous) + previous_label, previous_url, class: "btn btn--small") : tag.span),
        tag.span(label, class: "txt-small txt-muted"),
        (next_url ? link_to(tag.span(next_label) + icon(:next), next_url, class: "btn btn--small") : tag.span)
      ])
    end
  end

  # Errors for a form, above its fields.
  def field_errors(record, attribute)
    messages = record.respond_to?(:errors) ? record.errors[attribute] : []
    tag.p(messages.to_sentence, class: "field__error") if messages.any?
  end

  private
    def initials(name)
      words = name.scan(/[[:alnum:]]+/)
      (words.size > 1 ? words.first(2).map { it[0] }.join : words.first.to_s[0, 2]).upcase.presence || "?"
    end
end
