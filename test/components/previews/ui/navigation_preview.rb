# Segmented controls switch views of the same thing; tabs move between pages.
class Ui::NavigationPreview < ViewComponent::Preview
  def segmented_control
    render Ui::SegmentedControlComponent.new(label: "Arrange", items: [ [ "Apps × servers", "#", true ], [ "Servers × apps", "#", false ] ])
  end

  def tabs
    render Ui::TabsComponent.new(label: "Settings", items: [ [ "General", "#", true ], [ "People", "#", false ], [ "Jobs", "#", false ] ])
  end

  def pagination
    render Ui::PaginationComponent.new(label: "Apps 1–50 of 120", next_url: "#", next_label: "Next 50")
  end
end
