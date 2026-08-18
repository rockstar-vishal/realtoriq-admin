import { Controller } from "@hotwired/stimulus"

// Opens native <dialog> elements. The browser handles ESC, focus trapping and
// the backdrop, so this only opens and closes.
//
// Openers name their dialog by id (`data-dialog-id-param`), because a page can
// hold more than one — the firm page has both Suspend and Cancel subscription.
// Matching on a target instead would always open whichever came first in the
// DOM, which is exactly the bug this replaced.
export default class extends Controller {
  open({ params: { id } }) {
    const dialog = id ? document.getElementById(id) : this.element.querySelector("dialog")
    dialog?.showModal()
  }

  close(event) {
    event.target.closest("dialog")?.close()
  }
}
