# A drift state, always as a symbol and a word: never colour alone.
class Ui::StateComponent < ApplicationComponent
  TONES = { "in_sync" => :ok, "drifted" => :warn, "missing" => :bad, "stray" => :info, "stale" => :neutral, "unknown" => :neutral }.freeze

  def initialize(state)
    @state = state
  end

  def call
    return tag.span("–", class: "text-ink-faint", title: "Nothing here") unless @state

    render Ui::BadgeComponent.new(tone: TONES.fetch(@state), data: { state: @state }) do
      safe_join([ tag.span(Drift::SYMBOLS[@state], aria: { hidden: true }), Drift::LABELS[@state] ], " ")
    end
  end
end
