import { Controller } from "@hotwired/stimulus"

// Opens the Terms or the Privacy Policy over the form, so nothing typed is
// lost. Without JavaScript (or without <dialog>) the link opens a new tab.
export default class extends Controller {
  static targets = [ "dialog", "frame", "title", "tab" ]

  open(event) {
    if (!this.hasDialogTarget || typeof this.dialogTarget.showModal !== "function") return

    event.preventDefault()
    const link = event.currentTarget
    this.frameTarget.src = event.params.url
    if (this.hasTitleTarget) this.titleTarget.textContent = event.params.title || link.textContent.trim()
    if (this.hasTabTarget) this.tabTarget.href = link.href
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  closed() {
    this.frameTarget.src = "about:blank"
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }
}
