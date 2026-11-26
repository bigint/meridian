import { Controller } from "@hotwired/stimulus"

const DELAY = 400  // ms of hovering before a tooltip shows
const WARM = 300   // ms after one hides in which the next shows at once
const GAP = 6      // px between the tooltip and what it describes
const GUTTER = 8   // px kept clear of the viewport's edges

// One tooltip for the whole page: any element with data-tooltip="text" gets
// it on hover and on keyboard focus. It is a popover, so it sits in the top
// layer and no scrolling container clips it. CSS can switch an element's
// tooltip off with --tooltip: off, where its text is already on screen, and
// put it beside the element with --tooltip-side: right.
export default class extends Controller {
  static targets = [ "tip" ]

  connect() {
    this.hide = this.hide.bind(this)
    this.recheck = this.recheck.bind(this)
    this.escape = event => { if (event.key === "Escape") this.hide() }
    this.swap = event => { if (event.detail.renderMethod !== "morph") this.hide() }
    this.scrolled = () => { if (this.trigger) this.hide() } // one still waiting measures where it is when it shows
    this.listeners = [
      [ "keydown", this.escape ], [ "scroll", this.scrolled, { capture: true, passive: true } ],
      [ "turbo:before-cache", this.hide ], [ "turbo:before-render", this.swap ],
      [ "turbo:morph", this.recheck ], [ "turbo:frame-render", this.recheck ]
    ]
    for (const [ name, listener, options ] of this.listeners) document.addEventListener(name, listener, options)
  }

  disconnect() {
    this.hide()
    for (const [ name, listener, options ] of this.listeners) document.removeEventListener(name, listener, options)
  }

  // pointerover
  enter(event) {
    if (event.pointerType === "touch") return
    const trigger = this.triggerFor(event)
    if (!trigger || trigger === this.trigger || trigger === this.pending) return

    this.hide()
    const point = trigger instanceof SVGElement ? { x: event.clientX, y: event.clientY } : null
    const warm = performance.now() - (this.hiddenAt ?? -Infinity) < WARM
    this.timer = setTimeout(() => this.show(trigger, point), warm ? 0 : DELAY)
    this.pending = trigger
  }

  // pointerout
  leave(event) {
    const trigger = this.pending || this.trigger
    if (trigger?.contains(event.target) && !trigger.contains(event.relatedTarget)) this.hide()
  }

  // focusin
  focus(event) {
    const trigger = this.triggerFor(event)
    if (trigger && event.target.matches(":focus-visible")) {
      this.hide()
      this.show(trigger)
    }
  }

  // focusout
  blur(event) {
    if (this.trigger?.contains(event.target)) this.hide()
  }

  hide() {
    clearTimeout(this.timer)
    this.pending = null
    if (!this.trigger) return

    this.observer?.disconnect()
    this.describe(this.trigger, false)
    this.trigger = null
    this.hiddenAt = performance.now()
    if (this.tipTarget.matches(":popover-open")) this.tipTarget.hidePopover()
  }

  // A live refresh may have replaced or moved what the tooltip describes.
  recheck() {
    if (!this.trigger) return
    if (this.trigger.isConnected && this.trigger.dataset.tooltip) this.place(this.tipTarget, this.trigger, this.point)
    else this.hide()
  }

  triggerFor(event) {
    const trigger = event.target.closest?.("[data-tooltip]")
    if (!trigger || !trigger.dataset.tooltip) return null
    if (getComputedStyle(trigger).getPropertyValue("--tooltip").trim() === "off") return null
    return trigger
  }

  show(trigger, point = null) {
    this.pending = null
    if (!trigger.isConnected) return

    const tip = this.tipTarget
    tip.textContent = trigger.dataset.tooltip
    tip.showPopover()
    this.place(tip, trigger, point)
    this.trigger = trigger
    this.point = point
    this.describe(trigger, true)
    this.follow(trigger, point)
  }

  // Live numbers and toggles change their text while it is showing.
  follow(trigger, point) {
    this.observer = new MutationObserver(() => {
      if (!trigger.dataset.tooltip) return this.hide()
      this.tipTarget.textContent = trigger.dataset.tooltip
      this.place(this.tipTarget, trigger, point)
    })
    this.observer.observe(trigger, { attributeFilter: [ "data-tooltip" ] })
  }

  // Above what it describes, or below when there is no room (or to its
  // right, if CSS asks); never past an edge.
  place(tip, trigger, point) {
    const anchor = point ? { left: point.x, right: point.x, top: point.y, bottom: point.y } : trigger.getBoundingClientRect()
    const { width, height } = tip.getBoundingClientRect()
    const clamp = (value, size, room) => Math.min(Math.max(value, GUTTER), room - GUTTER - size)
    let left, top

    if (getComputedStyle(trigger).getPropertyValue("--tooltip-side").trim() === "right") {
      left = anchor.right + GAP
      top = (anchor.top + anchor.bottom) / 2 - height / 2
    } else {
      left = (anchor.left + anchor.right) / 2 - width / 2
      top = anchor.top - GAP - height
      if (top < GUTTER) top = anchor.bottom + GAP
    }

    tip.style.left = `${Math.round(clamp(left, width, window.innerWidth))}px`
    tip.style.top = `${Math.round(clamp(top, height, window.innerHeight))}px`
  }

  // Screen readers hear the tooltip as a description, unless it only repeats
  // the element's name.
  describe(trigger, on) {
    if (on && trigger.getAttribute("aria-label") === trigger.dataset.tooltip) return
    const id = this.tipTarget.id
    const ids = (trigger.getAttribute("aria-describedby") || "").split(" ").filter(other => other && other !== id)
    if (on) ids.push(id)
    if (ids.length) trigger.setAttribute("aria-describedby", ids.join(" "))
    else trigger.removeAttribute("aria-describedby")
  }
}
