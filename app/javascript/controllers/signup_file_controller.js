import { Controller } from "@hotwired/stimulus"

// A drop zone around one file input: drag a file in or tap to choose, see its
// name, size and a thumbnail, replace or remove it. The size and type check is
// a hint; the server reads the bytes. A HEIC file the browser does not name
// must not be refused here.
export default class extends Controller {
  static targets = [ "zone", "input", "name", "meta", "icon", "message" ]
  static values = {
    maxBytes: { type: Number, default: 2097152 },
    types: { type: Array, default: [ "application/pdf", "image/jpeg", "image/png", "image/webp", "image/heic", "image/heif" ] }
  }

  connect() {
    this.blank = {
      name: this.nameTarget.textContent,
      meta: this.metaTarget.textContent,
      icon: this.iconTarget.innerHTML
    }
  }

  disconnect() {
    this.revoke()
  }

  pick() {
    const file = this.inputTarget.files[0]
    if (!file) return this.reset()

    const typeKnown = Boolean(file.type)
    const tooBig = file.size > this.maxBytesValue
    const wrongType = typeKnown && !this.typesValue.includes(file.type)

    this.zoneTarget.classList.remove("is-bad", "is-filled")
    this.nameTarget.textContent = file.name
    this.metaTarget.textContent = this.size(file.size)

    if (tooBig || wrongType) {
      const message = tooBig
        ? `This file is ${this.size(file.size)}. Choose one of 2 MB or smaller.`
        : "Choose a PDF or an image (JPG, PNG, WebP or HEIC)."
      this.inputTarget.setCustomValidity(message)
      this.zoneTarget.classList.add("is-bad")
      this.say(message)
      this.inputTarget.value = ""
      this.dispatch("changed")
      return
    }

    this.inputTarget.setCustomValidity("")
    this.say("")
    this.zoneTarget.classList.add("is-filled")
    this.preview(file)
    this.dispatch("changed")
  }

  replace(event) {
    event.preventDefault()
    event.stopPropagation()
    this.inputTarget.click()
  }

  remove(event) {
    event.preventDefault()
    event.stopPropagation()
    this.inputTarget.value = ""
    this.reset()
    this.dispatch("changed")
  }

  over(event) {
    event.preventDefault()
    this.zoneTarget.classList.add("is-over")
  }

  leave() {
    this.zoneTarget.classList.remove("is-over")
  }

  drop(event) {
    event.preventDefault()
    this.zoneTarget.classList.remove("is-over")
    const files = event.dataTransfer?.files
    if (!files || !files.length) return

    const transfer = new DataTransfer()
    transfer.items.add(files[0])
    this.inputTarget.files = transfer.files
    this.pick()
  }

  reset() {
    this.revoke()
    this.inputTarget.setCustomValidity("")
    this.zoneTarget.classList.remove("is-bad", "is-filled")
    this.nameTarget.textContent = this.blank.name
    this.metaTarget.textContent = this.blank.meta
    this.iconTarget.innerHTML = this.blank.icon
    this.say("")
  }

  preview(file) {
    this.revoke()
    if (!/^image\/(jpeg|png|webp)$/.test(file.type)) {
      this.iconTarget.innerHTML = '<svg class="su-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>'
      return
    }
    this.url = URL.createObjectURL(file)
    const image = document.createElement("img")
    image.alt = ""
    image.src = this.url
    this.iconTarget.replaceChildren(image)
  }

  revoke() {
    if (this.url) URL.revokeObjectURL(this.url)
    this.url = null
  }

  say(message) {
    if (!this.hasMessageTarget) return

    this.messageTarget.textContent = message
    this.messageTarget.hidden = !message
  }

  size(bytes) {
    if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  }
}
