# Something folded away until asked for: filters, configuration, more items.
class Ui::DisclosureComponent < ApplicationComponent
  def initialize(summary:, open: false)
    @summary, @open = summary, open
  end

  def call
    tag.details class: "group", open: @open do
      tag.summary(class: "inline-flex cursor-pointer select-none list-none items-center gap-1 text-xs font-medium text-ink-muted hover:text-ink [&::-webkit-details-marker]:hidden") do
        helpers.icon(:chevron, class: "size-3.5 -rotate-90 transition-transform group-open:rotate-0") + @summary
      end + tag.div(content, class: "mt-3")
    end
  end
end
