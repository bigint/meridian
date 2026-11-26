import { Controller } from "@hotwired/stimulus"

// Sidebar search: results appear as you type; Enter opens the first match.
export default class extends Controller {
  static targets = [ "input", "form" ]

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      if (this.inputTarget.value.trim()) this.formTarget.requestSubmit()
      else this.#results.replaceChildren()
    }, 120)
  }

  key(event) {
    if (event.key === "Escape") { this.inputTarget.value = ""; this.#results.replaceChildren() }
    if (event.key !== "Enter") return
    const first = this.#results.querySelector("a")
    if (first) { event.preventDefault(); first.click() }
  }

  get #results() {
    return this.element.querySelector("#jump_results")
  }
}
