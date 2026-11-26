// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Live pages morph to the server's HTML on every refresh. What the person
// has done there is their state, not the server's: a <details> they opened
// or closed, and a field they are typing in or have changed but not sent.
// Turbo's morph would otherwise put every field back to the server's value.
// Once a form is sent, though, what it said is the server's: a submission
// that redirects back to this page morphs it too, and its fields take what
// the server now says (an emptied box, a saved value), not what was typed.
const edited = field =>
  field === document.activeElement ||
  (field instanceof HTMLOptionElement ? field.selected !== field.defaultSelected
    : field.type === "checkbox" || field.type === "radio" ? field.checked !== field.defaultChecked
    : field.value !== field.defaultValue)

// Forms sent and answered with this same page, until that page has rendered.
let sent = new WeakSet()

addEventListener("turbo:submit-end", ({ target, detail: { success, fetchResponse } }) => {
  if (success && fetchResponse?.redirected && fetchResponse.location.href === location.href) sent.add(target)
})
addEventListener("turbo:load", () => { sent = new WeakSet() })

addEventListener("turbo:before-morph-attribute", event => {
  const { target, detail: { attributeName } } = event
  if (target instanceof HTMLDetailsElement && attributeName === "open") event.preventDefault()
  if ([ "value", "checked", "selected" ].includes(attributeName) && target.matches("input, textarea, option") &&
    !sent.has(target.form) && edited(target)) event.preventDefault()
})

// The search's results answer what was typed, which the refreshed page doesn't know.
addEventListener("turbo:before-morph-element", event => {
  if (event.target.id === "jump_results") event.preventDefault()
})
