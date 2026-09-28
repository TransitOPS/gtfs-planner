import FormErrorFocus from "./form_error_focus_hook"

// Register before LiveSocket.connect installs its window-level history listener.
// popstate targets window itself; hook-time registration is too late to guard it.
let activeEditor = null
window.addEventListener("popstate", event => activeEditor?.historyDeparture(event), true)

const CalendarEditor = {
  ...FormErrorFocus,
  mounted() {
    FormErrorFocus.mounted.call(this)
    this.beforeUnload = event => {
      if (this.el.dataset.dirty !== "true") return
      event.preventDefault()
      event.returnValue = ""
    }
    this.depart = event => {
      const link = event.target.closest("a[href]")
      if (this.el.dataset.dirty !== "true" || !link || link.target === "_blank" ||
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
      if (this.el.dataset.dirty !== "true") return
      if (window.confirm(this.el.dataset.discardMessage || "Discard unsaved schedule changes? Cancel to keep editing.")) return
      event.stopImmediatePropagation()
      const delta = this.liveSocket.currentHistoryPosition - (event.state?.position || 0)
      this.restoringHistory = true
      window.history.go(delta)
    }
    activeEditor = this
    window.addEventListener("beforeunload", this.beforeUnload)
    window.addEventListener("click", this.depart, true)
  },
  destroyed() {
    FormErrorFocus.destroyed?.call(this)
    if (activeEditor === this) activeEditor = null
    window.removeEventListener("beforeunload", this.beforeUnload)
    window.removeEventListener("click", this.depart, true)
  }
}
export default CalendarEditor
