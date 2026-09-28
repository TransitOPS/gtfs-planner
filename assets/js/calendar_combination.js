// The combine transport's lifecycle.
//
// This hook reports only what the browser observes about the connection, and hands focus to an
// element the server names. It never computes a service date, never decides whether a combination
// is valid and never retries a write: the reviewed command and the decision that produced it live on
// the server, and a confirmation is sent exactly once, by the reviewer, through the ordinary form.
//
// While the socket is down the server cannot reach the page, so the two states a lost connection can
// have are pre-rendered by the server and revealed here: "nothing was sent" for a disconnect before
// a confirmation, and "the outcome is unconfirmed" for a disconnect after one. Reconnecting pushes
// the one lifecycle event the server needs to re-read its authoritative list instead of resending
// anything.
//
// The hook element and the notice it reveals sit outside the drawer: the shared dialog hook closes a
// modal as soon as the socket drops, so a notice rendered inside the drawer could never be read.
const CalendarCombination = {
  mounted() {
    this.handleEvent("calendar:combine-focus", ({ id, fallback_id }) => {
      this.focus(id) || this.focus(fallback_id);
    });
  },

  disconnected() {
    const notice = this.notice();
    if (!notice) return;

    // A confirmation that was already dispatched has no answer on this page; one that was not is
    // still the reviewer's to send.
    const dispatched = this.el.dataset.combineDispatched === "true";
    for (const line of notice.querySelectorAll("[data-combine-connection]")) {
      line.hidden =
        line.dataset.combineConnection !== (dispatched ? "dispatched" : "idle");
    }
    notice.hidden = false;

    const submit = this.submit();
    if (submit) submit.disabled = true;
  },

  reconnected() {
    const notice = this.notice();
    if (notice) notice.hidden = true;

    // The server owns the enabled state from here on; asking it to reload is what resolves a
    // confirmation whose answer was lost, and it never resends the old command.
    this.pushEvent("combine_reconnect", {});
  },

  notice() {
    return this.el.querySelector("#calendar-combine-connection");
  },

  submit() {
    return document.getElementById("calendar-combine-apply");
  },

  focus(id) {
    if (!id) return false;
    const target = document.getElementById(id);
    if (!target || !document.contains(target)) return false;
    target.focus({ preventScroll: false });
    return true;
  },
};

export default CalendarCombination;
