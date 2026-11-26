import { Controller } from "@hotwired/stimulus"

// Links inside an <svg> have an SVGAnimatedString href, which Turbo's click
// handling can't read. Handle the click here so Turbo never sees it, and
// visit the link through Turbo as usual.
export default class extends Controller {
  visit(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button > 0) return
    event.preventDefault()
    event.stopPropagation()
    Turbo.visit(this.element.getAttribute("href"))
  }
}
