# A count with its meaning, as a chip; on the board, a filter you can toggle.
class Ui::StatComponent < ApplicationComponent
  SYMBOL_TONES = { "in_sync" => "text-ok", "drifted" => "text-warn", "missing" => "text-bad", "stray" => "text-info", "stale" => "text-mute", "unknown" => "text-mute" }.freeze

  def initialize(label:, value:, state: nil, href: nil, current: false)
    @label, @value, @state, @href, @current = label, value, state, href, current
  end

  def call
    body = safe_join([
      (tag.span(Drift::SYMBOLS[@state], class: classes("font-bold", SYMBOL_TONES[@state]), aria: { hidden: true }) if @state),
      tag.span(@label),
      tag.span(@value, class: "font-mono text-ink-muted")
    ].compact)
    css = classes("inline-flex h-7 items-center gap-1.5 rounded-full border px-3 text-xs transition-colors",
      @current ? "border-accent bg-accent-soft text-ink" : "border-line bg-canvas text-ink hover:bg-surface")
    @href ? link_to(body, @href, class: css, aria: { current: (@current ? "true" : nil) }) : tag.span(body, class: css)
  end
end
