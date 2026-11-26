require "test_helper"

class Ui::SectionComponentTest < ViewComponent::TestCase
  test "a labelled section with a count" do
    render_inline(Ui::SectionComponent.new(title: "Releases", count: 3, id: "releases")) { "body" }
    assert_selector "section[aria-labelledby=releases] h2#releases", text: "Releases"
    assert_selector "h2", text: "3"
    assert_text "body"
  end
end
