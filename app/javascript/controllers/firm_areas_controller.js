import { Controller } from "@hotwired/stimulus"

// The primary locality has to belong to the selected city. The full locality
// list is in the markup; this only shows the ones in that city, and keeps the
// primary out of "also works in" so it is not stored twice.
export default class extends Controller {
  static targets = ["city", "locality", "extra"]

  connect() {
    this.allLocalities = Array.from(this.localityTarget.options)
      .filter((option) => option.value)
      .map((option) => ({
        value: option.value,
        label: option.textContent,
        cityId: option.dataset.cityId,
      }))
    this.blankLabel = this.localityTarget.options[0]?.value === ""
      ? this.localityTarget.options[0].textContent
      : "Select a locality"
    this.filter()
  }

  filter() {
    const cityId = this.cityTarget.value
    const select = this.localityTarget
    const current = select.value

    select.replaceChildren()
    const blank = document.createElement("option")
    blank.value = ""
    blank.textContent = this.blankLabel
    select.appendChild(blank)

    this.allLocalities
      .filter((row) => row.cityId === cityId)
      .forEach((row) => {
        const option = document.createElement("option")
        option.value = row.value
        option.textContent = row.label
        option.dataset.cityId = row.cityId
        if (row.value === current) option.selected = true
        select.appendChild(option)
      })

    if (![...select.options].some((option) => option.value === current && option.value !== "")) {
      select.value = ""
    }

    this.syncExtras()
  }

  syncExtras() {
    if (!this.hasExtraTarget) return

    const primary = this.localityTarget.value
    Array.from(this.extraTarget.options).forEach((option) => {
      const isPrimary = option.value !== "" && option.value === primary
      option.hidden = isPrimary
      option.disabled = isPrimary
      if (isPrimary) option.selected = false
    })
  }
}
