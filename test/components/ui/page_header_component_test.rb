require "test_helper"

class Ui::PageHeaderComponentTest < ViewComponent::TestCase
  test "title and subtitle" do
    render_inline Ui::PageHeaderComponent.new(title: "Servers", subtitle: "21 servers")
    assert_selector "h1", text: "Servers"
    assert_text "21 servers"
  end

  test "actions and tabs" do
    render_inline Ui::PageHeaderComponent.new(title: "Settings") do |header|
      header.with_actions { "Add person" }
      header.with_tabs { "General" }
    end
    assert_text "Add person"
    assert_text "General"
  end
end
