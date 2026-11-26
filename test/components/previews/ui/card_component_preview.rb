# A bordered surface. Meridian uses no shadows.
class Ui::CardComponentPreview < ViewComponent::Preview
  def default
    render(Ui::CardComponent.new(title: "Where Meridian runs")) { "The centre of the map's flows." }
  end

  def with_footer
    render_with_template
  end
end
