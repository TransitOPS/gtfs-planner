const OverlayDialog = {
  mounted() {
    this._overlayDialog_boundCancel = this._onCancel.bind(this);
    this._overlayDialog_boundClick = this._onBackdropClick.bind(this);

    this.el.addEventListener("cancel", this._overlayDialog_boundCancel);
    this.el.addEventListener("click", this._overlayDialog_boundClick);

    if (this._isOpenRequested() && !this.el.open) {
      this._activate();
    }
  },

  updated() {
    const requested = this._isOpenRequested();
    if (requested && !this.el.open) {
      this._activate();
    } else if (!requested && this.el.open) {
      this._deactivate();
    }
  },

  disconnected() {
    if (this.el.open) {
      this.el.close();
      const opener = this._overlayDialog_opener;
      if (opener && document.contains(opener) && typeof opener.focus === "function") {
        opener.focus();
      }
    }
  },

  reconnected() {
    this._overlayDialog_opener = null;
    const requested = this._isOpenRequested();
    if (requested && !this.el.open) {
      this._activate();
    } else if (!requested && this.el.open) {
      this._deactivate();
    }
  },

  destroyed() {
    this._cleanup();
  },

  _isOpenRequested() {
    return this.el.dataset.open === "true";
  },

  _isPending() {
    return this.el.dataset.pending === "true";
  },

  _cleanup() {
    if (this._overlayDialog_boundCancel) {
      this.el.removeEventListener("cancel", this._overlayDialog_boundCancel);
      this._overlayDialog_boundCancel = null;
    }
    if (this._overlayDialog_boundClick) {
      this.el.removeEventListener("click", this._overlayDialog_boundClick);
      this._overlayDialog_boundClick = null;
    }
    if (this.el.open) {
      this.el.close();
    }
    this._overlayDialog_opener = null;
  },

  _activate() {
    this._overlayDialog_opener = document.activeElement;
    this.el.showModal();
    this.el.scrollLeft = 0;
    this.el.scrollTop = 0;
    this._applyInitialFocus();
    this.el.scrollLeft = 0;
    this.el.scrollTop = 0;
  },

  _deactivate() {
    const returnId = this.el.dataset.returnFocusId;
    this.el.close();

    if (returnId) {
      const target = document.getElementById(returnId);
      if (target && document.contains(target) && typeof target.focus === "function") {
        target.focus();
      }
    }
  },

  _applyInitialFocus() {
    const explicitId = this.el.dataset.initialFocusId;
    if (explicitId) {
      const target = document.getElementById(explicitId);
      if (target && this.el.contains(target) && this._focusWithoutScroll(target)) return;
    }

    const role = this.el.getAttribute("role");
    const mode = this.el.dataset.initialFocus;

    if (role === "alertdialog" || !mode || mode === "cancel") {
      const dismiss = this._findDismissButton();
      if (this._focusWithoutScroll(dismiss)) return;
    }

    if (mode === "heading") {
      const heading = this.el.querySelector(
        "[role='heading'], h1, h2, h3, h4, h5, h6",
      );
      if (this._focusWithoutScroll(heading)) return;
    }

    if (mode === "first_field") {
      const field = Array.from(
        this.el.querySelectorAll(
          "input:not([disabled]):not([type='hidden']), select:not([disabled]), textarea:not([disabled])",
        ),
      ).find((candidate) => this._isRendered(candidate));
      if (this._focusWithoutScroll(field)) return;
    }

    const panel = this.el.querySelector("[data-dialog-panel]");
    this._focusWithoutScroll(panel);
  },

  _isRendered(target) {
    if (target.closest("[hidden], [inert]")) return false;

    const style = window.getComputedStyle(target);
    if (style.display === "none" || style.visibility === "hidden") return false;

    return target.getClientRects().length > 0;
  },

  _focusWithoutScroll(target) {
    if (!target || typeof target.focus !== "function") return false;

    target.focus({ preventScroll: true });
    return document.activeElement === target;
  },

  _findDismissButton() {
    return this.el.querySelector("[data-dialog-dismiss]");
  },

  _onCancel(e) {
    e.preventDefault();
    e.stopPropagation();

    if (this._isPending()) return;

    const dismiss = this._findDismissButton();
    if (dismiss) dismiss.click();
  },

  _onBackdropClick(e) {
    if (e.target !== this.el) return;
    if (this.el.dataset.closeOnBackdrop !== "true") return;
    if (this._isPending()) return;

    const dismiss = this._findDismissButton();
    if (dismiss) dismiss.click();
  },
};

export default OverlayDialog;
