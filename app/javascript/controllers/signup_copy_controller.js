import { Controller } from "@hotwired/stimulus"

// Copies the registration reference.
export default class extends Controller {
  static targets = [ "button" ]
  static values = { text: String }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.textValue)
      this.buttonTarget.textContent = "Copied"
    } catch (_error) {
      this.buttonTarget.textContent = "Select and copy"
    }
    window.setTimeout(() => { this.buttonTarget.textContent = "Copy" }, 2000)
  }
}
