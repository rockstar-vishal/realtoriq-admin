import { Controller } from "@hotwired/stimulus"

// Tracks the six sections, ticks them off (in the card, the desktop rail and
// the mobile bar), and keeps Submit off until everything required is done.
//
// "Required" is whatever carries data-required inside a visible section.
// A contact that carries data-must-verify must be in the verified state.
//
// Submit is aria-disabled rather than disabled, so a tap on it can say what is
// missing and jump there. Without JavaScript it is a plain enabled button and
// the server checks everything.
//
// Once the broker has typed or chosen anything, leaving or refreshing the page
// asks first. Only the verified contacts survive a reload (in the verify
// cookie); the other details and chosen files do not. Browsers show their own
// wording for a refresh or a closed tab; a link inside the app (Turbo) shows ours.
export default class extends Controller {
  static targets = [ "step", "check", "submit", "fill", "count", "next", "status", "captcha" ]

  connect() {
    window.suCaptchaDone = () => { this.captchaOk = true; this.refresh() }
    window.suCaptchaExpired = () => { this.captchaOk = false; this.refresh() }
    this.captchaOk = !this.hasCaptchaTarget
    this.touched = false
    this.submitting = false

    this.onBeforeUnload = (event) => {
      if (!this.shouldWarn()) return
      event.preventDefault()
      event.returnValue = ""
    }
    this.onTurboVisit = (event) => {
      if (this.shouldWarn() && !window.confirm("Leave this page? Your verified mobile, WhatsApp and email are kept, but you'll need to fill in the other details and choose your files again.")) {
        event.preventDefault()
      }
    }
    window.addEventListener("beforeunload", this.onBeforeUnload)
    document.addEventListener("turbo:before-visit", this.onTurboVisit)
    this.refresh()
  }

  disconnect() {
    delete window.suCaptchaDone
    delete window.suCaptchaExpired
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    document.removeEventListener("turbo:before-visit", this.onTurboVisit)
  }

  // Called by the form's input and change events, and by the contact, file,
  // locality and RERA controllers when they change something.
  refresh(event) {
    if (event && event.type !== "signup-reveal:changed") this.touched = true

    const done = {}
    this.stepTargets.forEach((step) => {
      const complete = this.missing(step).length === 0
      done[step.dataset.step] = complete
      step.classList.toggle("is-done", complete)
      document.querySelectorAll(`[data-rail-step="${step.dataset.step}"]`)
        .forEach((item) => item.classList.toggle("is-done", complete))
    })

    const checks = {
      mobile: this.verified("mobile"),
      email: this.verified("email"),
      details: this.stepTargets.filter((step) => step.dataset.step !== "submit").every((step) => done[step.dataset.step]),
      accept: Boolean(this.element.querySelector("#accept")?.checked),
      captcha: this.captchaOk
    }
    this.checkTargets.forEach((item) => item.classList.toggle("is-done", Boolean(checks[item.dataset.check])))

    if (this.missingElement && !this.stepTargets.some((step) => this.missing(step).some((gap) => gap.element === this.missingElement))) {
      this.clearMissing()
    }

    const ready = Object.values(checks).every(Boolean)
    if (this.hasSubmitTarget) this.submitTarget.setAttribute("aria-disabled", ready ? "false" : "true")
    this.ready = ready

    const total = this.stepTargets.length
    const count = this.stepTargets.filter((step) => done[step.dataset.step]).length
    if (this.hasFillTarget) this.fillTarget.style.width = `${Math.round((count / total) * 100)}%`
    if (this.hasCountTarget) this.countTarget.textContent = `${count} of ${total} done`
    if (this.hasNextTarget) {
      const next = this.stepTargets.find((step) => !done[step.dataset.step])
      this.nextTarget.textContent = next ? `Next: ${next.dataset.title}` : "Ready to submit"
    }
  }

  guard(event) {
    this.refresh()
    if (this.ready) {
      this.submitting = true
      this.submitTarget.classList.add("is-busy")
      this.submitTarget.textContent = "Submitting…"
      return
    }

    event.preventDefault()
    const first = this.firstGap()
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = first ? first.message : "Finish the steps above first."
    }
    if (!first) return

    this.markMissing(first)
    const card = first.element.closest(".su-card")
    first.element.scrollIntoView({ behavior: "smooth", block: "center" })
    window.setTimeout(() => {
      const focusable = first.element.matches("input, select, textarea, button")
        ? first.element
        : first.element.querySelector("input:not([type=hidden]):not([readonly]), select, textarea, button")
      focusable?.focus({ preventScroll: true })
    }, 350)
    if (card) {
      card.classList.remove("su-flash")
      void card.offsetWidth
      card.classList.add("su-flash")
    }
  }

  // Outline the field and say what it needs, right where the page scrolled to.
  // The note goes once the field is filled.
  markMissing(gap) {
    this.clearMissing()
    gap.element.classList.add("su-missing")
    const note = document.createElement("p")
    note.className = "su-error su-missing-note"
    note.setAttribute("role", "alert")
    note.textContent = gap.message
    gap.element.append(note)
    this.missingElement = gap.element
  }

  clearMissing() {
    if (!this.missingElement) return
    this.missingElement.classList.remove("su-missing")
    this.missingElement.querySelectorAll(".su-missing-note").forEach((note) => note.remove())
    this.missingElement = null
  }

  shouldWarn() {
    if (this.submitting) return false
    const filesChosen = Array.from(this.element.querySelectorAll("input[type=file]")).some((input) => input.files.length > 0)
    return this.touched || filesChosen
  }

  // ---- what is missing ----

  missing(step) {
    const gaps = []
    step.querySelectorAll("[data-required]").forEach((field) => {
      if (!this.visible(field)) return
      if (!this.filled(field)) gaps.push({ element: this.target(field), message: this.say(field) })
    })
    step.querySelectorAll("[data-must-verify]").forEach((contact) => {
      if (contact.dataset.state !== "verified") {
        gaps.push({ element: contact, message: `Verify your ${contact.dataset.label}.` })
      }
    })
    if (step.dataset.step === "submit" && !this.captchaOk) {
      gaps.push({ element: this.captchaTarget, message: "Tick the captcha." })
    }
    return gaps
  }

  firstGap() {
    for (const step of this.stepTargets) {
      const gaps = this.missing(step)
      if (gaps.length) return gaps[0]
    }
    return null
  }

  filled(field) {
    if (field.type === "radio") {
      return Boolean(this.element.querySelector(`input[type="radio"][name="${field.name}"]:checked`))
    }
    if (field.type === "checkbox") return field.checked
    if (field.type === "file") return field.files.length > 0 && field.validity.valid
    if (field.tagName === "SELECT") return Array.from(field.selectedOptions).some((option) => option.value)

    const value = field.value.trim()
    if (!value) return false
    if (field.pattern) return new RegExp(`^(?:${field.pattern})$`).test(value)
    return true
  }

  visible(field) {
    return !field.closest(".su-reveal:not(.is-open)")
  }

  // A hidden native select is reached through its search box.
  target(field) {
    return field.closest("[data-controller~='signup-combobox']") ||
      field.closest(".su-contact") ||
      field.closest(".su-field") ||
      field
  }

  say(field) {
    return field.dataset.missing || "Fill in the highlighted field."
  }

  verified(kind) {
    return this.element.querySelector(`[data-kind="${kind}"]`)?.dataset.state === "verified"
  }
}
