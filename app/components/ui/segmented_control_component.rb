# Two to four mutually exclusive views of the same thing.
#   Ui::SegmentedControlComponent.new(items: [ [ "Apps × servers", url, true ], … ], label: "Arrange")
class Ui::SegmentedControlComponent < ApplicationComponent
  def initialize(items:, label:)
    @items, @label = items, label
  end

  def call
    tag.nav class: "inline-flex rounded-md border border-line bg-surface p-0.5", aria: { label: @label } do
      safe_join(@items.map do |text, href, current|
        link_to text, href, aria: { current: (current ? "true" : nil) },
          class: classes("rounded-sm px-2.5 py-1 text-xs font-medium", current ? "bg-canvas text-ink ring-1 ring-line" : "text-ink-muted hover:text-ink")
      end)
    end
  end
end
