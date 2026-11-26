require "test_helper"

class SidebarComponentTest < ViewComponent::TestCase
  test "icons are named for screen readers and the current place is marked" do
    with_request_url("/") { render_inline SidebarComponent.new(user: users(:viewer), attention_count: 3) }
    assert_selector "nav[aria-label=Main] a[aria-current=page][title=Board]", text: "Board"
    assert_selector "a[title=Board] [aria-label='3 things need attention']", text: "3"
  end

  test "admins see Settings and Jobs; viewers don't" do
    with_request_url("/") { render_inline SidebarComponent.new(user: users(:admin)) }
    assert_link "Settings"
    assert_link "Jobs"

    with_request_url("/") { render_inline SidebarComponent.new(user: users(:viewer)) }
    assert_no_link "Settings"
  end
end
