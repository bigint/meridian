import { Controller } from "@hotwired/stimulus"

// Collapses the sidebar to its icon rail and back. The choice is a cookie,
// so the server renders the same width on the next page with no flicker.
export default class extends Controller {
  toggle() {
    const collapsed = !this.element.hasAttribute("data-collapsed")
    this.element.toggleAttribute("data-collapsed", collapsed)
    document.cookie = `sidebar=${collapsed ? "collapsed" : "expanded"}; path=/; max-age=31536000; SameSite=Lax`
    this.element.querySelectorAll("[data-sidebar-toggle]").forEach(button => button.setAttribute("aria-expanded", String(!collapsed)))
    // The button just pressed hides itself; keep keyboard focus on its twin.
    this.element.querySelector(`[data-sidebar-toggle=${collapsed ? "expand" : "collapse"}]`)?.focus()
  }
}
