module ApplicationHelper
  # How many things need attention, for the sidebar. Cached briefly: it is
  # shown on every page and the board refreshes itself anyway.
  def attention_count
    Rails.cache.fetch("attention-count", expires_in: 15.seconds) { Board.new.attention.size }
  end

  def time_ago(time)
    return tag.span("never", class: "text-ink-faint") unless time
    tag.time("#{time_ago_in_words(time)} ago", datetime: time.iso8601, title: time.to_fs(:long))
  end

  def short_sha(sha)
    tag.code(sha.to_s.first(7))
  end

  # Labels other than the place ones, which have a column of their own.
  PLACE_LABELS = %w[ city region lat lng ].freeze

  def labels_list(labels, except: [])
    safe_join(labels.except(*except).sort.map { |key, value| render(Ui::BadgeComponent.new("#{key}=#{value}", mono: true)) }, " ")
  end

  def place(server)
    city, region = server.label("city"), server.label("region")
    return tag.span("–", class: "text-ink-faint") unless city || region
    safe_join([ city, (tag.span(region, class: "font-mono text-xs text-ink-muted") if region) ].compact, " ")
  end
end
