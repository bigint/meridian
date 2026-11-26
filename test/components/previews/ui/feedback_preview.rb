# Alerts, empty states and the getting-started steps.
class Ui::FeedbackPreview < ViewComponent::Preview
  # @param tone select { choices: [ info, ok, warn, bad ] }
  def alert(tone: :info)
    render(Ui::AlertComponent.new(tone: tone.to_sym, title: "Deploy started")) { "CI picks up the commit in a few seconds." }
  end

  def empty_state
    render_with_template
  end

  def steps
    render Ui::StepsComponent.new(steps: [
      { title: "Connect a repository", detail: "Meridian reads its Kamal configs.", href: "#", done: true },
      { title: "Install the agent", detail: "Each server reports its containers.", href: "#", done: false },
      { title: "Ship a version", detail: "Commit a tag; CI deploys it.", href: "#", done: false }
    ])
  end

  def disclosure
    render(Ui::DisclosureComponent.new(summary: "Filters")) { "Folded away until asked for." }
  end
end
