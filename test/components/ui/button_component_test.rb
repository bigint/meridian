require "test_helper"

class Ui::ButtonComponentTest < ViewComponent::TestCase
  test "a plain button" do
    render_inline Ui::ButtonComponent.new(label: "Deploy", variant: :primary)
    assert_selector "button[type=button]", text: "Deploy"
  end

  test "a link when given an href" do
    render_inline Ui::ButtonComponent.new(label: "Open", href: "/apps")
    assert_selector "a[href='/apps']", text: "Open"
    assert_no_selector "button"
  end

  test "a form button with a confirmation when given a method" do
    render_inline Ui::ButtonComponent.new(label: "Roll back", href: "/apps/1/rollbacks", method: :post, confirm: "Sure?", variant: :danger)
    assert_selector "form[action='/apps/1/rollbacks'][data-turbo-confirm='Sure?'] button", text: "Roll back"
  end

  test "an icon before the label" do
    render_inline Ui::ButtonComponent.new(label: "New app", icon: :plus)
    assert_selector "button svg"
    assert_text "New app"
  end

  test "an unknown variant is an error" do
    assert_raises(KeyError) { render_inline Ui::ButtonComponent.new(label: "x", variant: :loud) }
  end
end
