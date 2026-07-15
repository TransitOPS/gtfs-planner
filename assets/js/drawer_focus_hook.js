// Focus management for the server-driven <.drawer> component.
//
// The drawer's open state lives on the server; the panel is always in the DOM
// and toggles via `data-open`. On open this hook moves focus into the panel,
// traps Tab/Shift-Tab, and closes on Escape through the same `on_close` event
// the overlay and header button push. On close it restores focus to the opener.
const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

const DrawerFocus = {
  mounted() {
    this.active = false
    this.opener = null
    this.handleKeydown = (e) => this.onKeydown(e)
    if (this.isOpen()) this.activate()
  },

  updated() {
    if (this.isOpen() && !this.active) {
      this.activate()
    } else if (!this.isOpen() && this.active) {
      this.deactivate()
    }
  },

  destroyed() {
    this.deactivate()
  },

  isOpen() {
    return this.el.dataset.open === "true"
  },

  activate() {
    this.active = true
    this.opener = document.activeElement
    this.el.addEventListener("keydown", this.handleKeydown)
    const items = this.focusables()
    if (items.length > 0) {
      items[0].focus()
    } else {
      this.el.focus()
    }
  },

  deactivate() {
    if (!this.active) return
    this.active = false
    this.el.removeEventListener("keydown", this.handleKeydown)
    if (this.opener && typeof this.opener.focus === "function") {
      this.opener.focus()
    }
    this.opener = null
  },

  focusables() {
    return Array.from(this.el.querySelectorAll(FOCUSABLE)).filter(
      (el) => el.offsetParent !== null
    )
  },

  onKeydown(e) {
    if (e.key === "Escape") {
      e.preventDefault()
      const event = this.el.dataset.onClose
      if (event) this.pushEvent(event)
      return
    }
    if (e.key !== "Tab") return
    const items = this.focusables()
    if (items.length === 0) {
      e.preventDefault()
      return
    }
    const first = items[0]
    const last = items[items.length - 1]
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault()
      first.focus()
    }
  },
}

export default DrawerFocus
