# Buttons and button-shaped links. One primary per view.
class Ui::ButtonComponentPreview < ViewComponent::Preview
  # @param label text
  # @param variant select { choices: [ primary, secondary, ghost, danger ] }
  # @param size select { choices: [ md, sm ] }
  def playground(label: "Deploy", variant: :primary, size: :md)
    render Ui::ButtonComponent.new(label: label, variant: variant.to_sym, size: size.to_sym)
  end

  def variants
    render_with_template
  end

  def with_icon
    render Ui::ButtonComponent.new(label: "New app", icon: :plus, variant: :primary)
  end

  def link
    render Ui::ButtonComponent.new(label: "Open the board", href: "/")
  end
end
