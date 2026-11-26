require "test_helper"

class Ui::ListComponentTest < ViewComponent::TestCase
  test "items with leading, subtitle and trailing parts" do
    render_inline Ui::ListComponent.new do |list|
      list.with_item(title: "web is drifted", href: "/apps/1") do |item|
        item.with_subtitle { "on 2 servers" }
        item.with_trailing { "Redeploy" }
      end
      list.with_item(title: "api deployed")
    end

    assert_selector "ul > li", count: 2
    assert_link "web is drifted", href: "/apps/1"
    assert_text "on 2 servers"
    assert_text "Redeploy"
  end
end
