# A short checklist that ticks itself off: getting started.
#   Ui::StepsComponent.new(steps: [ { title:, detail:, href:, done: } ])
class Ui::StepsComponent < ApplicationComponent
  def initialize(steps:)
    @steps = steps
  end

  def call
    tag.ol class: "grid gap-2 sm:grid-cols-3" do
      safe_join(@steps.each_with_index.map do |step, index|
        tag.li class: classes("flex gap-3 rounded-lg border p-3", step[:done] ? "border-line bg-surface" : "border-accent/40") do
          tag.span((step[:done] ? "✓" : index + 1).to_s, class: classes("grid size-6 shrink-0 place-items-center rounded-full text-xs font-semibold", step[:done] ? "bg-ok-soft text-ok" : "bg-accent text-accent-ink")) +
            tag.div do
              title = step[:done] ? tag.span(step[:title], class: "text-ink-muted line-through") : link_to(step[:title], step[:href], class: "font-medium text-ink hover:underline")
              title + tag.p(step[:detail], class: "mt-0.5 text-xs text-ink-muted")
            end
        end
      end)
    end
  end
end
