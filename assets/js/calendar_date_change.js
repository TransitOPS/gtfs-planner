// Keep the in-flight UI locked until the server acknowledges the write, including
// a rejected write. These DOM properties are not sticky LiveView JS attributes.
const CalendarDateChange = {
  mounted() {
    this.apply = () => {
      if (this.pending) return
      this.pending = true
      const overlay = document.getElementById("calendar-date-change-drawer-overlay")
      const close = document.getElementById("calendar-date-change-drawer-close")
      const button = document.getElementById("calendar-date-change-apply")
      this.el.inert = true
      overlay.dataset.pending = "true"
      close.disabled = true
      button.disabled = true
      button.textContent = "Applying…"
      this.pushEvent("date_change_apply", {}, () => {
        this.pending = false
        this.el.inert = false
        overlay.dataset.pending = "false"
        close.disabled = false
        button.disabled = false
        button.textContent = "Apply date change"
      })
    }
    this.el.addEventListener("calendar:apply", this.apply)
  },
  destroyed() {
    this.el.removeEventListener("calendar:apply", this.apply)
  }
}
export default CalendarDateChange
