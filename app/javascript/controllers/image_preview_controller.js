import { Controller } from "@hotwired/stimulus"

// Shows the chosen logo before it is uploaded, so an admin notices they picked
// the wrong file before saving rather than after.
export default class extends Controller {
  static targets = ["input", "image", "placeholder"]

  show() {
    const file = this.inputTarget.files?.[0]
    if (!file) return

    if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
    this.objectUrl = URL.createObjectURL(file)

    this.imageTarget.src = this.objectUrl
    this.imageTarget.classList.remove("hidden")
    if (this.hasPlaceholderTarget) this.placeholderTarget.classList.add("hidden")
  }

  disconnect() {
    if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
  }
}
