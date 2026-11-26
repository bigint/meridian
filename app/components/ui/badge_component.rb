# A small label: kinds, roles, tags. Tones map to the semantic palette.
class Ui::BadgeComponent < ApplicationComponent
  TONES = {
    neutral: "bg-mute-soft text-mute", accent: "bg-accent-soft text-accent-strong",
    ok: "bg-ok-soft text-ok", warn: "bg-warn-soft text-warn", bad: "bg-bad-soft text-bad", info: "bg-info-soft text-info"
  }.freeze

  def initialize(label = nil, tone: :neutral, mono: false, title: nil, data: nil)
    @label, @tone, @mono, @title, @data = label, tone, mono, title, data
  end

  def call
    tag.span (content.presence || @label), title: @title, data: @data,
      class: classes("inline-flex items-center gap-1 rounded-sm px-1.5 py-0.5 text-xs font-medium whitespace-nowrap", TONES.fetch(@tone), ("font-mono" if @mono))
  end
end
