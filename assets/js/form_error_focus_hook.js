const FOCUS_FORM_ERROR_EVENT = "focus_form_error";
// Some outcomes have no form and no invalid field — a rollback that succeeded,
// failed, or was superseded still has to land focus somewhere useful. Those
// pushes name their target directly. The containment check below is what keeps
// this scoped: a hook only ever focuses an element it already owns, so a
// broadcast event cannot pull focus into an unrelated region of the page.
const FOCUS_SCOPED_TARGET_EVENT = "focus_scoped_target";
const INVALID_CONTROL_SELECTOR = '[aria-invalid="true"]';
const NATIVE_CONTROL_SELECTOR = "input, select, textarea, button";
const ENABLED_CONTROL_SELECTOR =
  "input:not([disabled]), select:not([disabled]), textarea:not([disabled]), button:not([disabled])";
// LiveView's own focus restoration during a round trip can only land on a form
// control: the select or textual input it restores, or the submit button it
// re-enables. A reader who deliberately moved focus to anything else (a
// floorplan pathway, a heading) keeps it; re-asserting over that move is what
// a keyboard user experiences as focus being pulled away.
const RESTORED_FORM_CONTROLS = new Set(["BUTTON", "INPUT", "SELECT", "TEXTAREA"]);

const FormErrorFocus = {
  mounted() {
    this.handleEvent(FOCUS_FORM_ERROR_EVENT, (payload) => {
      this._focusFormError(payload || {});
    });

    this.handleEvent(FOCUS_SCOPED_TARGET_EVENT, (payload) => {
      this._focusWithin((payload || {}).id);
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
      this._attemptFocus(this._controlFor(invalid));
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

  // A grouped control (a fieldset of checkboxes or radios) carries the invalid
  // state but is not focusable itself, so focus its first enabled control.
  _controlFor(invalid) {
    if (invalid.matches(NATIVE_CONTROL_SELECTOR)) return invalid;
    return invalid.querySelector(ENABLED_CONTROL_SELECTOR) || invalid;
  },

  _findWithinRoot(id) {
    if (typeof id !== "string" || id === "") return null;

    const candidate = document.getElementById(id);
    if (!candidate || !this.el.contains(candidate)) return null;

    return candidate;
  },

  _attemptFocus(target) {
    if (!target || typeof target.focus !== "function") return;

    // A control inside a closed disclosure cannot take focus; the error is the
    // reason to open it.
    const closed = target.closest("details:not([open])");
    if (closed) closed.open = true;

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
      const thief = document.activeElement;

      if (thief === target || !document.contains(target)) return;
      if (thief && RESTORED_FORM_CONTROLS.has(thief.tagName)) target.focus();
    });
  },
};

export default FormErrorFocus;
