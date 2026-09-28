/**
 * PatternAlignment hook
 *
 * Owns the read-only alignment map inside `#alignment-map-root`
 * (spec 12, step 23). The server renders only the ignored container with
 * `data-tile-url`; every map DOM node below is hook-owned (CR-5).
 *
 * - `mounted` builds the map bar (Pan / Edit-points placeholders for
 *   step 24), the Leaflet stage, zoom/fit tools, the hint and the legend,
 *   creates `L.map` on vendored Leaflet 1.9.4 (`window.L`, CR-6) with
 *   basemap tiles from the authenticated `/map/tiles` proxy, registers the
 *   `alignment:load` / `alignment:select` / `alignment:retry_tiles`
 *   handlers, then pushes `alignment_hook_ready`.
 * - `alignment:load` draws one polyline per section (saved kinds in the
 *   model's verbatim `route_color`, missing as a red dashed anchor
 *   connector, blocked dotted), one marker per unique stop location with
 *   its visit label (`1 / 4` for a repeated stop), and fits the pattern.
 * - Clicking a section pushes `alignment_select_section`; `alignment:select`
 *   widens that polyline with a halo and fits its bounds.
 * - The first `tileerror` pushes `alignment_map_error` exactly once; a
 *   later `tileload` pushes `alignment_map_ok`. `alignment:retry_tiles`
 *   rebuilds the tile layer so a new failure episode reports again.
 * - `destroyed` removes the map and its listeners.
 *
 * Wire order is `[lon, lat]` everywhere outside Leaflet (INV-1); the only
 * axis swaps are the literal `[lat, lon]` constructions below.
 */

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

function hasCoords(visit) {
  return (
    visit != null &&
    typeof visit.lat === "number" &&
    typeof visit.lon === "number" &&
    Number.isFinite(visit.lat) &&
    Number.isFinite(visit.lon)
  );
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
      line.on("click", () =>
        this.pushEvent("alignment_select_section", {
          position: section.position,
        }),
      );
      this._sectionLayers.set(section.position, { line, halo: null, latlngs });
      extend(latlngs);
    }

    this._drawStopMarkers(model, visitsByPosition, color);

    if (bounds && bounds.isValid()) {
      this._bounds = bounds;
      this._map.fitBounds(bounds, { padding: [20, 20] });
    }
    this._select(this._selected, false);
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
    this._sectionLayers = new Map();
    this._stopMarkers = [];
  },
};

export default PatternAlignment;
export { MISSING_COLOR, MISSING_DASH, BLOCKED_DASH, UNSAVED_COLOR };
