require "test_helper"

class Ui::BadgeComponentTest < ViewComponent::TestCase
  test "a label" do
    render_inline Ui::BadgeComponent.new("fleet", tone: :accent)
    assert_selector "span", text: "fleet"
  end

  test "content wins over the label" do
    render_inline(Ui::BadgeComponent.new("ignored")) { "shown" }
    assert_text "shown"
    assert_no_text "ignored"
  end
end
