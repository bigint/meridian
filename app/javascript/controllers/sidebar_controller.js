import { Controller } from "@hotwired/stimulus"

// Collapses the sidebar to its icon rail and back. The choice is a cookie,
// so the server renders the same width on the next page with no flicker.
export default class extends Controller {
  static targets = [ "toggle", "label" ]

  toggle() {
    const collapsed = !this.element.hasAttribute("data-collapsed")
    const label = collapsed ? "Expand sidebar" : "Collapse sidebar"

    this.element.toggleAttribute("data-collapsed", collapsed)
    document.cookie = `sidebar=${collapsed ? "collapsed" : "expanded"}; path=/; max-age=31536000; SameSite=Lax`

    this.toggleTarget.setAttribute("aria-expanded", String(!collapsed))
    this.toggleTarget.setAttribute("aria-label", label)
    this.toggleTarget.title = label
    this.labelTarget.textContent = label
  }
}
