import { Controller } from "@hotwired/stimulus"

// Copies a code block's text and says so on the button for a moment.
export default class extends Controller {
  static targets = [ "source", "button" ]

  async copy() {
    await navigator.clipboard.writeText(this.sourceTarget.textContent)
    const label = this.buttonTarget.textContent
    this.buttonTarget.textContent = "Copied"
    setTimeout(() => this.buttonTarget.textContent = label, 1500)
  }
}
