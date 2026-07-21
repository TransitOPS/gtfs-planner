const FOCUS_FORM_ERROR_EVENT = "focus_form_error";
const INVALID_CONTROL_SELECTOR = '[aria-invalid="true"]';

const FormErrorFocus = {
  mounted() {
    this.handleEvent(FOCUS_FORM_ERROR_EVENT, (payload) => {
      this._focusFormError(payload || {});
    });

    const mountFocusId = this.el.dataset.focusOnMount;
    if (mountFocusId) {
      this._focusWithin(mountFocusId);
    }
  },

  _focusFormError(payload) {
    const form = this._findWithinRoot(payload.form_id);
    const invalid = form ? form.querySelector(INVALID_CONTROL_SELECTOR) : null;

    if (invalid) {
      this._attemptFocus(invalid);
      return;
    }

    this._focusWithin(payload.fallback_id);
  },

  _focusWithin(id) {
    const target = this._findWithinRoot(id);
    if (target) {
      this._attemptFocus(target);
    }
  },

  _findWithinRoot(id) {
    if (typeof id !== "string" || id === "") return null;

    const candidate = document.getElementById(id);
    if (!candidate || !this.el.contains(candidate)) return null;

    return candidate;
  },

  _attemptFocus(target) {
    if (!target || typeof target.focus !== "function") return;
    target.focus();

    // A `phx-submit` round trip ends with LiveView restoring focus to the
    // control that submitted the form, and that restoration runs *after* hook
    // events are dispatched. Without this re-assertion the user is left on the
    // submit button instead of the first invalid field. Re-assert once on the
    // next frame, and only if something else took focus, so the synchronous
    // behaviour above is unchanged.
    const nextFrame =
      typeof window !== "undefined" && window.requestAnimationFrame;
    if (!nextFrame) return;

    nextFrame(() => {
      if (document.activeElement !== target && document.contains(target)) {
        target.focus();
      }
    });
  },
};

export default FormErrorFocus;
