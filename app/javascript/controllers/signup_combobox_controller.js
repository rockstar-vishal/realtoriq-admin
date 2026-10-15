import { Controller } from "@hotwired/stimulus"

// Searchable locality picker over a native <select>, which stays the source of
// truth and is what the form posts. Without JavaScript the select shows as is.
//
// Single: type to search, pick one.
// Multiple: picked localities show as removable tags; Backspace removes the last.
export default class extends Controller {
  static targets = [ "select", "box", "input", "list", "tags", "count" ]
  static values = {
    multiple: Boolean,
    cityField: String,
    excludeField: String,
    max: { type: Number, default: 15 },
    placeholder: String,
    emptyCity: { type: String, default: "Choose a city first" }
  }

  connect() {
    this.options = Array.from(this.selectTarget.options)
      .filter((option) => option.value)
      .map((option) => ({ id: option.value, name: option.dataset.name || option.text, city: option.dataset.city, option }))
    this.selectTarget.required = false
    this.active = -1

    const label = document.querySelector(`label[for="${this.selectTarget.id}"]`)
    if (label) label.htmlFor = this.inputTarget.id

    this.onCity = () => this.cityChanged()
    this.onExclude = () => this.excludeChanged()
    this.city?.addEventListener("change", this.onCity)
    this.exclude?.addEventListener("change", this.onExclude)
    this.render()
  }

  disconnect() {
    this.city?.removeEventListener("change", this.onCity)
    this.exclude?.removeEventListener("change", this.onExclude)
  }

  get city() {
    return this.cityFieldValue ? document.getElementById(this.cityFieldValue) : null
  }

  get exclude() {
    return this.excludeFieldValue ? document.getElementById(this.excludeFieldValue) : null
  }

  get cityId() {
    return this.city ? this.city.value : ""
  }

  get picked() {
    return this.options.filter((item) => item.option.selected)
  }

  // ---- events ----

  focus(event) {
    if (event.target.closest("button")) return
    this.inputTarget.focus()
  }

  open() {
    if (this.inputTarget.disabled) return
    if (!this.multipleValue) this.inputTarget.select()
    this.show(this.multipleValue ? this.inputTarget.value : "")
  }

  search() {
    this.show(this.inputTarget.value)
  }

  blur() {
    window.setTimeout(() => {
      if (this.element.contains(document.activeElement)) return
      this.close()
      if (!this.multipleValue) this.inputTarget.value = this.picked[0]?.name || ""
      if (this.multipleValue) this.inputTarget.value = ""
    }, 120)
  }

  key(event) {
    const items = this.listTarget.querySelectorAll("[role=option]")
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        if (this.listTarget.hidden) return this.show(this.inputTarget.value)
        this.highlight(Math.min(this.active + 1, items.length - 1))
        break
      case "ArrowUp":
        event.preventDefault()
        this.highlight(Math.max(this.active - 1, 0))
        break
      case "Enter":
        if (!this.listTarget.hidden && items[this.active]) {
          event.preventDefault()
          this.pick(items[this.active].dataset.id)
        } else {
          event.preventDefault()
        }
        break
      case "Escape":
        if (!this.listTarget.hidden) {
          event.preventDefault()
          this.close()
        }
        break
      case "Backspace":
        if (this.multipleValue && !this.inputTarget.value && this.picked.length) {
          this.unpick(this.picked[this.picked.length - 1].id)
        }
        break
    }
  }

  choose(event) {
    event.preventDefault()
    const item = event.target.closest("[role=option]")
    if (item) this.pick(item.dataset.id)
  }

  remove(event) {
    event.preventDefault()
    event.stopPropagation()
    this.unpick(event.currentTarget.dataset.id)
    this.inputTarget.focus()
  }

  cityChanged() {
    this.options.forEach((item) => {
      if (item.option.selected && item.city !== this.cityId) item.option.selected = false
    })
    if (!this.multipleValue && !this.picked.length) this.selectTarget.value = ""
    this.inputTarget.value = ""
    this.changed()
  }

  excludeChanged() {
    const id = this.exclude?.value
    const item = this.options.find((entry) => entry.id === id)
    if (item && item.option.selected) {
      item.option.selected = false
      this.changed()
    } else {
      this.render()
    }
  }

  // ---- selection ----

  pick(id) {
    const item = this.options.find((entry) => entry.id === id)
    if (!item) return

    if (this.multipleValue) {
      if (!item.option.selected && this.picked.length >= this.maxValue) {
        this.note(`You can add up to ${this.maxValue}.`)
        return
      }
      item.option.selected = true
      this.inputTarget.value = ""
      this.changed()
      this.show("")
      this.inputTarget.focus()
    } else {
      this.selectTarget.value = id
      this.inputTarget.value = item.name
      this.close()
      this.changed()
    }
  }

  unpick(id) {
    const item = this.options.find((entry) => entry.id === id)
    if (!item) return

    item.option.selected = false
    this.changed()
  }

  changed() {
    this.render()
    this.selectTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.dispatch("changed")
  }

  // ---- drawing ----

  render() {
    const hasCity = Boolean(this.cityId)
    this.inputTarget.disabled = !hasCity
    this.boxTarget.classList.toggle("is-disabled", !hasCity)
    this.inputTarget.placeholder = hasCity ? this.placeholderValue : this.emptyCityValue

    if (this.multipleValue) {
      this.tagsTarget.replaceChildren(...this.picked.map((item) => this.tag(item)))
      if (this.hasCountTarget) {
        const count = this.picked.length
        this.countTarget.textContent = count ? `${count} selected · up to ${this.maxValue}` : ""
      }
    } else if (document.activeElement !== this.inputTarget) {
      this.inputTarget.value = this.picked[0]?.name || ""
    }
  }

  tag(item) {
    const tag = document.createElement("span")
    tag.className = "su-tag"
    const name = document.createElement("span")
    name.textContent = item.name
    const button = document.createElement("button")
    button.type = "button"
    button.dataset.id = item.id
    button.dataset.action = "signup-combobox#remove"
    button.setAttribute("aria-label", `Remove ${item.name}`)
    button.textContent = "×"
    tag.append(name, button)
    return tag
  }

  show(query) {
    if (this.inputTarget.disabled) return

    const q = query.trim().toLowerCase()
    const excluded = this.exclude?.value
    let matches = this.options.filter((item) => item.city === this.cityId)
    if (this.multipleValue) matches = matches.filter((item) => !item.option.selected && item.id !== excluded)
    if (q) {
      matches = matches
        .filter((item) => item.name.toLowerCase().includes(q))
        .sort((a, b) => Number(!a.name.toLowerCase().startsWith(q)) - Number(!b.name.toLowerCase().startsWith(q)))
    }

    const shown = matches.slice(0, 60)
    const pickedId = this.multipleValue ? null : this.selectTarget.value
    const rows = shown.map((item, index) => {
      const row = document.createElement("li")
      row.id = `${this.listTarget.id}-${index}`
      row.className = "su-combo-option"
      row.setAttribute("role", "option")
      row.dataset.id = item.id
      row.setAttribute("aria-selected", "false")
      if (item.id === pickedId) row.classList.add("is-picked")
      const label = document.createElement("span")
      label.append(this.marked(item.name, q))
      row.append(label)
      return row
    })

    if (!rows.length) {
      const empty = document.createElement("li")
      empty.className = "su-combo-empty"
      empty.textContent = q ? `No locality matches “${query.trim()}”.` : "No more localities in this city."
      rows.push(empty)
    } else if (matches.length > shown.length) {
      const more = document.createElement("li")
      more.className = "su-combo-empty"
      more.textContent = `Showing ${shown.length} of ${matches.length}. Keep typing to narrow down.`
      rows.push(more)
    }

    this.listTarget.replaceChildren(...rows)
    this.listTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
    this.highlight(rows[0]?.getAttribute("role") === "option" ? 0 : -1)
  }

  marked(name, q) {
    const fragment = document.createDocumentFragment()
    const at = q ? name.toLowerCase().indexOf(q) : -1
    if (at < 0) {
      fragment.append(name)
      return fragment
    }
    const mark = document.createElement("mark")
    mark.textContent = name.slice(at, at + q.length)
    fragment.append(name.slice(0, at), mark, name.slice(at + q.length))
    return fragment
  }

  highlight(index) {
    const items = this.listTarget.querySelectorAll("[role=option]")
    items.forEach((item, i) => item.setAttribute("aria-selected", i === index ? "true" : "false"))
    this.active = index
    const current = items[index]
    if (current) {
      this.inputTarget.setAttribute("aria-activedescendant", current.id)
      current.scrollIntoView({ block: "nearest" })
    } else {
      this.inputTarget.removeAttribute("aria-activedescendant")
    }
  }

  close() {
    this.listTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
    this.active = -1
  }

  note(message) {
    if (this.hasCountTarget) this.countTarget.textContent = message
  }
}
