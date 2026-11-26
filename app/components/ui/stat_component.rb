# A number with its meaning, optionally a filter link. The board's summary.
class Ui::StatComponent < ApplicationComponent
  def initialize(label:, value:, state: nil, href: nil, current: false)
    @label, @value, @state, @href, @current = label, value, state, href, current
  end

  def call
    body = tag.span(@value, class: "text-lg font-semibold text-ink tabular-nums") +
      tag.span(class: "flex items-center gap-1 text-xs text-ink-muted") do
        safe_join([ (tag.span(Drift::SYMBOLS[@state], class: SYMBOL_TONES[@state], aria: { hidden: true }) if @state), @label ].compact)
      end
    css = classes("flex min-w-28 flex-col rounded-md border px-3 py-2 transition-colors",
      @current ? "border-accent bg-accent-soft" : "border-line hover:bg-surface")
    @href ? link_to(body, @href, class: css, aria: { current: (@current ? "true" : nil) }) : tag.div(body, class: css)
  end

  SYMBOL_TONES = { "in_sync" => "text-ok", "drifted" => "text-warn", "missing" => "text-bad", "stray" => "text-info", "stale" => "text-mute", "unknown" => "text-mute" }.freeze
end
