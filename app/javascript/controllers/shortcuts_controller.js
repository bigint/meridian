import { Controller } from "@hotwired/stimulus"

// M or ⌘K opens the menu; "g" then a letter jumps to a section; "/" focuses
// the page's filter; "?" shows the shortcuts.
export default class extends Controller {
  static targets = [ "help" ]

  press(event) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault()
      return this.#toggleMenu()
    }
    if (event.metaKey || event.ctrlKey || event.altKey || this.#typing(event.target)) return

    if (this.pending) {
      this.pending = false
      const link = document.querySelector(`#jump [data-shortcut="${event.key}"]`)
      if (link) { event.preventDefault(); link.click() }
    } else if (event.key === "g") {
      this.pending = true
      setTimeout(() => this.pending = false, 1500)
    } else if (event.key === "m" || event.key === "M") {
      event.preventDefault()
      this.#toggleMenu()
    } else if (event.key === "/") {
      const filter = document.querySelector("main [data-filter]")
      if (filter) { event.preventDefault(); filter.focus() }
    } else if (event.key === "?") {
      this.help()
    }
  }

  help() {
    document.getElementById("me")?.hidePopover()
    this.helpTarget?.showModal()
  }

  #toggleMenu() {
    const menu = document.getElementById("jump")
    if (!menu) return
    if (menu.matches(":popover-open")) return menu.hidePopover()

    menu.showPopover()
    const input = menu.querySelector("input[type=search]")
    input.value = ""
    menu.querySelector("#jump_results").replaceChildren()
    input.focus()
  }

  #typing(element) {
    return element.closest("input, textarea, select, [contenteditable]")
  }
}
