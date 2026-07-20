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
  },
};

export default FormErrorFocus;
