require "test_helper"

class Ui::NavigationTest < ViewComponent::TestCase
  ITEMS = [ [ "General", "/settings", true ], [ "People", "/settings/users", false ] ].freeze

  test "tabs mark the current page" do
    render_inline Ui::TabsComponent.new(label: "Settings", items: ITEMS)
    assert_selector "nav[aria-label=Settings] a[aria-current=page]", text: "General"
    assert_selector "a:not([aria-current])", text: "People"
  end

  test "a segmented control marks the current view" do
    render_inline Ui::SegmentedControlComponent.new(label: "Arrange", items: ITEMS)
    assert_selector "nav[aria-label=Arrange] a[aria-current=true]", text: "General"
  end

  test "pagination renders only when there is another page" do
    render_inline Ui::PaginationComponent.new(label: "1–50 of 51", next_url: "/apps?page=2")
    assert_link "Next →", href: "/apps?page=2"

    render_inline Ui::PaginationComponent.new(label: "1–5 of 5")
    assert_no_selector "nav"
  end
end
