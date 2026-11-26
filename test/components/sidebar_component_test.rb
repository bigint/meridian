require "test_helper"

class SidebarComponentTest < ViewComponent::TestCase
  test "the search box uses Meridian's form styles" do
    with_request_url("/") { render_inline SidebarComponent.new(user: users(:viewer)) }
    assert_selector "input[type=search][name=q].rounded-md"
    assert_selector "label.sr-only", text: "Search apps, servers and projects"
  end

  test "admins see Settings and Jobs; viewers don't" do
    with_request_url("/") { render_inline SidebarComponent.new(user: users(:admin), attention_count: 3) }
    assert_link "Settings"
    assert_link "Jobs"
    assert_selector "a[aria-current=page]", text: "Board"
    assert_text "3"

    with_request_url("/") { render_inline SidebarComponent.new(user: users(:viewer)) }
    assert_no_link "Settings"
  end
end
