class Ui::BadgeComponentPreview < ViewComponent::Preview
  # @param label text
  # @param tone select { choices: [ neutral, accent, ok, warn, bad, info ] }
  # @param mono toggle
  def playground(label: "web", tone: :neutral, mono: false)
    render Ui::BadgeComponent.new(label, tone: tone.to_sym, mono: mono)
  end

  def tones
    render_with_template
  end
end
