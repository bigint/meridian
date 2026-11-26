// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Live pages morph to the server's HTML on every refresh. A <details> the
// person opened or closed is their state, not the server's: keep it.
addEventListener("turbo:before-morph-attribute", event => {
  if (event.target instanceof HTMLDetailsElement && event.detail.attributeName === "open") event.preventDefault()
})
