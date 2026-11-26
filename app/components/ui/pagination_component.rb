class Ui::PaginationComponent < ApplicationComponent
  def initialize(label:, previous_url: nil, next_url: nil, previous_label: "Previous", next_label: "Next")
    @label, @previous_url, @next_url, @previous_label, @next_label = label, previous_url, next_url, previous_label, next_label
  end

  def render? = @previous_url || @next_url

  def call
    tag.nav class: "flex items-center justify-between gap-3 text-sm", aria: { label: "Pages" } do
      safe_join([
        (@previous_url ? render(Ui::ButtonComponent.new(label: "← #{@previous_label}", href: @previous_url, size: :sm)) : tag.span),
        tag.span(@label, class: "text-xs text-ink-muted"),
        (@next_url ? render(Ui::ButtonComponent.new(label: "#{@next_label} →", href: @next_url, size: :sm)) : tag.span)
      ])
    end
  end
end
