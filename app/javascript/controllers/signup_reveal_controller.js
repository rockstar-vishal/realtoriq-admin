import { Controller } from "@hotwired/stimulus"

// Shows the panel that matches the chosen radio (RERA yes or no) and makes
// only that panel's fields required. Without JavaScript both panels show, each
// with its own heading.
export default class extends Controller {
  static targets = [ "panel" ]
  static values = { name: String }

  connect() {
    this.toggle()
  }

  toggle() {
    const checked = this.element.querySelector(`input[type="radio"][name="${this.nameValue}"]:checked`)
    const value = checked ? checked.value : null

    this.panelTargets.forEach((panel) => {
      const open = panel.dataset.when === value
      panel.classList.toggle("is-open", open)
      panel.querySelectorAll("[data-required]").forEach((field) => {
        if (field.dataset.native !== "false") field.required = open
      })
    })
    this.dispatch("changed")
  }
}
