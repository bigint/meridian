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

  def labels_list(labels)
    safe_join(labels.sort.map { |key, value| render(Ui::BadgeComponent.new("#{key}=#{value}", mono: true)) }, " ")
  end
end
