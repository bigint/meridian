# A message in the flow of the page: notices, errors, one-time secrets.
class Ui::AlertComponent < ApplicationComponent
  TONES = {
    info: "border-accent/30 bg-accent-soft", ok: "border-ok/30 bg-ok-soft", warn: "border-warn/30 bg-warn-soft",
    bad: "border-bad/30 bg-bad-soft"
  }.freeze
  ICONS = { info: "ⓘ", ok: "✓", warn: "!", bad: "✕" }.freeze
  TEXT = { info: "text-accent-strong", ok: "text-ok", warn: "text-warn", bad: "text-bad" }.freeze

  def initialize(tone: :info, title: nil, role: nil)
    @tone, @title, @role = tone, title, role || (tone == :bad ? "alert" : "status")
  end

  def call
    tag.div class: classes("flex gap-2.5 rounded-md border px-3 py-2.5 text-sm text-ink", TONES.fetch(@tone)), role: @role do
      tag.span(ICONS.fetch(@tone), class: classes("font-semibold", TEXT.fetch(@tone)), aria: { hidden: true }) +
        tag.div(class: "min-w-0 space-y-1") { safe_join([ (tag.p(@title, class: "font-medium") if @title), content ].compact) }
    end
  end
end
