# Sub-navigation inside a page: Settings › General, People, Jobs.
class Ui::TabsComponent < ApplicationComponent
  def initialize(items:, label:)
    @items, @label = items, label
  end

  def call
    tag.nav class: "flex gap-4 border-b border-transparent", aria: { label: @label } do
      safe_join(@items.map do |text, href, current|
        link_to text, href, aria: { current: (current ? "page" : nil) },
          class: classes("-mb-px border-b-2 px-0.5 pb-2 text-sm font-medium", current ? "border-accent text-ink" : "border-transparent text-ink-muted hover:text-ink")
      end)
    end
  end
end
