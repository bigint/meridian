# Every form gets Meridian's input styles without per-form markup, and a
# field helper for the label, input, hint and errors together:
#
#   <%= form.field :name, hint: "Lowercase." %>
#   <%= form.field :kind do %><%= form.select :kind, App::KINDS %><% end %>
#
# Pass compact: true for dense inline forms such as filters.
class MeridianFormBuilder < ActionView::Helpers::FormBuilder
  INPUT = "block w-full rounded-md border border-line bg-canvas px-2.5 text-ink placeholder:text-ink-faint " \
    "focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/25 disabled:opacity-60"
  SIZES = { regular: "h-9 text-sm", compact: "h-8 text-xs" }.freeze

  %i[ text_field email_field password_field number_field search_field url_field date_field ].each do |name|
    define_method(name) do |method, options = {}|
      super(method, style(options, max: "max-w-md"))
    end
  end

  def text_area(method, options = {})
    options = options.merge(class: [ INPUT, "max-w-2xl py-2 font-mono text-xs min-h-32", options[:class] ].compact.join(" "))
    super(method, options)
  end

  def select(method, choices = nil, options = {}, html_options = {}, &block)
    multiple = html_options[:multiple]
    super(method, choices, options, style(html_options, max: "max-w-md", extra: (multiple ? "h-auto py-1 min-h-40" : "pr-8")), &block)
  end

  def check_box(method, options = {}, checked_value = "1", unchecked_value = "0")
    super(method, options.merge(class: [ "size-4 rounded border-line accent-accent", options[:class] ].compact.join(" ")), checked_value, unchecked_value)
  end

  def radio_button(method, value, options = {})
    super(method, value, options.merge(class: [ "size-4 border-line accent-accent", options[:class] ].compact.join(" ")))
  end

  def label(method, text = nil, options = {}, &block)
    text, options = nil, text if text.is_a?(Hash)
    options = options.merge(class: [ "mb-1 block text-xs font-medium text-ink-muted", options[:class] ].compact.join(" "))
    super(method, text, options, &block)
  end

  def submit(value = nil, options = {})
    value, options = nil, value if value.is_a?(Hash)
    variant = options.delete(:variant) || :primary
    css = [ "inline-flex h-8 items-center rounded-md px-3 text-sm font-medium cursor-pointer", Ui::ButtonComponent::VARIANTS.fetch(variant), options[:class] ].compact.join(" ")
    super(value, options.merge(class: css))
  end

  # Label, input (or the block), hint and errors.
  def field(method, label: nil, hint: nil, **options, &block)
    input = block ? @template.capture(&block) : text_field(method, options)
    errors = object.respond_to?(:errors) ? object.errors[method] : []
    @template.tag.div(class: "space-y-1") do
      @template.safe_join([
        self.label(method, label),
        input,
        (@template.tag.p(hint, class: "text-xs text-ink-muted") if hint),
        (@template.tag.p(errors.to_sentence, class: "text-xs text-bad") if errors.any?)
      ].compact)
    end
  end

  private
    def style(options, max:, extra: nil)
      size = options.delete(:compact) ? :compact : :regular
      options.merge(class: [ INPUT, SIZES.fetch(size), (size == :compact ? "w-auto" : max), extra, options[:class] ].compact.join(" "))
    end
end
