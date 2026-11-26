require "test_helper"

class Ui::MiscTest < ViewComponent::TestCase
  test "avatar initials are stable and hidden from screen readers" do
    render_inline Ui::AvatarComponent.new(name: "Ana Lima")
    assert_selector "span[aria-hidden]", text: "AL"
    first = page.find("span")[:class]

    render_inline Ui::AvatarComponent.new(name: "Ana Lima")
    assert_equal first, page.find("span")[:class]
  end

  test "a state avatar shows the state's symbol" do
    render_inline Ui::AvatarComponent.new(state: "missing")
    assert_text Drift::SYMBOLS["missing"]
  end

  test "a code block has a copy button wired to the clipboard controller" do
    render_inline Ui::CodeBlockComponent.new(code: "kamal deploy", label: "shell")
    assert_selector "[data-controller=clipboard] button[data-action='clipboard#copy']", text: "Copy"
    assert_selector "pre code[data-clipboard-target=source]", text: "kamal deploy"
  end

  test "a description list pairs terms and values" do
    render_inline Ui::DescriptionListComponent.new do |list|
      list.with_item("Host") { "10.0.4.12" }
    end
    assert_selector "dt", text: "Host"
    assert_selector "dd", text: "10.0.4.12"
  end

  test "a stat can be a current filter link" do
    render_inline Ui::StatComponent.new(label: "Drifted", value: 2, state: "drifted", href: "/?state=drifted", current: true)
    assert_selector "a[href='/?state=drifted'][aria-current=true]", text: "2"
  end
end
