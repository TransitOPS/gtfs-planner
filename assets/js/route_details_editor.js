/**
 * Local preview mechanics for the shared route color field
 * (`GtfsPlannerWeb.Gtfs.RouteFormComponents.color_fields/1`, spec 16, step 20).
 *
 * The server renders the whole readout — picker value, checked mode chip,
 * contrast verdict, ratio, fallback note, badge — from the form's own values,
 * and this hook keeps it live while the operator types: the hex field drives
 * the picker, the picker drives the hex field, and the readout is recomputed
 * with the same helpers the server used, so the two cannot disagree.
 *
 * Nothing here reaches the server. Both hex fields carry `phx-debounce="blur"`
 * and submit plain hex values, the automatic hex is resolved by
 * `Route.editor_changeset/3`, and a preview never establishes a saved value
 * (R7, C-2, INV-6).
 *
 * On Route › Details the same hook also keeps the route's own heading badge in
 * step with the color field, so the badge, the contrast readout and the badge in
 * it show one color the instant it is typed (AC-19), and it wires Ctrl/Cmd+S to
 * the form's ordinary submit so the shortcut is one normal submission of the
 * same draft rather than a second save path (AC-21). Both are gated on the
 * Details save bar, which only Route › Details renders: the create drawer mounts
 * the same color field and keeps its own submit untouched.
 *
 * `paint/0` derives every pixel it touches from the DOM's current values and
 * writes only properties the operator is not typing into — it never rewrites a
 * hex field, and it never replaces a node. That is what makes `updated/0` safe:
 * a LiveView patch has already put the server's values in the DOM, so repainting
 * after an update adopts them, and an operator mid-edit is left alone.
 */
import {
  automaticTextColor,
  contrastRatio,
  normalizeHex,
} from "./route_identity_preview.js";

// The pale-fill edge `RouteIdentity.route_badge/1` puts on a badge whose fill
// is under 3:1 against white, so a previewed near-white route color keeps it.
const BADGE_EDGE = ["ring-1", "ring-inset", "ring-subtle"];
const READABLE_BOX = ["bg-canvas", "text-default"];
const UNREADABLE_BOX = [
  "border",
  "border-warning-line",
  "bg-warning-bg",
  "text-warning-fg",
];

const RouteDetailsEditor = {
  mounted() {
    this.prefix = this.el.dataset.prefix || "";
    this.colorField = this._part("color");
    this.textField = this._part("text");
    this.picker = this._part("color-picker");
    this.wrap = this._part("text-wrap");
    this.box = this._part("contrast");
    this.badge = this._part("contrast-badge")?.firstElementChild;
    // The heading badge is the route header's own badge, rendered outside this
    // color field, so it is found in the document like the save bar below.
    this.headingBadge = this.el.ownerDocument.getElementById(
      `${this.prefix}-badge`,
    )?.firstElementChild;
    this.readableIcon = this._part("contrast-icon-ok");
    this.unreadableIcon = this._part("contrast-icon-low");
    this.verdict = this._part("contrast-verdict");
    this.ratio = this._part("contrast-ratio");
    this.advice = this._part("contrast-advice");

    // One delegated listener for every field and both mode chips; the picker is
    // the only control that writes back into another control.
    this.onInput = (event) => {
      if (event.target === this.picker) this._pick();
      this.paint();
    };
    this.onClick = (event) => {
      if (event.target.closest(`[id="${this.prefix}-use-automatic"]`))
        this._useAutomatic();
    };
    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("change", this.onInput);
    this.el.addEventListener("click", this.onClick);

    // Ctrl/Cmd+S submits the draft the server has acknowledged, through the
    // form's own submit event: the same event the Save changes button emits, so
    // there is one save path. A hidden bar means nothing to save, and a disabled
    // submit is one already in flight, which must not be repeated (AC-21).
    // Step 24 owns what that submit does; this hook only emits it.
    this.saveBar = this.el.ownerDocument.getElementById(
      `${this.prefix}-save-bar`,
    );
    this.form = this.el.closest("form");

    this.onKeydown = (event) => {
      if (!this.saveBar || !this.form) return;
      if (!(event.ctrlKey || event.metaKey) || event.key.toLowerCase() !== "s")
        return;

      event.preventDefault();

      const save = this.saveBar.querySelector("button[type='submit']");
      if (this.saveBar.hidden || !save || save.disabled) return;

      this.form.requestSubmit(save);
    };

    if (this.saveBar && this.form) {
      this.el.ownerDocument.addEventListener("keydown", this.onKeydown);
    }

    this.paint();
  },

  updated() {
    this.paint();
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("change", this.onInput);
    this.el.removeEventListener("click", this.onClick);

    if (this.saveBar && this.form) {
      this.el.ownerDocument.removeEventListener("keydown", this.onKeydown);
    }
  },

  // Renders every derived part of the field from the DOM's current values.
  paint() {
    const background = this._background();
    const requested = this._requested(background);
    const ratio =
      background && requested ? contrastRatio(background, requested) : null;
    const usable = ratio !== null;
    const warned = usable && ratio < 4.5;

    // The picker always shows a color the browser can draw; the hex field keeps
    // the operator's own keystrokes and is never written by this hook.
    this.picker.value = `#${background || "FFFFFF"}`;
    this.wrap.classList.toggle("hidden", this._mode() !== "custom");

    this._paintBadge(background, requested, ratio);
    this._paintHeadingBadge(background, requested, ratio);
    this._paintBox(warned, ratio);
  },

  // The picker's value is the hex field's value, without the leading "#" the
  // field decorates itself with. Selecting a color is not a save: the field
  // still submits, and the server still validates what arrives.
  _pick() {
    this.colorField.value = this.picker.value.slice(1).toUpperCase();
  },

  // The one-click fix: check Automatic and put focus on the chip it selected, so
  // the change is visible and the operator keeps a focus target. The hex field
  // is left as it is — the automatic hex is resolved server-side.
  _useAutomatic() {
    const automatic = this._part("text-mode-automatic");

    automatic.checked = true;
    automatic.focus();
    this.paint();
  },

  // A blank route color saves as white (R1's normalization); a color the server
  // will reject has no preview, and its error line is the truth.
  _background() {
    const raw = this.colorField.value.trim();
    return raw === "" ? "FFFFFF" : normalizeHex(raw);
  },

  // What the operator asked for: the automatic pick, or the custom hex — blank
  // being the R1 default of 000000, exactly as the server renders it.
  _requested(background) {
    if (this._mode() !== "custom")
      return background ? automaticTextColor(background) : null;

    const raw = this.textField.value.trim();
    return raw === "" ? "000000" : normalizeHex(raw);
  },

  _mode() {
    const checked = this.el.querySelector('input[name="text_mode"]:checked');
    return checked ? checked.value : "automatic";
  },

  // The same foreground the application badge picks: the requested color when
  // it is readable, otherwise the automatic one.
  _paintBadge(background, requested, ratio) {
    if (!this.badge) return;

    this._paintRouteBadge(this.badge, background, requested, ratio);

    // The badge shows the route number the operator is typing, when the shared
    // form renders that field under the same prefix. A cleared number keeps the
    // last label until the next server render rather than guessing a fallback
    // string here.
    const label = this._label();

    if (label && this.badge.firstChild) this.badge.firstChild.nodeValue = label;
  },

  // The Details heading badge is the route's own identity, so a changed color
  // shows there at once, with the route number the operator is typing.
  _paintHeadingBadge(background, requested, ratio) {
    if (!this.headingBadge) return;

    this._paintRouteBadge(this.headingBadge, background, requested, ratio);

    const label = this._label();

    if (label && this.headingBadge.firstChild)
      this.headingBadge.firstChild.nodeValue = label;
  },

  // The pixels `RouteIdentity.route_badge/1` decides: the route color, its
  // readable-or-automatic foreground, and the subtle edge a near-white fill
  // needs. A color the server would reject has no preview at all, so the badge
  // keeps the surface the server rendered for it.
  _paintRouteBadge(el, background, requested, ratio) {
    if (!background) return;

    const edge = contrastRatio(background, "FFFFFF") < 3;
    for (const name of BADGE_EDGE) el.classList.toggle(name, edge);

    const foreground =
      requested && ratio >= 4.5 ? requested : automaticTextColor(background);
    el.style.backgroundColor = `#${background}`;
    el.style.color = `#${foreground}`;
  },

  _label() {
    const number = this.el.ownerDocument.querySelector(
      `[id="${this.prefix}-short"]`,
    );
    return number ? number.value.trim() : "";
  },

  _paintBox(warned, ratio) {
    for (const name of READABLE_BOX) this.box.classList.toggle(name, !warned);
    for (const name of UNREADABLE_BOX) this.box.classList.toggle(name, warned);

    this.readableIcon.classList.toggle("hidden", warned);
    this.unreadableIcon.classList.toggle("hidden", !warned);
    this.verdict.classList.toggle("hidden", ratio === null);
    this.advice.classList.toggle("hidden", !warned);

    this.ratio.textContent =
      ratio === null
        ? "–:1 contrast"
        : `${ratio.toFixed(1)}:1 contrast${warned ? ", below 4.5:1" : ""}`;
  },

  _part(suffix) {
    return this.el.querySelector(`[id="${this.prefix}-${suffix}"]`);
  },
};

export default RouteDetailsEditor;
