/**
 * Keyboard behavior for LiveView-owned Details/History tabs.
 *
 * The server remains the source of truth for the selected panel. This hook only
 * supplies the WAI-ARIA roving-focus shortcut and activates the existing button
 * event, so rollback previews and history filters retain their LiveView paths.
 */
const TablistHook = {
  mounted() {
    this._onKeydown = (event) => this._handleKeydown(event);
    this.el.addEventListener("keydown", this._onKeydown);
    this._syncRovingTabindex();
  },

  updated() {
    this._syncRovingTabindex();
  },

  destroyed() {
    if (this._onKeydown) {
      this.el.removeEventListener("keydown", this._onKeydown);
      this._onKeydown = null;
    }
  },

  _tabs() {
    return Array.from(this.el.querySelectorAll('[role="tab"]:not([disabled])'));
  },

  _syncRovingTabindex() {
    const tabs = this._tabs();
    if (tabs.length === 0) return;

    const selected = tabs.find((tab) => tab.getAttribute("aria-selected") === "true") || tabs[0];
    tabs.forEach((tab) => tab.setAttribute("tabindex", tab === selected ? "0" : "-1"));
  },

  _handleKeydown(event) {
    if (event.altKey || event.ctrlKey || event.metaKey) return;

    const current = event.target.closest('[role="tab"]');
    if (!current || !this.el.contains(current)) return;

    const tabs = this._tabs();
    const currentIndex = tabs.indexOf(current);
    if (currentIndex < 0) return;

    let nextIndex;
    switch (event.key) {
      case "ArrowRight":
        nextIndex = (currentIndex + 1) % tabs.length;
        break;
      case "ArrowLeft":
        nextIndex = (currentIndex - 1 + tabs.length) % tabs.length;
        break;
      case "Home":
        nextIndex = 0;
        break;
      case "End":
        nextIndex = tabs.length - 1;
        break;
      default:
        return;
    }

    event.preventDefault();
    const next = tabs[nextIndex];
    tabs.forEach((tab) => tab.setAttribute("tabindex", tab === next ? "0" : "-1"));
    next.focus();
    next.click();
  },
};

export default TablistHook;
