import { Controller } from "@hotwired/stimulus"

// The menu: type to go anywhere, Enter opens the first match, 1–6 open a tile,
// arrow keys move between links.
export default class extends Controller {
  static targets = [ "input", "form" ]

  toggled(event) {
    if (event.newState !== "open") return
    if (document.activeElement !== this.inputTarget) {
      this.inputTarget.value = ""
      this.#results.replaceChildren()
      this.inputTarget.focus()
    }
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      if (this.inputTarget.value.trim()) this.formTarget.requestSubmit()
      else this.#results.replaceChildren()
    }, 120)
  }

  key(event) {
    if (event.key === "Enter" && event.target === this.inputTarget) {
      const first = this.#results.querySelector("a")
      if (first) { event.preventDefault(); first.click() }
    } else if (/^[1-6]$/.test(event.key) && !this.inputTarget.value) {
      const tile = this.element.querySelector(`[data-number="${event.key}"]`)
      if (tile) { event.preventDefault(); tile.click() }
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      const links = [ this.inputTarget, ...this.element.querySelectorAll("a") ]
      const index = links.indexOf(document.activeElement)
      const next = links[(index + (event.key === "ArrowDown" ? 1 : -1) + links.length) % links.length]
      next.focus()
    }
  }

  get #results() {
    return this.element.querySelector("#jump_results")
  }
}
