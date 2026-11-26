import { Controller } from "@hotwired/stimulus"

// System, light or dark. The page's color-scheme decides every colour (see
// colors.css); a cookie remembers the choice so the server renders it with
// no flash. "System" clears both and follows the operating system again.
export default class extends Controller {
  static targets = [ "option" ]

  pick(event) {
    const choice = event.currentTarget.dataset.themeChoice
    const root = document.documentElement

    if (choice === "system") {
      delete root.dataset.theme
      document.cookie = "theme=; path=/; max-age=0; SameSite=Lax"
    } else {
      root.dataset.theme = choice
      document.cookie = `theme=${choice}; path=/; max-age=31536000; SameSite=Lax`
    }

    this.optionTargets.forEach(option => option.setAttribute("aria-pressed", String(option === event.currentTarget)))
  }
}
