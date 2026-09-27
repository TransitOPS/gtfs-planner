// Dirty-navigation, focus and connectivity behavior for the route pattern
// editor.
//
// The server owns the dirty state and the confirmation dialog. This hook
// carries the three pieces the other hooks do not provide: a browser-level
// `beforeunload` guard while staged edits exist, scoped focus so a task switch
// can land on the task heading, and the connectivity state. A disconnected
// socket can receive no server push, so the offline announcement and the
// disabled commit controls are applied locally and the reconnected event tells
// the server to announce recovery once the socket is back. FormErrorFocus
// remains the hook for invalid-field focus.
const RoutePatternEditor = {
  mounted() {
    this.dirty = this.el.dataset.dirty === "true";
    this.offline = this.el.dataset.offline === "true";

    this.handleEvent("route_pattern_dirty", ({ dirty }) => {
      this.dirty = Boolean(dirty);
    });

    this.handleEvent("route_pattern_focus", ({ id }) => {
      this.focusWithin(id);
    });

    this.beforeUnloadHandler = (event) => {
      if (!this.dirty) return;
      event.preventDefault();
      event.returnValue = "";
      return "";
    };

    window.addEventListener("beforeunload", this.beforeUnloadHandler);
  },

  updated() {
    if (this.el.dataset.dirty !== undefined) {
      this.dirty = this.el.dataset.dirty === "true";
    }

    // A server patch restores the authoritative connectivity state, so the
    // locally applied offline state is cleared whenever the server re-renders
    // the editor as connected.
    if (this.el.dataset.offline === "false" && this.offline) {
      this.setOffline(false);
    }
  },

  disconnected() {
    this.setOffline(true);
  },

  reconnected() {
    this.setOffline(false);
    this.pushEvent("editor_reconnected", {});
  },

  destroyed() {
    if (this.beforeUnloadHandler) {
      window.removeEventListener("beforeunload", this.beforeUnloadHandler);
      this.beforeUnloadHandler = null;
    }
  },

  // Announce the offline state and block any commit control until the socket is
  // back. The server never learns about the disconnect, because a queued event
  // could be replayed after reconnection and leave the editor marked offline.
  setOffline(offline) {
    this.offline = Boolean(offline);

    const banner = document.getElementById("pattern-connectivity");

    if (banner) {
      banner.hidden = !this.offline;
      banner.setAttribute("aria-hidden", String(!this.offline));
    }

    const controls = [
      ...this.el.querySelectorAll("[data-commit]"),
      // Commit actions inside an open review or impact dialog are disabled the
      // same way, so a review that is already open cannot be applied offline.
      ...this.el.querySelectorAll("dialog[data-open='true'] button[id$='-confirm']"),
    ];

    controls.forEach((control) => {
      if (this.offline) {
        control.dataset.commitProtected = "true";
        control.disabled = true;
      } else if (control.dataset.commitProtected === "true") {
        delete control.dataset.commitProtected;
        control.disabled = false;
      }
    });
  },

  // Only focuses an element this editor already owns, so a broadcast event
  // cannot pull focus into an unrelated region of the page.
  focusWithin(id) {
    if (typeof id !== "string" || id === "") return;

    const target = document.getElementById(id);
    if (!target || !this.el.contains(target)) return;
    if (typeof target.focus !== "function") return;

    target.focus();
  },
};

export default RoutePatternEditor;
