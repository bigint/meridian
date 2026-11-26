class Ui::PageHeaderComponentPreview < ViewComponent::Preview
  def default
    render Ui::PageHeaderComponent.new(title: "Servers", subtitle: "21 servers in 14 places")
  end

  def with_actions_and_tabs
    render_with_template
  end
end
