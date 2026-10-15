import { Controller } from "@hotwired/stimulus"

// One contact (mobile, WhatsApp or email): type it, send a code, enter the
// code, verified. The value locks once a code is sent; "Change" unlocks it.
//
// Without JavaScript every button shows and each one posts the whole form to
// its formaction, as before. With JavaScript the same endpoints answer JSON:
//   { ok, state: "idle" | "sent" | "verified", message, resend_in }
export default class extends Controller {
  static targets = [ "value", "send", "code", "verify", "resend", "timer", "message", "sentTo", "same" ]
  static values = {
    kind: String,
    state: { type: String, default: "idle" },
    sendUrl: String,
    verifyUrl: String,
    changeUrl: String,
    resendAt: String
  }

  connect() {
    this.apply(this.stateValue, { announce: false })
    const until = Date.parse(this.resendAtValue)
    if (until && until > Date.now()) this.startTimer(until)
  }

  disconnect() {
    this.stopTimer()
  }

  async send(event) {
    event?.preventDefault()
    if (this.sending) return
    if (!this.valueTarget.value.trim()) {
      this.say(this.kindValue === "email" ? "Enter your email address first." : "Enter the number first.", false)
      this.valueTarget.focus()
      return
    }

    this.sending = true
    const button = event?.currentTarget
    this.busy(button, true)
    const data = await this.post(this.sendUrlValue)
    this.busy(button, false)
    this.sending = false
    if (!data) return

    this.say(data.message, data.ok)
    if (data.state) this.apply(data.state)
    if (data.resend_in) this.startTimer(Date.now() + data.resend_in * 1000)
    if (data.ok && this.stateValue === "sent") this.codeTarget.focus()
  }

  async verify(event) {
    event?.preventDefault()
    if (this.verifying) return
    const code = this.codeTarget.value.replace(/\D/g, "")
    if (code.length !== 6) {
      this.say("Enter the 6-digit code.", false)
      this.codeTarget.focus()
      return
    }

    this.verifying = true
    this.busy(this.verifyTarget, true)
    const data = await this.post(this.verifyUrlValue)
    this.busy(this.verifyTarget, false)
    this.verifying = false
    if (!data) return

    if (data.state) this.apply(data.state)
    if (data.ok) {
      this.say("", true)
      this.codeTarget.value = ""
    } else {
      this.say(data.message, false)
      this.codeTarget.select()
    }
  }

  // Unlocks the value at once; the server forgets this contact's code and
  // tick in the background.
  change(event) {
    event.preventDefault()
    this.codeTarget.value = ""
    this.say("", true)
    this.apply("idle")
    this.valueTarget.focus()
    this.valueTarget.select()
    if (this.changeUrlValue) this.post(this.changeUrlValue, { quiet: true })
  }

  // Digits only, and verify as soon as the sixth one lands.
  codeInput() {
    const digits = this.codeTarget.value.replace(/\D/g, "").slice(0, 6)
    if (digits !== this.codeTarget.value) this.codeTarget.value = digits
    if (digits.length === 6) this.verify()
  }

  // Phone fields keep digits only; the +91 is shown beside the box.
  valueInput() {
    if (this.kindValue === "email") return

    const digits = this.valueTarget.value.replace(/\D/g, "").replace(/^(91|0)(?=\d{10}$)/, "").slice(0, 10)
    if (digits !== this.valueTarget.value) this.valueTarget.value = digits
  }

  sameAsMobile(event) {
    if (!event.target.checked) return

    const mobile = document.getElementById("mobile")
    if (!mobile || !mobile.value.trim()) {
      event.target.checked = false
      this.say("Enter your mobile number first.", false)
      return
    }
    if (this.stateValue !== "idle") this.apply("idle")
    this.valueTarget.value = mobile.value
    this.say("Copied from your mobile. You can verify WhatsApp now or later in the app.", true)
    this.valueTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  apply(state, { announce = true } = {}) {
    this.stateValue = state
    this.element.dataset.state = state
    const locked = state !== "idle"
    this.valueTarget.readOnly = locked
    if (this.hasSameTarget) this.sameTarget.disabled = locked
    if (this.hasSentToTarget) this.sentToTarget.textContent = this.display()
    if (state !== "sent") this.stopTimer()
    if (announce) this.dispatch("changed", { detail: { kind: this.kindValue, state } })
  }

  startTimer(until) {
    this.stopTimer()
    if (!this.hasResendTarget) return

    const tick = () => {
      const left = Math.ceil((until - Date.now()) / 1000)
      if (left > 0) {
        this.resendTarget.disabled = true
        if (this.hasTimerTarget) this.timerTarget.textContent = `in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`
      } else {
        this.resendTarget.disabled = false
        if (this.hasTimerTarget) this.timerTarget.textContent = ""
        this.stopTimer()
      }
    }
    tick()
    this.timer = window.setInterval(tick, 1000)
  }

  stopTimer() {
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null
    if (this.hasResendTarget) this.resendTarget.disabled = false
    if (this.hasTimerTarget) this.timerTarget.textContent = ""
  }

  // Text fields only: the files stay in the browser until the final submit.
  async post(url, { quiet = false } = {}) {
    const form = this.element.closest("form")
    const body = new URLSearchParams()
    for (const [ key, value ] of new FormData(form)) {
      if (typeof value === "string") body.append(key, value)
    }

    try {
      const response = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Accept": "application/json",
          "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body
      })
      const data = await response.json().catch(() => null)
      if (data || quiet) return data

      this.say(response.status === 429 ? "Too many attempts. Try again later." : "Something went wrong. Please try again.", false)
      return null
    } catch (_error) {
      if (quiet) return null
      this.say("You seem to be offline. Check your connection and try again.", false)
      return null
    }
  }

  say(message, ok) {
    if (!this.hasMessageTarget) return

    this.messageTarget.textContent = message || ""
    this.messageTarget.classList.toggle("is-ok", Boolean(message) && ok)
    this.messageTarget.classList.toggle("is-err", Boolean(message) && !ok)
  }

  busy(button, on) {
    if (!button) return

    button.classList.toggle("is-busy", on)
    button.setAttribute("aria-busy", on ? "true" : "false")
  }

  display() {
    const value = this.valueTarget.value.trim()
    if (this.kindValue === "email") return value

    const digits = value.replace(/\D/g, "").slice(-10)
    return digits.length === 10 ? `+91 ${digits.slice(0, 5)} ${digits.slice(5)}` : value
  }
}
