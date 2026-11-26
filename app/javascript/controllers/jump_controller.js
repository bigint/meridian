import { Controller } from "@hotwired/stimulus"

// Sidebar search: results appear as you type; Enter opens the first match.
// Results come back late, so each one says what it answers (data-query):
// Enter only opens a match for what the box says now, waiting for it if it
// is still on its way, and an answer to an older query is never drawn.
export default class extends Controller {
  static targets = [ "input", "form" ]

  disconnect() {
    clearTimeout(this.timer)
  }

  search() {
    this.opening = false
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.#submit(), 120)
  }

  key(event) {
    if (event.key === "Escape") {
      clearTimeout(this.timer)
      this.opening = false
      this.inputTarget.value = ""
      this.#results.replaceChildren()
    }
    if (event.key !== "Enter" || event.isComposing) return

    event.preventDefault()
    if (this.#answered) {
      this.#openFirst()
    } else if (this.inputTarget.value.trim()) {
      clearTimeout(this.timer)
      this.opening = true
      this.#submit()
    }
  }

  // turbo:before-frame-render on the results
  render(event) {
    if (this.#queryOf(event.detail.newFrame) !== this.inputTarget.value) event.detail.render = () => {}
  }

  // turbo:frame-load on the results
  loaded() {
    if (!this.opening || !this.#answered) return
    this.opening = false
    this.#openFirst()
  }

  #submit() {
    if (this.inputTarget.value.trim()) this.formTarget.requestSubmit()
    else this.#results.replaceChildren()
  }

  #openFirst() {
    this.#results.querySelector("a")?.click()
  }

  get #answered() {
    return this.#queryOf(this.#results) === this.inputTarget.value
  }

  #queryOf(frame) {
    return frame.querySelector("[data-query]")?.dataset.query
  }

  get #results() {
    return this.element.querySelector("#jump_results")
  }
}
