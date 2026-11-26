require "test_helper"

class Ui::FeedbackTest < ViewComponent::TestCase
  test "a bad alert is announced as an alert" do
    render_inline(Ui::AlertComponent.new(tone: :bad, title: "Sync failed")) { "Check the token." }
    assert_selector "[role=alert]", text: "Sync failed"
  end

  test "other alerts are status messages" do
    render_inline(Ui::AlertComponent.new(tone: :ok)) { "Saved." }
    assert_selector "[role=status]", text: "Saved."
  end

  test "an empty state with an action" do
    render_inline Ui::EmptyStateComponent.new(title: "No apps yet") do |empty|
      empty.with_action { "Add a project" }
      "Connect a repository."
    end
    assert_text "No apps yet"
    assert_text "Connect a repository."
    assert_text "Add a project"
  end

  test "steps tick themselves off" do
    render_inline Ui::StepsComponent.new(steps: [
      { title: "Connect", detail: "a", href: "/projects/new", done: true },
      { title: "Install", detail: "b", href: "/agents", done: false }
    ])
    assert_selector "li", count: 2
    assert_no_link "Connect"
    assert_link "Install", href: "/agents"
    assert_text "✓"
  end

  test "a disclosure starts closed unless asked" do
    render_inline(Ui::DisclosureComponent.new(summary: "Filters")) { "inside" }
    assert_selector "details:not([open]) summary", text: "Filters"

    render_inline(Ui::DisclosureComponent.new(summary: "Filters", open: true)) { "inside" }
    assert_selector "details[open]"
  end
end
