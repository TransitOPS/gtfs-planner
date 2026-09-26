// Dirty-navigation and focus behavior for the route pattern editor.
//
// The server owns the dirty state and the confirmation dialog. This hook only
// carries the two pieces the current hooks do not provide: a browser-level
// `beforeunload` guard while staged edits exist, and scoped focus so a task
// switch can land on the task heading. FormErrorFocus remains the hook for
// invalid-field focus.
const RoutePatternEditor = {
  mounted() {
    this.dirty = this.el.dataset.dirty === "true";

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
  },

  destroyed() {
    if (this.beforeUnloadHandler) {
      window.removeEventListener("beforeunload", this.beforeUnloadHandler);
      this.beforeUnloadHandler = null;
    }
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
