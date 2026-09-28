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
 * `paint/0` derives every pixel it touches from the DOM's current values and
 * writes only properties the operator is not typing into — it never rewrites a
 * hex field, and it never replaces a node. That is what makes `updated/0` safe:
 * a LiveView patch has already put the server's values in the DOM, so repainting
 * after an update adopts them, and an operator mid-edit is left alone.
 */
import { automaticTextColor, contrastRatio, normalizeHex } from "./route_identity_preview.js";

// The pale-fill edge `RouteIdentity.route_badge/1` puts on a badge whose fill
// is under 3:1 against white, so a previewed near-white route color keeps it.
const BADGE_EDGE = ["ring-1", "ring-inset", "ring-subtle"];
const READABLE_BOX = ["bg-canvas", "text-default"];
const UNREADABLE_BOX = ["border", "border-warning-line", "bg-warning-bg", "text-warning-fg"];

const RouteDetailsEditor = {
  mounted() {
    this.prefix = this.el.dataset.prefix || "";
    this.colorField = this._part("color");
    this.textField = this._part("text");
    this.picker = this._part("color-picker");
    this.wrap = this._part("text-wrap");
    this.box = this._part("contrast");
    this.badge = this._part("contrast-badge")?.firstElementChild;
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
      if (event.target.closest(`[id="${this.prefix}-use-automatic"]`)) this._useAutomatic();
    };
    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("change", this.onInput);
    this.el.addEventListener("click", this.onClick);

    this.paint();
  },

  updated() {
    this.paint();
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("change", this.onInput);
    this.el.removeEventListener("click", this.onClick);
  },

  // Renders every derived part of the field from the DOM's current values.
  paint() {
    const background = this._background();
    const requested = this._requested(background);
    const ratio = background && requested ? contrastRatio(background, requested) : null;
    const usable = ratio !== null;
    const warned = usable && ratio < 4.5;

    // The picker always shows a color the browser can draw; the hex field keeps
    // the operator's own keystrokes and is never written by this hook.
    this.picker.value = `#${background || "FFFFFF"}`;
    this.wrap.classList.toggle("hidden", this._mode() !== "custom");

    this._paintBadge(background, requested, ratio);
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
    if (this._mode() !== "custom") return background ? automaticTextColor(background) : null;

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

    const edge = background ? contrastRatio(background, "FFFFFF") < 3 : false;
    for (const name of BADGE_EDGE) this.badge.classList.toggle(name, edge);

    // An unusable draft color keeps the neutral surface the server rendered for
    // it rather than a color this hook invented for a value it cannot read.
    if (!background) return;

    const foreground = requested && ratio >= 4.5 ? requested : automaticTextColor(background);
    this.badge.style.backgroundColor = `#${background}`;
    this.badge.style.color = `#${foreground}`;

    // The badge shows the route number the operator is typing, when the shared
    // form renders that field under the same prefix. A cleared number keeps the
    // last label until the next server render rather than guessing a fallback
    // string here.
    const number = this.el.ownerDocument.querySelector(`[id="${this.prefix}-short"]`);
    const label = number ? number.value.trim() : "";

    if (label && this.badge.firstChild) this.badge.firstChild.nodeValue = label;
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
