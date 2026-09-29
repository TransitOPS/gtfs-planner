import FormErrorFocus from "./form_error_focus_hook"

// Register before LiveSocket.connect installs its window-level history listener.
// popstate targets window itself; hook-time registration is too late to guard it.
let activeEditor = null
window.addEventListener("popstate", event => activeEditor?.historyDeparture(event), true)

// `data-dirty` only catches up once a field's debounced change event has
// round-tripped, so a click that lands in the same moment as a blur would slip
// past it. An editor that renders the saved tuple it is compared against
// (`data-dirty-baseline`, keyed by the form field names) lets the client answer
// the same question exactly, with the same service-time normalization the
// server applies. Without that attribute the hook keeps its `data-dirty`
// behaviour unchanged.
const serviceTime = value => {
  const match = /^(\d{1,3}):([0-5]?\d)(?::([0-5]?\d))?$/.exec(String(value ?? "").trim())
  return match ? Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3] ?? 0) : null
}

const comparableField = (name, value) => {
  const text = String(value ?? "").trim()
  if (name.endsWith("start_time") || name.endsWith("end_time")) return serviceTime(text) ?? text
  return text
}

const CalendarEditor = {
  ...FormErrorFocus,
  mounted() {
    FormErrorFocus.mounted.call(this)
    this.beforeUnload = event => {
      if (!this.isDirty()) return
      event.preventDefault()
      event.returnValue = ""
    }
    this.depart = event => {
      const link = event.target.closest("a[href]")
      if (!this.isDirty() || !link || link.target === "_blank" ||
          event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      const url = new URL(link.href, window.location.href)
      if (url.origin !== window.location.origin ||
          (url.hash && url.pathname === window.location.pathname && url.search === window.location.search)) return
      event.preventDefault()
      event.stopImmediatePropagation()
      this.pushEvent(this.el.dataset.departEvent || "calendar_depart", {path: url.pathname + url.search})
    }
    // History traversal is same-document: neither click nor beforeunload runs.
    // The early window listener runs before LiveView can replace the view.
    // Its history positions let cancellation return to the original entry without
    // adding an entry, losing Forward, or reconstructing the draft from params.
    this.historyDeparture = event => {
      if (this.restoringHistory) {
        event.stopImmediatePropagation()
        this.restoringHistory = false
        return
      }
      if (!this.isDirty()) return
      if (window.confirm(this.el.dataset.discardMessage || "Discard unsaved schedule changes? Cancel to keep editing.")) return
      event.stopImmediatePropagation()
      const delta = this.liveSocket.currentHistoryPosition - (event.state?.position || 0)
      this.restoringHistory = true
      window.history.go(delta)
    }
    // The error summary links to fields that may sit in a collapsed disclosure, and
    // a browser cannot scroll to or focus a control that is not rendered.
    this.jumpToField = event => {
      const link = event.target.closest?.('.form-error-summary a[href^="#"]')
      const target = link && document.getElementById(link.getAttribute("href").slice(1))
      if (!target || !this.el.contains(target)) return
      event.preventDefault()
      this._attemptFocus(target)
    }
    activeEditor = this
    window.addEventListener("beforeunload", this.beforeUnload)
    window.addEventListener("click", this.depart, true)
    this.el.addEventListener("click", this.jumpToField)
  },
  // Optional fields live in `<details>` that the client owns, so a rejected submit
  // opens the one holding the first invalid control before focusing it.
  _attemptFocus(target) {
    const details = target?.closest?.("details")
    if (details) details.open = true
    FormErrorFocus._attemptFocus.call(this, target)
  },
  // Unsaved input, as the browser currently holds it. A field the baseline does
  // not carry (LiveView's own hidden fields) is not part of the comparison.
  isDirty() {
    const baseline = this.el.dataset.dirtyBaseline
    if (!baseline) return this.el.dataset.dirty === "true"

    let saved
    try {
      saved = JSON.parse(baseline)
    } catch (_error) {
      return this.el.dataset.dirty === "true"
    }

    return Array.from(this.el.querySelectorAll("form [name]")).some(field => {
      if (saved[field.name] === undefined) return false
      return comparableField(field.name, field.value) !== comparableField(field.name, saved[field.name])
    })
  },
  destroyed() {
    FormErrorFocus.destroyed?.call(this)
    if (activeEditor === this) activeEditor = null
    window.removeEventListener("beforeunload", this.beforeUnload)
    window.removeEventListener("click", this.depart, true)
    this.el.removeEventListener("click", this.jumpToField)
  }
}
export default CalendarEditor
