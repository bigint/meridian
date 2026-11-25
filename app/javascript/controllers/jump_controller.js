import { Controller } from "@hotwired/stimulus"

// The menu: type to go anywhere; Enter opens the first match.
export default class extends Controller {
  static targets = [ "input", "form" ]

  toggled(event) {
    if (event.newState !== "open") return
    this.inputTarget.value = ""
    this.#results.replaceChildren()
    this.inputTarget.focus()
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      if (this.inputTarget.value.trim()) this.formTarget.requestSubmit()
      else this.#results.replaceChildren()
    }, 120)
  }

  key(event) {
    if (event.key !== "Enter" || event.target !== this.inputTarget) return
    const first = this.#results.querySelector("a")
    if (first) { event.preventDefault(); first.click() }
  }

  get #results() {
    return this.element.querySelector("#jump_results")
  }
}
