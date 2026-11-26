import { Controller } from "@hotwired/stimulus"

// Copies a code block's text and says so on the button for a moment. Over
// plain HTTP (not localhost) browsers have no clipboard API: the text is
// selected instead, so ⌘C or Ctrl+C copies it.
export default class extends Controller {
  static targets = [ "source", "button", "label" ]

  disconnect() {
    clearTimeout(this.timer)
  }

  async copy() {
    let copied = false
    try {
      await navigator.clipboard.writeText(this.sourceTarget.textContent)
      copied = true
    } catch {
      getSelection().selectAllChildren(this.sourceTarget)
    }
    this.#say(copied ? "Copied" : "Selected: press ⌘C or Ctrl+C", copied)
  }

  #say(text, copied) {
    this.buttonTarget.toggleAttribute("data-copied", copied)
    this.labelTarget.textContent = text
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.buttonTarget.toggleAttribute("data-copied", false)
      this.labelTarget.textContent = "Copy"
    }, copied ? 1500 : 4000)
  }
}
