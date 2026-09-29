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
 * Details also owns the dirty-navigation guard (AC-22), adapted from the
 * RoutePatternEditor conventions: the server owns the dirty state and the
 * "Leave without saving?" dialog, and this hook intercepts the departures the
 * browser would otherwise dispatch — same-origin link clicks (tabs, the back
 * button, header and list links), history traversal, a version-option click
 * before the GtfsVersionHook can write the selected-version global state and
 * navigate, and a native `beforeunload` warning for everything else. The guard
 * is armed only when the element carries `data-nav-guard="true"` (Route ›
 * Details); the create drawer mounts the same hook without it and keeps none of
 * this behavior. No second router is installed: intercepted clicks hand the
 * intended path to the LiveView, and the server decides.
 *
 * Both route forms also carry the connectivity recovery (AC-23): a form marked
 * `data-recovery="true"` has its commit controls disabled and its entries left
 * untouched the moment the socket drops, and reconnecting does not re-enable
 * anything by itself — the hook asks the server (the form's recovery event,
 * carrying the signed attempt where one exists) and only clears the block when
 * the server has revalidated scope and permission and answers `retryable`.
 * A `blocked` answer keeps the controls disabled and announces the server's
 * message, so an unverifiable attempt or a removed editor keeps a visible
 * unverified draft instead of a blind save (R2/R3). Only controls this hook
 * disabled are ever re-enabled, so a save that is pending for another reason
 * stays pending.
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

// Register before LiveSocket installs its history listener: a hook mounted
// after connection is too late to stop the socket from starting a history
// redirect. Only the active Details guard answers.
let activeGuard = null;
window.addEventListener(
  "popstate",
  (event) => activeGuard?.popStateHandler?.(event),
  true,
);

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
      this.el.dataset.headingBadge || `${this.prefix}-badge`,
    )?.firstElementChild;
    this.readableIcon = this._part("contrast-icon-ok");
    this.unreadableIcon = this._part("contrast-icon-low");
    this.verdict = this._part("contrast-verdict");
    this.verdictText = this._part("contrast-verdict-text");
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

    if (this.el.dataset.navGuard === "true") this._mountGuard();

    this.recoveryForm = this.el.closest('form[data-recovery="true"]');
    if (this.recoveryForm) this._mountRecovery();

    this.paint();
  },

  // Connectivity recovery (AC-23). The offline block is applied locally the
  // moment the socket drops — a disconnected socket can receive no server
  // push — and it is cleared only by the server's post-revalidation answer,
  // never by the reconnect itself.
  _mountRecovery() {
    this.recoveryEvent =
      this.recoveryForm.dataset.recoveryEvent || "recover_new_route";
    this.offline = false;
    this.recoveryRegion = this.el.ownerDocument.getElementById(
      `${this.prefix}-recovery`,
    );

    this.handleEvent("route_recovery", ({ state, message }) => {
      if (state === "retryable") {
        this._clearOfflineBlock();
        this._announce(
          message ||
            "Connection restored. Your entries are preserved — you can save again.",
        );
      } else {
        this._announce(
          message ||
            "Connection restored, but your changes could not be verified.",
        );
      }
    });
  },

  disconnected() {
    if (!this.recoveryForm) return;
    // The first drop's entries are the ones to keep; a further failed rejoin
    // must not overwrite them with whatever the DOM shows by then.
    if (!this.offline) this.entries = this._readEntries();
    this._applyOffline(true);
  },

  // Reconnecting re-enables nothing: the server must revalidate scope and
  // permission first. The hook only announces the check and asks, carrying the
  // form's signed attempt where the drawer renders one.
  reconnected() {
    if (!this.recoveryForm) return;
    this._restoreEntries();
    this._announce("Connection restored. Checking your work…");
    this.pushEvent(this.recoveryEvent, {
      _attempt:
        this.recoveryForm.querySelector('input[name="_attempt"]')?.value ?? "",
    });
  },

  // The rejoin renders the form from the new server process before LiveView's
  // form recovery replays the entries, and a field the dialog focuses on
  // reopening is skipped by that replay. Putting back what the operator had
  // typed keeps the draft exactly as it was (AC-23); the server revalidates the
  // same values through the recovery event and the form's own submit.
  _readEntries() {
    return Array.from(this.recoveryForm.elements)
      .filter((control) => control.name && control.type !== "hidden")
      .map((control) => ({
        control,
        value: control.value,
        checked: control.checked,
      }));
  },

  _restoreEntries() {
    for (const { control, value, checked } of this.entries || []) {
      if (!control.isConnected) continue;
      if (control.value !== value) control.value = value;
      if (control.checked !== checked) control.checked = checked;
    }

    this.entries = null;
    this.paint();
  },

  // Blocks the form's commit controls and announces the lost connection. The
  // entries themselves are never touched: the draft the operator typed stays
  // exactly as it is, offline or not (AC-23).
  _applyOffline(offline) {
    this.offline = Boolean(offline);

    if (this.offline) {
      this._announce(
        "Connection lost. Your entries are preserved — reconnecting…",
      );
    }

    for (const control of this.recoveryForm.querySelectorAll(
      "button[type='submit']",
    )) {
      if (this.offline) {
        control.dataset.recoveryProtected = "true";
        control.disabled = true;
      } else if (control.dataset.recoveryProtected === "true") {
        delete control.dataset.recoveryProtected;
        control.disabled = false;
      }
    }
  },

  // Only the server's post-revalidation answer reaches here: controls this
  // hook disabled come back, and anything disabled for another reason — a save
  // already in flight — stays as the server rendered it.
  _clearOfflineBlock() {
    this._applyOffline(false);
  },

  _announce(text) {
    if (!this.recoveryRegion) return;

    this.recoveryRegion.textContent = text;
    this.recoveryRegion.hidden = false;
  },

  // The dirty-navigation guard: same interception surface as the route pattern
  // editor, with one addition — a version-option click is stopped before the
  // version hook can dispatch the selection, so cancelling it leaves the
  // selected-version global state and the current URL intact (AC-22).
  _mountGuard() {
    this.dirty = this.el.dataset.dirty === "true";
    this.currentUrl = location.href;
    this.currentHistoryState = history.state;
    activeGuard = this;

    this.beforeUnloadHandler = (event) => {
      if (!this.dirty) return;
      event.preventDefault();
      event.returnValue = "";
      return "";
    };

    this.navigationHandler = (event) => {
      if (
        !this.dirty ||
        event.defaultPrevented ||
        event.button !== 0 ||
        event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey
      )
        return;

      const option = event.target.closest("[data-version-option]");
      if (option) {
        const versionId = option.dataset.versionId;
        const current = location.pathname.match(/^\/gtfs\/([^/]+)/)?.[1];
        if (!versionId || versionId === current) return;

        event.preventDefault();
        event.stopImmediatePropagation();
        this.pushEvent("guard_details_navigation", {
          path: this._versionPath(versionId),
        });
        return;
      }

      const link = event.target.closest("a[href]");
      if (
        !link ||
        link.target === "_blank" ||
        link.hasAttribute("download") ||
        link.dataset.phxLink === "patch"
      )
        return;
      const url = new URL(link.href, location.href);
      if (
        url.origin !== location.origin ||
        (url.pathname === location.pathname && url.search === location.search)
      )
        return;
      event.preventDefault();
      event.stopImmediatePropagation();
      this.pushEvent("guard_details_navigation", {
        path: url.pathname + url.search + url.hash,
      });
    };

    this.navigationCompleteHandler = () => {
      this.currentUrl = location.href;
      this.currentHistoryState = history.state;
    };

    this.popStateHandler = (event) => {
      if (!this.dirty) return;
      const destination = location.pathname + location.search + location.hash;
      event.stopImmediatePropagation();
      history.pushState(this.currentHistoryState, "", this.currentUrl);
      this.pushEvent("guard_details_navigation", { path: destination });
    };

    document.addEventListener("click", this.navigationHandler, true);
    window.addEventListener("beforeunload", this.beforeUnloadHandler);
    window.addEventListener(
      "phx:page-loading-stop",
      this.navigationCompleteHandler,
    );
  },

  _versionPath(versionId) {
    return (
      location.pathname.replace(/^\/gtfs\/[^/]+/, `/gtfs/${versionId}`) +
      location.search +
      location.hash
    );
  },

  updated() {
    this.paint();

    if (this.recoveryForm && this.offline) {
      // A patch that arrived around the reconnect must not unblock what the
      // server has not revalidated yet.
      this._applyOffline(true);
    }

    if (this.el.dataset.navGuard === "true") {
      this.currentUrl = location.href;
      this.currentHistoryState = history.state;
      if (this.el.dataset.dirty !== undefined) {
        this.dirty = this.el.dataset.dirty === "true";
      }
    }
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("change", this.onInput);
    this.el.removeEventListener("click", this.onClick);

    if (this.saveBar && this.form) {
      this.el.ownerDocument.removeEventListener("keydown", this.onKeydown);
    }

    if (this.el.dataset.navGuard === "true") {
      if (activeGuard === this) activeGuard = null;
      document.removeEventListener("click", this.navigationHandler);
      window.removeEventListener(
        "phx:page-loading-stop",
        this.navigationCompleteHandler,
      );
      if (this.beforeUnloadHandler) {
        window.removeEventListener("beforeunload", this.beforeUnloadHandler);
        this.beforeUnloadHandler = null;
      }
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
  // is left as it is — the automatic hex is resolved server-side. The change is
  // announced like the operator's own click on the chip, so the server's draft
  // leaves Custom too and its next render cannot put the chip back.
  _useAutomatic() {
    const automatic = this._part("text-mode-automatic");

    automatic.checked = true;
    automatic.focus();
    automatic.dispatchEvent(new Event("input", { bubbles: true }));
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
    // The verdict label follows the same ratio as the icon and the readout, so
    // the three never disagree between server renders.
    if (this.verdictText && ratio !== null)
      this.verdictText.textContent = warned ? "Hard to read" : "Easy to read";
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
