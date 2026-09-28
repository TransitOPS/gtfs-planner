/**
 * PatternAlignment hook
 *
 * Owns the read-only alignment map inside `#alignment-map-root`
 * (spec 12, steps 23–24). The server renders only the ignored container with
 * `data-tile-url`; every map DOM node below is hook-owned (CR-5).
 *
 * - `mounted` builds the map bar (Pan / Edit points / Undo / Redo), the
 *   Leaflet stage, zoom/fit tools, the hint and the legend, creates `L.map`
 *   on vendored Leaflet 1.9.4 (`window.L`, CR-6) with basemap tiles from the
 *   authenticated `/map/tiles` proxy, registers the `alignment:load` /
 *   `alignment:select` / `alignment:retry_tiles` handlers, then pushes
 *   `alignment_hook_ready`.
 * - `alignment:load` draws one polyline per section (saved kinds in the
 *   model's verbatim `route_color`, missing as a red dashed anchor
 *   connector, blocked dotted), one marker per unique stop location with
 *   its visit label (`1 / 4` for a repeated stop), and fits the pattern.
 *   Draft (unsaved) sections redraw in amber.
 * - Keyboard point list (step 25): the server renders the "Point list"
 *   toggle and an empty ignored `#alignment-point-list` inside
 *   `#alignment-detail` for editable non-missing sections. The hook owns
 *   that container (CR-5): rows with a checkbox and a Locate button per
 *   interior point, Add midpoint and Delete points actions. `toggle_points`
 *   arrives as a DOM `alignment:action` on the hook root; opening the
 *   list from Pan enters Edit points on the editable selected section so
 *   the keyboard path never dead-ends. Marker keydown moves the focused
 *   handle by container pixels (2 px, 10 px with Shift), Space/Enter
 *   toggles its selection, Delete removes it.
 * - Clicking a section pushes `alignment_select_section`; `alignment:select`
 *   widens that polyline with a halo and fits its bounds.
 * - Edit points mode (step 24) shows draggable `L.marker` handles for the
 *   interior points of the selected non-missing section only — stop anchors
 *   are never handles and never move. Clicking the selected line inserts at
 *   `nearestEdgeIndex`; dragging commits on `dragend`; Delete/Backspace
 *   removes the selected handles; Shift-drag box-selects via
 *   `pointsInBounds`; Esc returns to Pan; Ctrl/⌘Z undoes and Shift+Ctrl/⌘Z
 *   redoes. Every commit pushes `alignment_draft_state`.
 * - The first `tileerror` pushes `alignment_map_error` exactly once; a
 *   later `tileload` pushes `alignment_map_ok`. `alignment:retry_tiles`
 *   rebuilds the tile layer so a new failure episode reports again.
 * - `destroyed` removes the map and its listeners.
 *
 * Wire order is `[lon, lat]` everywhere outside Leaflet (INV-1); the only
 * axis swaps are the `toLatLng`/`fromLatLng` calls below.
 */

import {
  fromLatLng,
  nearestEdgeIndex,
  pointsInBounds,
  toLatLng,
} from "./alignment_geometry";

const MISSING_COLOR = "#9b1c1c";
const MISSING_DASH = "8 7";
const BLOCKED_DASH = "2 6";
const UNSAVED_COLOR = "#8a5a0e";
const SAVED_WEIGHT = 4;
const SELECTED_WEIGHT = 6;
const HALO_WEIGHT = 12;
const HALO_OPACITY = 0.25;
const TILE_ATTRIBUTION =
  "Powered by Geoapify | © OpenMapTiles © OpenStreetMap contributors";
const MARKER_ICON_SIZE = 30;
const HANDLE_ICON_SIZE = 44;
const HANDLE_ICON_ANCHOR = HANDLE_ICON_SIZE / 2;
// A click that lands within this window after a drag or a box select is
// treated as the gesture's own click, never as a new insert/select.
const GESTURE_CLICK_SUPPRESS_MS = 300;

function hasCoords(visit) {
  return (
    visit != null &&
    typeof visit.lat === "number" &&
    typeof visit.lon === "number" &&
    Number.isFinite(visit.lat) &&
    Number.isFinite(visit.lon)
  );
}

function pointsEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

const PatternAlignment = {
  mounted() {
    const root = this.el;
    this._destroyed = false;
    this._errorReported = false;
    this._selected = 1;
    this._hideLabels = false;
    this._sectionLayers = new Map();
    this._stopMarkers = [];
    this._bounds = null;
    this._map = null;
    this._tileLayer = null;
    // Step 24 edit state: drafts and undo live in the hook (CR-5). Drafts
    // map position -> {points, op, base, dirty}; undo/redo hold
    // {position, before, after} interior snapshots for this session only.
    this._mode = "pan";
    this._model = null;
    this._drafts = new Map();
    this._undo = [];
    this._redo = [];
    this._handles = [];
    this._selectedPoints = new Set();
    this._dragWorking = null;
    // Step 25 keyboard list: closed until the server toggle opens it. The
    // list DOM lives outside the hook root (see _renderPointList).
    this._pointsOpen = false;
    this._lastDragEnd = 0;
    this._lastBoxEnd = 0;
    this._shiftHeld = false;
    this._box = null;

    root.classList.add("pa-live");
    const loading = root.querySelector("#alignment-map-loading");
    if (loading) loading.remove();

    const L = window.L;
    if (!L) {
      const fallback = document.createElement("p");
      fallback.setAttribute("role", "status");
      fallback.className = "pa-fallback";
      fallback.textContent = "The map could not load.";
      root.appendChild(fallback);
      return;
    }

    root.appendChild(this._buildChrome());
    this._chrome = root.querySelector(".pa-map");

    const mapEl = root.querySelector("[data-pa-leaflet]");
    // If LiveView reused a container that already had Leaflet initialized
    // (e.g. the previous hook's destroyed() did not run before re-mount),
    // Leaflet throws "Map container is already initialized." Reset the
    // internal flag and clear child DOM before creating a new map.
    if (mapEl._leaflet_id) {
      mapEl._leaflet_id = undefined;
      mapEl.innerHTML = "";
    }

    const map = L.map(mapEl, {
      preferCanvas: true,
      zoomControl: false,
      scrollWheelZoom: true,
      dragging: true,
      keyboard: false,
    });
    map.setView([20, 0], 2);
    this._map = map;
    this._addTileLayer();
    this._wireChrome(root);
    // The document listeners below are hook-scoped by checks: keys act
    // only while focus is inside this hook's root, and pointer tracking
    // only while a box select is open.
    this._onKeyDown = (event) => this._handleKey(event);
    this._onKeyUp = (event) => {
      if (event.key === "Shift") {
        this._shiftHeld = false;
        if (this._mode === "edit" && !this._box && this._map) {
          this._map.dragging.enable();
        }
      }
    };
    this._onPointerMove = (event) => this._updateBox(event);
    this._onPointerUp = (event) => this._finishBox(event);
    document.addEventListener("keydown", this._onKeyDown);
    document.addEventListener("keyup", this._onKeyUp);
    document.addEventListener("mousemove", this._onPointerMove);
    document.addEventListener("mouseup", this._onPointerUp);
    // The server "Point list" button dispatches a DOM action (not a
    // LiveView push), following the CalendarDateChange precedent.
    this._onAction = (event) => {
      if (event?.detail?.action === "toggle_points") this._togglePointList();
    };
    root.addEventListener("alignment:action", this._onAction);
    map.on("mousedown", (event) => this._maybeStartBox(event));

    // The server pushes `%{model: ...}` (see the LiveView map test); unwrap
    // it here so a misshapen payload fails loudly in _draw, never as an
    // empty map.
    this.handleEvent("alignment:load", (payload) => this._draw(payload.model));
    this.handleEvent("alignment:select", ({ position }) =>
      this._select(position, true),
    );
    this.handleEvent("alignment:retry_tiles", () => this._retryTiles());

    this.pushEvent("alignment_hook_ready", {});
  },

  destroyed() {
    this._destroyed = true;
    document.removeEventListener("keydown", this._onKeyDown);
    document.removeEventListener("keyup", this._onKeyUp);
    document.removeEventListener("mousemove", this._onPointerMove);
    document.removeEventListener("mouseup", this._onPointerUp);
    this.el?.removeEventListener?.("alignment:action", this._onAction);
    // The point list container is hook-owned but lives outside the root;
    // clear it so no stale rows survive a re-mount.
    this._pointsOpen = false;
    this._renderPointList();
    this._removeBoxOverlay();
    if (this._map) {
      try {
        this._map.remove();
      } catch (_) {
        // Tearing down a half-initialized map must not raise.
      }
      this._map = null;
    }
    // The map teardown leaves the container element behind; the whole
    // chrome subtree is hook-owned, so remove it to leave no Leaflet DOM
    // in the element and to keep a later re-mount from duplicating it.
    if (this._chrome) {
      this._chrome.remove();
      this._chrome = null;
    }
    this._tileLayer = null;
    this._sectionLayers = new Map();
    this._stopMarkers = [];
    this._handles = [];
    this._bounds = null;
  },

  _buildChrome() {
    const wrap = document.createElement("div");
    wrap.className = "pa-map";
    wrap.innerHTML = `
      <div class="pa-bar">
        <div class="pa-bar-group">
          <button type="button" class="btn btn-outline min-h-11" data-pa-pan aria-pressed="true">
            Pan
          </button>
          <button type="button" class="btn btn-outline min-h-11" data-pa-edit disabled title="Point editing arrives with the editing tools">
            Edit points
          </button>
        </div>
        <div class="pa-bar-group">
          <button type="button" class="btn btn-outline min-h-11" data-pa-undo disabled aria-label="Undo" title="Undo">
            Undo
          </button>
          <button type="button" class="btn btn-outline min-h-11" data-pa-redo disabled aria-label="Redo" title="Redo">
            Redo
          </button>
        </div>
      </div>
      <div class="pa-stage" data-pa-stage>
        <div class="pa-leaflet" data-pa-leaflet></div>
        <div class="pa-help">
          <strong>Follow the bus, one section at a time</strong>
          <span>Drag to pan · Select a path to inspect it</span>
        </div>
        <div class="pa-tools" role="group" aria-label="Map tools">
          <button type="button" data-pa-zoom-in aria-label="Zoom in">+</button>
          <button type="button" data-pa-zoom-out aria-label="Zoom out">−</button>
          <button type="button" data-pa-fit aria-label="Fit entire pattern" title="Fit entire pattern">⤢</button>
        </div>
      </div>
      <div class="pa-footer">
        <div class="pa-legend" aria-label="Map legend">
          <span><i data-pa-legend-route></i>Route path</span>
          <span><i data-pa-legend-missing></i>Missing</span>
          <span><i data-pa-legend-unsaved></i>Unsaved</span>
        </div>
        <button type="button" class="pa-toggle-labels" data-pa-toggle-labels aria-pressed="false">Hide stop labels</button>
      </div>
    `;
    return wrap;
  },

  _wireChrome(root) {
    const zoomIn = root.querySelector("[data-pa-zoom-in]");
    const zoomOut = root.querySelector("[data-pa-zoom-out]");
    const fit = root.querySelector("[data-pa-fit]");
    const toggle = root.querySelector("[data-pa-toggle-labels]");
    const pan = root.querySelector("[data-pa-pan]");
    const edit = root.querySelector("[data-pa-edit]");
    const undo = root.querySelector("[data-pa-undo]");
    const redo = root.querySelector("[data-pa-redo]");
    if (zoomIn) zoomIn.addEventListener("click", () => this._map.zoomIn());
    if (zoomOut) zoomOut.addEventListener("click", () => this._map.zoomOut());
    if (fit)
      fit.addEventListener("click", () => {
        if (this._bounds) this._map.fitBounds(this._bounds, { padding: [20, 20] });
      });
    if (toggle)
      toggle.addEventListener("click", () => {
        this._hideLabels = !this._hideLabels;
        root.classList.toggle("pa-hide-labels", this._hideLabels);
        toggle.setAttribute("aria-pressed", String(this._hideLabels));
        toggle.textContent = this._hideLabels ? "Show stop labels" : "Hide stop labels";
      });
    if (pan) pan.addEventListener("click", () => this._setMode("pan"));
    if (edit) edit.addEventListener("click", () => this._setMode("edit"));
    if (undo) undo.addEventListener("click", () => this._undoOnce());
    if (redo) redo.addEventListener("click", () => this._redoOnce());
  },

  _addTileLayer() {
    const L = window.L;
    const layer = L.tileLayer(this.el.dataset.tileUrl, {
      attribution: TILE_ATTRIBUTION,
      maxZoom: 19,
    });
    layer.on("tileerror", () => {
      if (!this._errorReported) {
        this._errorReported = true;
        this.pushEvent("alignment_map_error", {});
      }
    });
    layer.on("tileload", () => {
      if (this._errorReported) {
        this._errorReported = false;
        this.pushEvent("alignment_map_ok", {});
      }
    });
    layer.addTo(this._map);
    this._tileLayer = layer;
  },

  _retryTiles() {
    if (this._destroyed || !this._map || !window.L) return;
    if (this._tileLayer) this._map.removeLayer(this._tileLayer);
    this._errorReported = false;
    this._addTileLayer();
  },

  _draw(model) {
    if (this._destroyed || !this._map || !window.L) return;
    const L = window.L;
    const color = model.route_color;
    this._model = model;
    // A fresh model starts a fresh editing session: drafts, history and
    // the handle selection belong to the previous geometry.
    this._drafts = new Map();
    this._undo = [];
    this._redo = [];
    this._selectedPoints = new Set();
    this._dragWorking = null;
    this._pointsOpen = false;
    this._renderPointList();
    this._removeBoxOverlay();
    this._box = null;
    this._clearOverlays();

    const legendRoute = this.el.querySelector("[data-pa-legend-route]");
    if (legendRoute) legendRoute.style.borderColor = color;

    const visitsByPosition = new Map(
      (model.visits || []).map((visit) => [visit.position, visit]),
    );

    let bounds = null;
    const extend = (latlngs) => {
      const sectionBounds = L.latLngBounds(latlngs);
      bounds = bounds ? bounds.extend(sectionBounds) : sectionBounds;
    };

    for (const section of model.sections || []) {
      const from = visitsByPosition.get(section.position);
      const to = visitsByPosition.get(section.position + 1);
      if (!hasCoords(from) || !hasCoords(to)) continue;

      let latlngs;
      let style;
      if (section.kind === "missing") {
        // A missing section has no saved geometry: draw the straight
        // two-point connector between its stop anchors.
        latlngs = [
          [from.lat, from.lon],
          [to.lat, to.lon],
        ];
        style = { color: MISSING_COLOR, weight: SAVED_WEIGHT, dashArray: MISSING_DASH };
      } else if (section.kind === "blocked") {
        latlngs = [
          [from.lat, from.lon],
          [to.lat, to.lon],
        ];
        style = { color, weight: SAVED_WEIGHT, dashArray: BLOCKED_DASH };
      } else {
        // Interior points travel as [lon, lat]; anchors come from the
        // visits as {lat, lon} (INV-1).
        latlngs = [
          [from.lat, from.lon],
          ...(section.points || []).map(([lon, lat]) => [lat, lon]),
          [to.lat, to.lon],
        ];
        style = { color, weight: SAVED_WEIGHT };
      }

      const line = L.polyline(latlngs, { ...style, interactive: true }).addTo(
        this._map,
      );
      line.on("click", (event) => this._onSectionClick(section.position, event));
      this._sectionLayers.set(section.position, {
        line,
        halo: null,
        latlngs,
        color: style.color,
      });
      extend(latlngs);
    }

    this._drawStopMarkers(model, visitsByPosition, color);

    if (bounds && bounds.isValid()) {
      this._bounds = bounds;
      this._map.fitBounds(bounds, { padding: [20, 20] });
    }
    this._mode = "pan";
    this._select(this._selected, false);
    this._refreshEditChrome();
  },

  _drawStopMarkers(model, visitsByPosition, color) {
    const L = window.L;
    const byLocation = new Map();
    for (const visit of model.visits || []) {
      if (!hasCoords(visit)) continue;
      const key = `${visit.lat},${visit.lon}`;
      if (!byLocation.has(key)) byLocation.set(key, []);
      byLocation.get(key).push(visit);
    }

    for (const visits of byLocation.values()) {
      const first = visits[0];
      const label = visits
        .map((visit) => visit.position)
        .sort((a, b) => a - b)
        .join(" / ");
      const marker = L.marker([first.lat, first.lon], {
        interactive: false,
        keyboard: false,
        icon: L.divIcon({
          className: "pa-div-icon",
          iconSize: [MARKER_ICON_SIZE, MARKER_ICON_SIZE],
          iconAnchor: [MARKER_ICON_SIZE / 2, MARKER_ICON_SIZE / 2],
          html:
            `<span class="pa-stop-pin" style="border-color:${color}">${label}</span>` +
            `<span class="pa-stop-name">${first.name}</span>`,
        }),
      }).addTo(this._map);
      this._stopMarkers.push(marker);
    }
  },

  _select(position, fit) {
    if (!this._map || !window.L) return;
    const L = window.L;
    const entry = this._sectionLayers.get(position);
    if (!entry) return;
    this._selected = position;

    for (const [other, otherEntry] of this._sectionLayers) {
      const selected = other === position;
      if (selected && !otherEntry.halo) {
        otherEntry.halo = L.polyline(otherEntry.latlngs, {
          color: otherEntry.line.options.color,
          weight: HALO_WEIGHT,
          opacity: HALO_OPACITY,
          interactive: false,
        }).addTo(this._map);
        otherEntry.halo.bringToBack();
      } else if (!selected && otherEntry.halo) {
        this._map.removeLayer(otherEntry.halo);
        otherEntry.halo = null;
      }
      const baseWeight = selected ? SELECTED_WEIGHT : SAVED_WEIGHT;
      if (otherEntry.line.options.weight !== baseWeight) {
        otherEntry.line.setStyle({ weight: baseWeight });
      }
    }

    // Handles follow the selection: editing a section that cannot be
    // edited falls back to Pan so no stale handles linger.
    this._selectedPoints = new Set();
    if (this._mode === "edit" && !this._editableSection(position)) {
      this._mode = "pan";
      if (this._map.boxZoom) this._map.boxZoom.enable();
      this.pushDraftState();
    }
    this._rebuildHandles();
    this._refreshEditChrome();
    // The keyboard list names this section's points; re-render it so a
    // server-driven section change never shows the previous section.
    this._renderPointList();

    if (fit) {
      this._map.fitBounds(L.latLngBounds(entry.latlngs), { padding: [30, 30] });
    }
  },

  _clearOverlays() {
    if (!this._map) return;
    for (const { line, halo } of this._sectionLayers.values()) {
      if (halo) this._map.removeLayer(halo);
      this._map.removeLayer(line);
    }
    for (const marker of this._stopMarkers) this._map.removeLayer(marker);
    for (const marker of this._handles) this._map.removeLayer(marker);
    this._sectionLayers = new Map();
    this._stopMarkers = [];
    this._handles = [];
  },

  // --- Point editing (step 24) -------------------------------------------

  _savedSection(position) {
    return (this._model?.sections || []).find(
      (section) => section.position === position,
    );
  },

  _sectionAnchors(position) {
    const visitsByPosition = new Map(
      (this._model?.visits || []).map((visit) => [visit.position, visit]),
    );
    const from = visitsByPosition.get(position);
    const to = visitsByPosition.get(position + 1);
    if (!hasCoords(from) || !hasCoords(to)) return null;
    return { from, to };
  },

  _savedInterior(position) {
    const section = this._savedSection(position);
    return [...(section?.points || [])];
  },

  _effectiveInterior(position) {
    const draft = this._drafts.get(position);
    if (draft) return [...draft.points];
    return this._savedInterior(position);
  },

  _isDirty(position) {
    const draft = this._drafts.get(position);
    return Boolean(draft && draft.dirty);
  },

  // Edit mode is available on the selected section when the model is
  // editable, the section is saved geometry (never missing) and both stop
  // anchors resolve. Blocked sections may be edited: they draw a straight
  // connector with an empty interior, and clicking it inserts the first
  // point.
  _editableSection(position) {
    if (!this._model?.editable) return false;
    const section = this._savedSection(position);
    if (!section || section.kind === "missing") return false;
    return this._sectionAnchors(position) !== null;
  },

  _setMode(mode) {
    if (this._destroyed || !this._map) return;
    if (mode === "edit" && !this._editableSection(this._selected)) return;
    if (this._mode === mode) {
      this._refreshEditChrome();
      return;
    }
    this._mode = mode;
    if (mode === "edit") {
      if (this._map.boxZoom) this._map.boxZoom.disable();
    } else {
      if (this._map.boxZoom) this._map.boxZoom.enable();
      if (!this._box && this._map.dragging) this._map.dragging.enable();
      this._selectedPoints = new Set();
    }
    this._removeBoxOverlay();
    this._box = null;
    this._rebuildHandles();
    this._refreshEditChrome();
    this.pushDraftState();
  },

  _refreshEditChrome() {
    const root = this.el;
    const pan = root.querySelector("[data-pa-pan]");
    const edit = root.querySelector("[data-pa-edit]");
    const undo = root.querySelector("[data-pa-undo]");
    const redo = root.querySelector("[data-pa-redo]");
    const helpTitle = root.querySelector(".pa-help strong");
    const helpSub = root.querySelector(".pa-help span");
    const editing = this._mode === "edit";

    if (pan) {
      pan.setAttribute("aria-pressed", String(!editing));
      // daisyUI btn-outline carries no pressed visual on its own; mark
      // the active mode so the state is visible, not aria-only.
      pan.classList.toggle("btn-active", !editing);
    }
    if (edit) {
      edit.setAttribute("aria-pressed", String(editing));
      edit.classList.toggle("btn-active", editing);
      if (this._editableSection(this._selected)) {
        edit.disabled = false;
        edit.removeAttribute("title");
      } else {
        edit.disabled = true;
        const section = this._savedSection(this._selected);
        edit.title =
          section && section.kind === "missing"
            ? "This section has no saved path yet. Use Draw manually to create one."
            : "Point editing arrives with the editing tools.";
      }
    }
    if (undo) undo.disabled = this._undo.length === 0;
    if (redo) redo.disabled = this._redo.length === 0;
    if (helpTitle) {
      helpTitle.textContent = editing
        ? "Click the line to add a point"
        : "Follow the bus, one section at a time";
    }
    if (helpSub) {
      helpSub.textContent = editing
        ? "Drag points to adjust · Shift-drag to select · Delete to remove"
        : "Drag to pan · Select a path to inspect it";
    }
  },

  _handleIcon(index) {
    const L = window.L;
    const selected = this._selectedPoints.has(index);
    return L.divIcon({
      className: "alignment-handle",
      iconSize: [HANDLE_ICON_SIZE, HANDLE_ICON_SIZE],
      iconAnchor: [HANDLE_ICON_ANCHOR, HANDLE_ICON_ANCHOR],
      html: `<span class="alignment-handle-dot${selected ? " is-selected" : ""}"></span>`,
    });
  },

  _rebuildHandles() {
    if (!this._map || !window.L) return;
    for (const marker of this._handles) this._map.removeLayer(marker);
    this._handles = [];
    if (this._mode !== "edit") return;
    if (!this._editableSection(this._selected)) return;
    const L = window.L;
    const position = this._selected;
    const interior = this._effectiveInterior(position);
    interior.forEach((point, index) => {
      const marker = L.marker(toLatLng(point), {
        draggable: true,
        keyboard: true,
        icon: this._handleIcon(index),
      });
      marker.on("drag", () => this._onHandleDrag(position, index, marker));
      marker.on("dragend", () => this._onHandleDragEnd(position, index, marker));
      marker.on("click", () => this._onHandleClick(index));
      marker.addTo(this._map);
      // Keyboard editing (step 25): Leaflet keyboard markers are plain
      // tabbable divs, so a DOM keydown owns arrows/Space/Delete per
      // handle. In-place selection repaints keep this element (and its
      // listener) alive; rebuilds re-attach below.
      marker.getElement?.()?.addEventListener?.("keydown", (event) =>
        this._onHandleKey(position, index, event),
      );
      this._handles[index] = marker;
    });
  },

  _paintHandleSelection() {
    // Toggle the class on the live icon so the marker DOM (and any
    // in-flight gesture such as a double-click zoom) survives selection.
    this._handles.forEach((marker, index) => {
      const dot = marker?.getElement?.()?.querySelector?.(
        ".alignment-handle-dot",
      );
      if (dot) dot.classList.toggle("is-selected", this._selectedPoints.has(index));
    });
  },

  // Live drag feedback: move the line with the pointer without recording
  // history. The working copy starts lazily here so a missed `dragstart`
  // (touch flows, synthetic events) still commits exactly once on
  // `dragend`.
  _onHandleDrag(position, index, marker) {
    if (this._mode !== "edit" || position !== this._selected) return;
    if (!this._dragWorking || this._dragWorking.position !== position) {
      this._dragWorking = { position, before: this._effectiveInterior(position) };
    }
    const points = [...this._dragWorking.before];
    if (index < 0 || index >= points.length) return;
    points[index] = fromLatLng(marker.getLatLng());
    this._dragWorking.points = points;
    this._previewLine(position, points);
  },

  _onHandleDragEnd(position, index, marker) {
    this._lastDragEnd = Date.now();
    if (this._mode !== "edit" || position !== this._selected) {
      this._dragWorking = null;
      return;
    }
    let points;
    if (this._dragWorking && this._dragWorking.position === position) {
      points = [...(this._dragWorking.points || this._dragWorking.before)];
      const at = fromLatLng(marker.getLatLng());
      if (index >= 0 && index < points.length) points[index] = at;
    } else {
      points = this._effectiveInterior(position);
      if (index >= 0 && index < points.length) {
        points[index] = fromLatLng(marker.getLatLng());
      }
    }
    this._dragWorking = null;
    this._commit(position, points);
  },

  _onHandleClick(index) {
    // A drag release also fires click; the drag already owns that gesture.
    if (Date.now() - this._lastDragEnd < GESTURE_CLICK_SUPPRESS_MS) return;
    if (this._mode !== "edit") return;
    if (this._selectedPoints.has(index)) {
      this._selectedPoints.delete(index);
    } else {
      this._selectedPoints.add(index);
    }
    this._paintHandleSelection();
    this.pushDraftState();
  },

  _onSectionClick(position, event) {
    // A box select that ends over the line fires a click; the box owns it.
    if (Date.now() - this._lastBoxEnd < GESTURE_CLICK_SUPPRESS_MS) return;
    if (
      this._mode === "edit" &&
      position === this._selected &&
      this._editableSection(position) &&
      event &&
      event.latlng
    ) {
      this._insertPoint(position, event.latlng);
      return;
    }
    this.pushEvent("alignment_select_section", { position });
  },

  _insertPoint(position, latlng) {
    const entry = this._sectionLayers.get(position);
    if (!entry) return;
    // `latlngs` are Leaflet-order [lat, lon] pairs as drawn; the insertion
    // index counts edges, so the interior index is one less (anchor first).
    const edgeIndex = nearestEdgeIndex(this._map, latlng, entry.latlngs);
    const interior = this._effectiveInterior(position);
    const at = Math.min(Math.max(edgeIndex - 1, 0), interior.length);
    const next = [...interior];
    next.splice(at, 0, fromLatLng(window.L.latLng(latlng)));
    this._commit(position, next);
    this._selectedPoints = new Set([at]);
    this._paintHandleSelection();
    this.pushDraftState();
  },

  // Record one undo entry for a user-complete gesture (click, dragend,
  // key), then redraw the line, handles and bar and push the draft state.
  _commit(position, points) {
    const before = this._effectiveInterior(position);
    const after = [...points];
    if (pointsEqual(before, after)) return;
    const section = this._savedSection(position);
    const base = this._savedInterior(position);
    let draft = this._drafts.get(position);
    if (!draft) {
      draft = {
        op: "set",
        base,
        revision: section?.revision ? { ...section.revision } : null,
        points: before,
        dirty: false,
      };
      this._drafts.set(position, draft);
    }
    draft.points = after;
    draft.dirty = !pointsEqual(after, draft.base);
    if (!draft.dirty) this._drafts.delete(position);
    this._undo.push({ position, before, after });
    this._redo = [];
    this._refreshSection(position);
    this.pushDraftState();
  },

  _applySnapshot(position, points) {
    const section = this._savedSection(position);
    const base = this._savedInterior(position);
    if (pointsEqual(points, base)) {
      this._drafts.delete(position);
    } else {
      const draft = this._drafts.get(position) || {
        op: "set",
        base,
        revision: section?.revision ? { ...section.revision } : null,
      };
      draft.points = [...points];
      draft.dirty = true;
      this._drafts.set(position, draft);
    }
    this._refreshSection(position);
  },

  _previewLine(position, interior) {
    const entry = this._sectionLayers.get(position);
    const anchors = this._sectionAnchors(position);
    if (!entry || !anchors) return;
    entry.latlngs = this._chainLatLngs(anchors, interior);
    entry.line.setLatLngs(entry.latlngs);
  },

  _chainLatLngs(anchors, interior) {
    return [
      [anchors.from.lat, anchors.from.lon],
      ...interior.map(([lon, lat]) => [lat, lon]),
      [anchors.to.lat, anchors.to.lon],
    ];
  },

  _refreshSection(position) {
    const entry = this._sectionLayers.get(position);
    const anchors = this._sectionAnchors(position);
    if (!entry || !anchors) return;
    entry.latlngs = this._chainLatLngs(anchors, this._effectiveInterior(position));
    entry.line.setLatLngs(entry.latlngs);
    const color = this._isDirty(position) ? UNSAVED_COLOR : entry.color;
    if (entry.line.options.color !== color) entry.line.setStyle({ color });
    if (entry.halo && entry.halo.options.color !== color) {
      entry.halo.setLatLngs(entry.latlngs);
      entry.halo.setStyle({ color });
    }
    this._selectedPoints = new Set(
      [...this._selectedPoints].filter(
        (index) => index < this._effectiveInterior(position).length,
      ),
    );
    this._rebuildHandles();
    this._paintHandleSelection();
    this._refreshEditChrome();
  },

  _undoOnce() {
    const entry = this._undo.pop();
    if (!entry) return;
    this._redo.push(entry);
    // The selection names handles by index; a restored array may be
    // shorter, so clear it and let the next gesture select afresh.
    this._selectedPoints = new Set();
    this._applySnapshot(entry.position, entry.before);
    this.pushDraftState();
  },

  _redoOnce() {
    const entry = this._redo.pop();
    if (!entry) return;
    this._undo.push(entry);
    this._selectedPoints = new Set();
    this._applySnapshot(entry.position, entry.after);
    this.pushDraftState();
  },

  // --- Box selection ------------------------------------------------------

  _maybeStartBox(event) {
    if (this._mode !== "edit") return;
    const original = event?.originalEvent;
    if (!original || !original.shiftKey) return;
    // A handle owns its own gesture; the box only starts on bare map.
    if (original.target?.closest?.(".alignment-handle")) return;
    if (!event.containerPoint) return;
    if (this._map.dragging) this._map.dragging.disable();
    const stage = this.el.querySelector("[data-pa-stage]");
    const overlay = document.createElement("div");
    overlay.className = "pa-select-box";
    overlay.setAttribute("aria-hidden", "true");
    if (stage) stage.appendChild(overlay);
    this._box = { start: event.containerPoint, overlay };
    this._paintBox(event.containerPoint);
    if (original.preventDefault) original.preventDefault();
  },

  _updateBox(event) {
    if (!this._box || !this._map) return;
    const stage = this.el.querySelector("[data-pa-stage]");
    const rect = stage?.getBoundingClientRect();
    // Document mousemove carries client coordinates; translate them into
    // the map container frame so the overlay tracks the pointer.
    const point = rect
      ? { x: event.clientX - rect.left, y: event.clientY - rect.top }
      : { x: event.clientX, y: event.clientY };
    this._paintBox(point);
  },

  _paintBox(point) {
    if (!this._box?.overlay) return;
    const { start } = this._box;
    const left = Math.min(start.x, point.x);
    const top = Math.min(start.y, point.y);
    const width = Math.abs(start.x - point.x);
    const height = Math.abs(start.y - point.y);
    const overlay = this._box.overlay;
    overlay.style.left = `${left}px`;
    overlay.style.top = `${top}px`;
    overlay.style.width = `${width}px`;
    overlay.style.height = `${height}px`;
    this._box.end = point;
  },

  _finishBox(event) {
    if (!this._box || !this._map || !window.L) {
      return;
    }
    const box = this._box;
    this._box = null;
    this._removeBoxOverlay();
    this._lastBoxEnd = Date.now();
    if (this._map.dragging && !this._shiftHeld) this._map.dragging.enable();
    if (!box.end) return;
    const L = window.L;
    const cornerA = this._map.containerPointToLatLng(box.start);
    const cornerB = this._map.containerPointToLatLng(box.end);
    const bounds = L.latLngBounds(cornerA, cornerB);
    const interior = this._effectiveInterior(this._selected);
    this._selectedPoints = pointsInBounds(interior, bounds);
    this._paintHandleSelection();
    this.pushDraftState();
    if (event?.preventDefault) event.preventDefault();
  },

  _removeBoxOverlay() {
    const overlay = this.el?.querySelector(".pa-select-box");
    if (overlay) overlay.remove();
  },

  // --- Keyboard ------------------------------------------------------------

  _handleKey(event) {
    // Keys act only while focus is inside this hook's root, so Delete and
    // Esc never hijack the inspector or dialogs. (There is no
    // `#alignment-workspace` in this task; the hook root is the coherent
    // scope for the same intent.)
    if (!this.el.contains(document.activeElement)) return;
    // Marker keydown owns handle-originated keys (it stopPropagation, but
    // the guard keeps the single-point Delete below from also firing when
    // a focused handle bubbles here).
    if (event.target?.closest?.(".alignment-handle")) return;
    const key = event.key;
    if ((event.ctrlKey || event.metaKey) && (key === "z" || key === "Z")) {
      if (this._mode !== "edit") return;
      event.preventDefault();
      if (event.shiftKey) {
        this._redoOnce();
      } else {
        this._undoOnce();
      }
      return;
    }
    if (key === "Shift") {
      // Holding Shift pre-disables panning so a Shift-drag never pans the
      // map, regardless of listener order on the container.
      this._shiftHeld = true;
      if (this._mode === "edit" && this._map?.dragging) {
        this._map.dragging.disable();
      }
      return;
    }
    if (key === "Escape") {
      if (this._mode !== "edit") return;
      event.preventDefault();
      this._setMode("pan");
      return;
    }
    if (key === "Delete" || key === "Backspace") {
      if (this._mode !== "edit" || this._selectedPoints.size === 0) return;
      event.preventDefault();
      const position = this._selected;
      const doomed = [...this._selectedPoints].sort((a, b) => b - a);
      const interior = this._effectiveInterior(position);
      const next = [...interior];
      for (const index of doomed) {
        // Handles name interior points only; anchors are never in the set.
        if (index >= 0 && index < next.length) next.splice(index, 1);
      }
      this._selectedPoints = new Set();
      this._commit(position, next);
    }
  },

  // --- Keyboard point list (step 25) --------------------------------------
  //
  // The server renders the "Point list" toggle and an empty ignored
  // `#alignment-point-list` inside `#alignment-detail` for editable
  // non-missing sections; the hook owns that container's rows (CR-5).
  // Row anatomy and helper copy follow the prototype's `pointList()`:
  // checkbox + "Point n" label + Locate per interior point, Add midpoint
  // and Delete points with the selected count. Handles are 0-based
  // interior indexes, matching `_selectedPoints`.

  _togglePointList() {
    if (this._destroyed || !this._map) return;
    // The list is the keyboard path into Edit points: opening it from Pan
    // enters edit mode on the editable selected section so the toggle
    // never appears to do nothing.
    if (!this._pointsOpen && this._mode !== "edit") {
      if (!this._editableSection(this._selected)) return;
      this._setMode("edit");
    }
    this._pointsOpen = !this._pointsOpen;
    this._renderPointList();
  },

  _renderPointList() {
    const list = document.getElementById("alignment-point-list");
    const toggle = document.getElementById("alignment-point-list-toggle");
    if (toggle) toggle.setAttribute("aria-expanded", String(this._pointsOpen));
    if (!list) return;
    // Rebuilds drop focus, so remember which list control held it and
    // restore it after the rebuild keeps keyboard users in place.
    const active = document.activeElement;
    const focusKey =
      active && list.contains(active) ? active.dataset?.paListFocus : null;
    const open =
      this._pointsOpen &&
      this._mode === "edit" &&
      this._editableSection(this._selected);
    if (!open) {
      list.innerHTML = "";
      return;
    }
    const interior = this._effectiveInterior(this._selected);
    const selected = this._selectedPoints;
    const rows = interior
      .map(
        (_, index) => `
      <div class="pa-point-row">
        <input type="checkbox" class="checkbox" data-point-check="${index}" id="alignment-point-check-${index}" data-pa-list-focus="check-${index}"${selected.has(index) ? " checked" : ""}>
        <label for="alignment-point-check-${index}">Point ${index + 1}</label>
        <button type="button" class="btn btn-ghost min-h-11" data-focus-point="${index}" data-pa-list-focus="locate-${index}">Locate</button>
      </div>`,
      )
      .join("");
    list.innerHTML = `
      <p class="pa-point-help">Select points here. Arrow keys move a focused map point. End stops are fixed.</p>
      ${rows || '<p class="pa-point-empty">No interior points yet. Use Add midpoint to start.</p>'}
      <div class="pa-point-actions">
        <button type="button" class="btn btn-outline min-h-11" data-add-midpoint data-pa-list-focus="midpoint">Add midpoint</button>
        <button type="button" class="btn btn-outline min-h-11" data-delete-points data-pa-list-focus="delete"${selected.size === 0 ? " disabled" : ""}>Delete points (${selected.size})</button>
      </div>`;
    list.querySelectorAll("[data-point-check]").forEach((box) =>
      box.addEventListener("change", () =>
        this._onListCheck(Number(box.dataset.pointCheck), box.checked),
      ),
    );
    list.querySelectorAll("[data-focus-point]").forEach((button) =>
      button.addEventListener("click", () =>
        this._focusHandle(Number(button.dataset.focusPoint)),
      ),
    );
    list
      .querySelector("[data-add-midpoint]")
      ?.addEventListener("click", () => this._addMidpoint());
    list
      .querySelector("[data-delete-points]")
      ?.addEventListener("click", () => this._deleteSelected());
    if (focusKey) {
      // The invoking control may be gone or disabled now (deleted row,
      // emptied selection): fall back to Add midpoint, never the void.
      let next = list.querySelector(`[data-pa-list-focus="${focusKey}"]`);
      if (!next || next.disabled) {
        next = list.querySelector("[data-add-midpoint]");
      }
      if (next && !next.disabled) next.focus();
    }
  },

  _onListCheck(index, checked) {
    if (this._mode !== "edit" || !this._editableSection(this._selected)) return;
    if (index < 0 || index >= this._effectiveInterior(this._selected).length) {
      return;
    }
    if (checked) {
      this._selectedPoints.add(index);
    } else {
      this._selectedPoints.delete(index);
    }
    this._paintHandleSelection();
    this.pushDraftState();
  },

  // Focuses the map handle for an interior index; true when one exists.
  _focusHandle(index) {
    const element = this._handles[index]?.getElement?.();
    if (!element) return false;
    element.focus();
    return true;
  },

  // Per-handle keys, mirroring the prototype's `map.onkeydown` on
  // `[data-map-point]`: arrows move by container pixels at the current
  // zoom (2 px, 10 px with Shift) through one undoable commit; Space or
  // Enter toggles the selection with the list checkbox following; Delete
  // removes exactly the focused point. Anchors are never in the handle
  // set, so Delete cannot remove them (INV-1).
  _onHandleKey(position, index, event) {
    if (this._mode !== "edit" || position !== this._selected) return;
    const marker = this._handles[index];
    if (!marker || !this._map) return;
    const key = event.key;
    if (
      key === "ArrowUp" ||
      key === "ArrowDown" ||
      key === "ArrowLeft" ||
      key === "ArrowRight"
    ) {
      event.preventDefault();
      event.stopPropagation();
      const step = event.shiftKey ? 10 : 2;
      const dx = key === "ArrowRight" ? step : key === "ArrowLeft" ? -step : 0;
      const dy = key === "ArrowDown" ? step : key === "ArrowUp" ? -step : 0;
      const at = this._map.latLngToContainerPoint(marker.getLatLng());
      const next = this._map.containerPointToLatLng(
        window.L.point(at.x + dx, at.y + dy),
      );
      const points = this._effectiveInterior(position);
      if (index < 0 || index >= points.length) return;
      marker.setLatLng(next);
      points[index] = fromLatLng(next);
      this._commit(position, points);
      // The commit rebuilds the handles; keep the keyboard on the moved
      // point so repeated presses keep working.
      this._focusHandle(index);
      return;
    }
    if (key === " " || key === "Enter") {
      event.preventDefault();
      event.stopPropagation();
      if (this._selectedPoints.has(index)) {
        this._selectedPoints.delete(index);
      } else {
        this._selectedPoints.add(index);
      }
      this._paintHandleSelection();
      this.pushDraftState();
      return;
    }
    if (key === "Delete" || key === "Backspace") {
      event.preventDefault();
      event.stopPropagation();
      this._deletePoint(index);
    }
  },

  // Inserts the midpoint of the first edge: first anchor to first
  // interior point, or second anchor when the interior is empty.
  _addMidpoint() {
    if (this._mode !== "edit" || !this._editableSection(this._selected)) return;
    const L = window.L;
    if (!L) return;
    const position = this._selected;
    const anchors = this._sectionAnchors(position);
    if (!anchors) return;
    const interior = this._effectiveInterior(position);
    const before = L.latLng(anchors.from.lat, anchors.from.lon);
    // toLatLng returns [lat, lon]; L.latLng accepts that pair verbatim.
    const after =
      interior.length > 0
        ? L.latLng(toLatLng(interior[0]))
        : L.latLng(anchors.to.lat, anchors.to.lon);
    const mid = L.latLng(
      (before.lat + after.lat) / 2,
      (before.lng + after.lng) / 2,
    );
    this._commit(position, [fromLatLng(mid), ...interior]);
    this._selectedPoints = new Set([0]);
    this._paintHandleSelection();
    this.pushDraftState();
    this._focusHandle(0);
  },

  // Removes exactly one interior point; the selection names indexes, so
  // it clears and the keyboard lands on the point now at that index, or
  // on Add midpoint when none remains.
  _deletePoint(index) {
    const position = this._selected;
    const interior = this._effectiveInterior(position);
    if (index < 0 || index >= interior.length) return;
    const next = [...interior];
    next.splice(index, 1);
    this._selectedPoints = new Set();
    this._commit(position, next);
    if (!this._focusHandle(index)) {
      document
        .getElementById("alignment-point-list")
        ?.querySelector("[data-add-midpoint]")
        ?.focus();
    }
  },

  // Removes every selected interior point; the button label carries the
  // selected count and the button stays disabled at zero.
  _deleteSelected() {
    if (this._selectedPoints.size === 0) return;
    const position = this._selected;
    const doomed = [...this._selectedPoints].sort((a, b) => b - a);
    const next = this._effectiveInterior(position);
    for (const index of doomed) {
      if (index >= 0 && index < next.length) next.splice(index, 1);
    }
    this._selectedPoints = new Set();
    this._commit(position, next);
  },

  // --- Draft state ---------------------------------------------------------

  dirtyPositions() {
    return [...this._drafts.entries()]
      .filter(([, draft]) => draft.dirty)
      .map(([position]) => position)
      .sort((a, b) => a - b);
  },

  pushDraftState() {
    if (this._destroyed) return;
    // Every draft-affecting gesture funnels through here, so the keyboard
    // list re-renders on the same beat (selection, counts, open state).
    // Focus inside the list survives via _renderPointList's restore.
    this._renderPointList();
    this.pushEvent("alignment_draft_state", {
      dirty_positions: this.dirtyPositions(),
      selected: this._selected,
      mode: this._mode,
      selected_point_count: this._selectedPoints.size,
      point_count: this._effectiveInterior(this._selected).length,
      can_undo: this._undo.length > 0,
      can_redo: this._redo.length > 0,
      flagged_positions: [],
      review_positions: [],
    });
  },
};

export default PatternAlignment;
export { MISSING_COLOR, MISSING_DASH, BLOCKED_DASH, UNSAVED_COLOR };
