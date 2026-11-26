import { Controller } from "@hotwired/stimulus"

// Copies a code block's text and says so on the button for a moment.
export default class extends Controller {
  static targets = [ "source", "button", "label" ]

  async copy() {
    await navigator.clipboard.writeText(this.sourceTarget.textContent)
    this.buttonTarget.toggleAttribute("data-copied", true)
    this.labelTarget.textContent = "Copied"
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.buttonTarget.toggleAttribute("data-copied", false)
      this.labelTarget.textContent = "Copy"
    }, 1500)
  }
}
