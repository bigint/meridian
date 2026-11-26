# Initials on a soft colour that stays the same for the same name, or a drift
# state's symbol when the avatar stands for a problem.
class Ui::AvatarComponent < ApplicationComponent
  PALETTE = [ "bg-accent-soft text-accent-strong", "bg-info-soft text-info", "bg-warn-soft text-warn", "bg-ok-soft text-ok", "bg-mute-soft text-mute" ].freeze
  STATES = { "missing" => "bg-bad-soft text-bad", "drifted" => "bg-warn-soft text-warn", "stray" => "bg-info-soft text-info", "stale" => "bg-mute-soft text-mute" }.freeze
  SIZES = { sm: "size-6 text-[10px]", md: "size-8 text-xs" }.freeze

  def initialize(name: nil, state: nil, size: :md)
    @name, @state, @size = name.to_s, state, size
  end

  def call
    text, tone = @state ? [ Drift::SYMBOLS[@state], STATES.fetch(@state, PALETTE.last) ] : [ initials, PALETTE[Zlib.crc32(@name) % PALETTE.size] ]
    tag.span text, class: classes("inline-grid shrink-0 place-items-center rounded-full font-semibold", SIZES.fetch(@size), tone), aria: { hidden: true }
  end

  private
    def initials
      words = @name.scan(/[[:alnum:]]+/)
      (words.size > 1 ? words.first(2).map { it[0] }.join : words.first.to_s[0, 2]).upcase.presence || "?"
    end
end
