import FormErrorFocus from "./form_error_focus_hook"

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
      this.pushEvent("calendar_depart", {path: url.pathname + url.search})
    }
    window.addEventListener("beforeunload", this.beforeUnload)
    window.addEventListener("click", this.depart, true)
  },
  destroyed() {
    FormErrorFocus.destroyed?.call(this)
    window.removeEventListener("beforeunload", this.beforeUnload)
    window.removeEventListener("click", this.depart, true)
  }
}
export default CalendarEditor
