/**
 * WAI-ARIA menu-button behavior for the header account menu.
 *
 * The hook owns open/close state for a purely client-side dropdown: the trigger
 * toggles the panel, clicking away or pressing Escape closes it (returning focus
 * to the trigger), and arrow/Home/End keys move roving focus across the menu
 * items. Navigation and logout remain plain links, so the server stays the
 * source of truth for what each item does.
 */
const UserMenuHook = {
  mounted() {
    this._trigger = this.el.querySelector("[data-user-menu-trigger]");
    this._panel = this.el.querySelector("[data-user-menu-panel]");

    this._onTriggerClick = (event) => this._handleTriggerClick(event);
    this._onTriggerKeydown = (event) => this._handleTriggerKeydown(event);
    this._onPanelKeydown = (event) => this._handlePanelKeydown(event);
    this._onDocumentPointerdown = (event) => this._handleDocumentPointerdown(event);

    this._trigger.addEventListener("click", this._onTriggerClick);
    this._trigger.addEventListener("keydown", this._onTriggerKeydown);
    this._panel.addEventListener("keydown", this._onPanelKeydown);
  },

  destroyed() {
    this._trigger.removeEventListener("click", this._onTriggerClick);
    this._trigger.removeEventListener("keydown", this._onTriggerKeydown);
    this._panel.removeEventListener("keydown", this._onPanelKeydown);
    document.removeEventListener("pointerdown", this._onDocumentPointerdown, true);
  },

  _items() {
    return Array.from(this._panel.querySelectorAll('[role="menuitem"]'));
  },

  _isOpen() {
    return this._trigger.getAttribute("aria-expanded") === "true";
  },

  _open({ focus = "first" } = {}) {
    this._panel.hidden = false;
    this._trigger.setAttribute("aria-expanded", "true");
    document.addEventListener("pointerdown", this._onDocumentPointerdown, true);

    const items = this._items();
    if (items.length === 0) return;
    const target = focus === "last" ? items[items.length - 1] : items[0];
    target.focus();
  },

  _close({ returnFocus = true } = {}) {
    if (!this._isOpen()) return;
    this._panel.hidden = true;
    this._trigger.setAttribute("aria-expanded", "false");
    document.removeEventListener("pointerdown", this._onDocumentPointerdown, true);
    if (returnFocus) this._trigger.focus();
  },

  _handleTriggerClick(event) {
    event.preventDefault();
    if (this._isOpen()) {
      this._close();
    } else {
      this._open();
    }
  },

  _handleTriggerKeydown(event) {
    switch (event.key) {
      case "ArrowDown":
      case "Enter":
      case " ":
        event.preventDefault();
        this._open({ focus: "first" });
        break;
      case "ArrowUp":
        event.preventDefault();
        this._open({ focus: "last" });
        break;
      default:
        break;
    }
  },

  _handlePanelKeydown(event) {
    const items = this._items();
    if (items.length === 0) return;
    const currentIndex = items.indexOf(document.activeElement);

    switch (event.key) {
      case "Escape":
        event.preventDefault();
        this._close();
        break;
      case "Tab":
        this._close({ returnFocus: false });
        break;
      case "ArrowDown":
        event.preventDefault();
        items[(currentIndex + 1) % items.length].focus();
        break;
      case "ArrowUp":
        event.preventDefault();
        items[(currentIndex - 1 + items.length) % items.length].focus();
        break;
      case "Home":
        event.preventDefault();
        items[0].focus();
        break;
      case "End":
        event.preventDefault();
        items[items.length - 1].focus();
        break;
      default:
        break;
    }
  },

  _handleDocumentPointerdown(event) {
    if (!this.el.contains(event.target)) this._close({ returnFocus: false });
  },
};

export default UserMenuHook;
