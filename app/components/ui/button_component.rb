# Buttons and button-shaped links. One primary per view.
#
#   render Ui::ButtonComponent.new(label: "Deploy", variant: :primary)
#   render Ui::ButtonComponent.new(label: "Open", href: app_path(app))
#   render Ui::ButtonComponent.new(label: "Roll back", href: path, method: :post, confirm: "Sure?", variant: :danger)
class Ui::ButtonComponent < ApplicationComponent
  VARIANTS = {
    primary: "bg-accent text-accent-ink hover:bg-accent-strong",
    secondary: "border border-line bg-canvas text-ink hover:bg-raised",
    ghost: "text-ink-muted hover:bg-raised hover:text-ink",
    danger: "border border-line bg-canvas text-bad hover:bg-bad-soft"
  }.freeze
  SIZES = { sm: "h-7 gap-1 px-2.5 text-xs", md: "h-8 gap-1.5 px-3 text-sm" }.freeze

  def initialize(label: nil, variant: :secondary, size: :md, href: nil, method: nil, confirm: nil, icon: nil, type: :button, **html)
    @label, @variant, @size, @href, @method, @confirm, @icon, @type, @html = label, variant, size, href, method, confirm, icon, type, html
  end

  def call
    css, data = self.css, @html.delete(:data) || {}
    confirm = { turbo_confirm: @confirm }.compact

    if @href && @method
      button_to @href, method: @method, class: css, data: data, form: { class: "inline", data: confirm }, **@html do
        body
      end
    elsif @href
      link_to body, @href, class: css, data: data.merge(confirm), **@html
    else
      tag.button body, type: @type, class: css, data: data.merge(confirm), **@html
    end
  end

  protected
    def css
      classes("inline-flex items-center justify-center whitespace-nowrap rounded-md font-medium transition-colors",
        "disabled:pointer-events-none disabled:opacity-50 cursor-pointer", SIZES.fetch(@size), VARIANTS.fetch(@variant), @html.delete(:class))
    end

  private
    def body
      safe_join([ (helpers.icon(@icon, class: "size-4 shrink-0") if @icon), (content.presence || @label) ].compact)
    end
end
