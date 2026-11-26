require "test_helper"

class TopbarComponentTest < ViewComponent::TestCase
  test "the search box uses Meridian's form styles" do
    with_request_url("/") { render_inline TopbarComponent.new(user: users(:viewer)) }
    assert_selector "input[type=search][name=q].rounded-md"
    assert_selector "label.sr-only", text: "Search apps, servers and projects"
  end

  test "the account menu names the person and signs out" do
    with_request_url("/") { render_inline TopbarComponent.new(user: users(:viewer)) }
    assert_selector "button[popovertarget=account][aria-label='Account: #{users(:viewer).display_name}']"
    assert_selector "#account[popover] form[action='/session'] button", text: "Sign out"
  end
end
