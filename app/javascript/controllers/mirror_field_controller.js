import { Controller } from "@hotwired/stimulus"

// "WhatsApp is the same as the mobile number" — copies the source field into
// the destination and locks it while the box is ticked.
//
// The server recomputes this from the checkbox on save, so this is purely so
// the admin can see what they're about to store.
export default class extends Controller {
  static targets = ["toggle", "destination"]

  connect() {
    this.sourceField = this.element.closest("form")?.querySelector("[name='firm[contact_mobile]']")
    this.sync()
  }

  sync() {
    if (!this.hasDestinationTarget) return

    const mirroring = this.hasToggleTarget && this.toggleTarget.checked

    if (mirroring && this.sourceField) {
      this.destinationTarget.value = this.sourceField.value
    }

    this.destinationTarget.readOnly = mirroring
    this.destinationTarget.classList.toggle("opacity-60", mirroring)
  }
}
