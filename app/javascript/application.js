// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Live pages morph to the server's HTML on every refresh. What the person
// has done there is their state, not the server's: a <details> they opened
// or closed, and a field they are typing in or have changed but not sent.
// Turbo's morph would otherwise put every field back to the server's value.
const edited = field =>
  field === document.activeElement ||
  (field instanceof HTMLOptionElement ? field.selected !== field.defaultSelected
    : field.type === "checkbox" || field.type === "radio" ? field.checked !== field.defaultChecked
    : field.value !== field.defaultValue)

addEventListener("turbo:before-morph-attribute", event => {
  const { target, detail: { attributeName } } = event
  if (target instanceof HTMLDetailsElement && attributeName === "open") event.preventDefault()
  if ([ "value", "checked", "selected" ].includes(attributeName) && target.matches("input, textarea, option") && edited(target)) event.preventDefault()
})

// The search's results answer what was typed, which the refreshed page doesn't know.
addEventListener("turbo:before-morph-element", event => {
  if (event.target.id === "jump_results") event.preventDefault()
})
