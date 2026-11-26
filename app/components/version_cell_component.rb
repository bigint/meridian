# One app on one server: the version it runs, tinted by its drift state.
# The state is also a word for screen readers and a distinct border, so it
# never rests on colour alone.
class VersionCellComponent < ApplicationComponent
  STYLES = {
    "in_sync" => "border-ok-line bg-ok-soft text-ok",
    "drifted" => "border-warn-line bg-warn-soft text-warn border-[1.5px]",
    "missing" => "border-bad-line bg-bad-soft text-bad border-[1.5px]",
    "stray" => "border-info-line bg-info-soft text-info border-dotted border-[1.5px]",
    "stale" => "border-dashed border-ink-faint bg-raised text-ink-muted",
    "unknown" => "border-dashed border-ink-faint bg-canvas text-ink-muted"
  }.freeze

  def initialize(cell:, href: nil)
    @cell, @href = cell, href
  end

  def call
    label = "#{@cell.app.name} on #{@cell.server.name}: #{Drift::LABELS[@cell.state]}#{", running #{running}" if @cell.versions.any?}"
    body = safe_join([ tag.span("#{Drift::LABELS[@cell.state]}: ", class: "sr-only"), text ])
    css = classes("inline-grid h-6 min-w-11 max-w-24 place-items-center truncate rounded border px-1.5 font-mono text-[10.5px] font-medium", STYLES.fetch(@cell.state))
    data = { cell: true, state: @cell.state }
    @href ? link_to(body, @href, class: css, title: label, data: data) : tag.span(body, class: css, title: label, data: data)
  end

  private
    def running = @cell.versions.join(", ")

    def text
      case @cell.state
      when "missing" then "✕"
      when "unknown" then "?"
      when "drifted" then "≠#{short(@cell.versions.first)}"
      else short(@cell.version) || "–"
      end
    end

    def short(version) = version&.first(10)
end
