require "test_helper"

class Ui::StateComponentTest < ViewComponent::TestCase
  test "every state shows a symbol and a word" do
    Drift::STATES.each do |state|
      render_inline Ui::StateComponent.new(state)
      assert_selector "[data-state=#{state}]", text: Drift::LABELS[state]
      assert_selector "[data-state=#{state}] [aria-hidden]", text: Drift::SYMBOLS[state]
    end
  end

  test "no state is a dash" do
    render_inline Ui::StateComponent.new(nil)
    assert_selector "span[title='Nothing here']", text: "–"
  end
end
