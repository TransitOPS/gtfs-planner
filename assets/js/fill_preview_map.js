/**
 * FillPreviewMapHook
 *
 * Owns the Running times fill panel's read-only "On the map" preview: one
 * marker per visit and one line per section, drawn from the server payload so
 * the planner can see which stops get estimates and which sections have no
 * path yet. The server renders the payload and the legend; this hook only
 * draws what the payload already says and never invents geometry (INV-4).
 *
 * Required data-* attrs on the hook root element:
 *   data-fill-map  fill_map_payload/4 as JSON: `{stops: [{position, name,
 *                coord: [lon, lat] | null, kind: "timepoint" | "estimate" |
 *                "blocked" | "blank" | "stop", label: "HH:MM" | null}],
 *                sections: [{from, to, points: [[lon, lat]], source:
 *                "path" | "straight"}]}`. Coordinates are `[lon, lat]` JSON
 *                numbers (INV-4); conversion to Leaflet `[lat, lon]` happens
 *                only in `leafletLatLng/1`.
 *
 * The container is `phx-update="ignore"`, so the server never patches inside
 * it; the `data-*` attribute itself is patched, and a hook on an ignored
 * container receives `updated()` whenever its dataset changed. Every preview
 * change (scope, method, anchor) redraws in place and refits; the map object
 * itself is created once in `mounted()` and removed in `destroyed()`.
 *
 * Marker vocabulary (the prototype's rt-fill states): timepoints are squares,
 * estimates are dashed circles, blocked stops are warning circles, every
 * other stop is a plain circle. Path sections draw solid; straight sections
 * (no path on the map) draw dashed in the warning tone. Clicking a section
 * fits the map to that section's bounds.
 *
 * This is an external-runtime boundary: window.L (Leaflet) and the
 * authenticated tile proxy `/map/tiles/osm-bright/:z/:x/:y` (same-origin
 * cookies ride along, via `basemap_layers.js`). A missing Leaflet degrades
 * to a one-line message without an exception; the panel stays usable and a
 * failed tile keeps every vector on screen. Keyboard zoom uses the Leaflet
 * defaults and markers stay out of the tab order, so there is no focus trap.
 */

import { addStreetBasemap } from "./basemap_layers";

const FIT_PADDING = [24, 24];
const FIT_MAX_ZOOM = 17;
const SINGLE_POINT_ZOOM = 15;
const WORLD_CENTER = [20, 0];
const WORLD_ZOOM = 2;

const LINE_WEIGHT = 4;
const CASING_WEIGHT = 8;
const CASING_COLOR = "#ffffff";
const PATH_COLOR = "#0f1a3d";
const STRAIGHT_COLOR = "#8a5a0e";
const STRAIGHT_DASH_ARRAY = "8 6";

const ERROR_MESSAGE_ID = "fill-map-error";

// `[lon, lat]` at the model boundary, `[lat, lon]` for Leaflet — the explicit
// conversion INV-4 asks for. Only finite JSON numbers pass: anything else
// (null, a string, NaN) is corrupt input that must never become a drawn
// point at (0, 0).
export function leafletLatLng(coordinates) {
  if (!Array.isArray(coordinates) || coordinates.length !== 2) return null;
  const lon = coordinates[0];
  const lat = coordinates[1];
  if (
    typeof lon !== "number" ||
    !Number.isFinite(lon) ||
    typeof lat !== "number" ||
    !Number.isFinite(lat)
  ) {
    return null;
  }
  return [lat, lon];
}

// The `data-fill-map` payload. `stops` is required; `sections` defaults to
// empty so a panel without alignment geometry still draws its visits.
export function parsePayload(raw) {
  if (typeof raw !== "string" || raw === "") return null;

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_error) {
    return null;
  }

  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.stops)) {
    return null;
  }
  if (
    parsed.sections !== undefined &&
    !Array.isArray(parsed.sections)
  ) {
    return null;
  }

  return { stops: parsed.stops, sections: parsed.sections || [] };
}

// One marker per visit with coordinates, not per stop name: a repeated stop
// keeps one marker per occurrence position. Visits without coordinates are
// never drawn and never fabricated.
export function visitMarkers(stops) {
  const markers = [];

  for (const stop of stops || []) {
    const latlng = leafletLatLng(stop?.coord);
    if (!latlng) continue;
    markers.push({
      key: `visit-${stop.position}`,
      position: stop.position,
      name: stop?.name || `stop ${stop.position}`,
      label: typeof stop?.label === "string" ? stop.label : null,
      kind: stop?.kind || "stop",
      latlng,
    });
  }

  return markers;
}

// One line per section with at least two valid points. A `straight` section
// (no path on the map) draws dashed in the warning tone; a `path` section
// draws solid.
export function sectionPaths(sections) {
  const paths = [];

  for (const section of sections || []) {
    const rawPoints = Array.isArray(section?.points) ? section.points : [];
    const latlngs = rawPoints.map(leafletLatLng).filter(Boolean);
    if (latlngs.length < 2 || latlngs.length !== rawPoints.length) continue;
    paths.push({
      key: `section-${section.from}-${section.to}`,
      from: section.from,
      to: section.to,
      kind: section?.source === "straight" ? "dashed" : "solid",
      latlngs,
    });
  }

  return paths;
}

// The prototype's marker vocabulary as divIcon classes. Unknown kinds fall
// back to the plain stop so a new server kind can never leave a visit
// unmarked.
export function markerClass(kind) {
  switch (kind) {
    case "timepoint":
      return "fill-preview-timepoint";
    case "estimate":
      return "fill-preview-estimate";
    case "blocked":
      return "fill-preview-blocked";
    default:
      return "fill-preview-stop";
  }
}

export function markerHtml(marker) {
  const label = markerClass(marker.kind);
  return (
    `<span class="fill-preview-marker ${label} flex h-[22px] w-[22px] ` +
    `items-center justify-center text-[11px] font-bold tabular-nums">${marker.position}</span>`
  );
}

export function markerTooltip(marker) {
  if (marker.label) return `${marker.name} · ${marker.label}`;
  return `${marker.name} · no time`;
}

const FillPreviewMapHook = {
  mounted() {
    this._destroyed = false;
    this._payloadRaw = null;
    this._sectionLayers = [];

    const L = window.L;
    if (!L) {
      console.error(
        "FillPreviewMapHook: window.L (Leaflet) is not available; " +
          "the fill panel remains usable without the map preview",
      );
      this._showError();
      return;
    }
    this._L = L;

    // If LiveView reused a container that already had Leaflet initialized,
    // reset the flag and clear the child DOM first (MapAlignment precedent).
    if (this.el._leaflet_id) {
      this.el._leaflet_id = undefined;
      this.el.innerHTML = "";
    }

    this._map = L.map(this.el, {
      // A 320px panel that stole the wheel would trap page scroll, so the
      // wheel leaves the map alone and the zoom control (plus keyboard, left
      // at the Leaflet default) zooms instead.
      scrollWheelZoom: false,
    });
    this._map.setView(WORLD_CENTER, WORLD_ZOOM);

    addStreetBasemap(L, this._map);

    this._markers = L.layerGroup().addTo(this._map);
    this._sections = L.layerGroup().addTo(this._map);

    this._draw();
  },

  updated() {
    if (this._destroyed || !this._map) return;
    // The map object is never re-created here: a preview change redraws the
    // same layers and refits.
    this._draw();
  },

  destroyed() {
    this._destroyed = true;
    this._sectionLayers = [];

    if (this._map) {
      try {
        this._map.remove();
      } catch (_error) {
        /* container reused by a newer instance */
      }
      this._map = null;
    }
  },

  _payload() {
    const raw =
      typeof this.el.dataset.fillMap === "string"
        ? this.el.dataset.fillMap
        : "";
    if (raw === this._payloadRaw) return "unchanged";
    this._payloadRaw = raw;
    return parsePayload(raw);
  },

  _draw() {
    const payload = this._payload();
    if (payload === "unchanged" || !payload) return;

    this._markers.clearLayers();
    this._sections.clearLayers();
    this._sectionLayers = [];

    for (const marker of visitMarkers(payload.stops)) {
      this._L
        .marker(marker.latlng, {
          keyboard: false,
          icon: this._L.divIcon({
            className: "fill-preview-icon",
            html: markerHtml(marker),
            iconSize: [22, 22],
            iconAnchor: [11, 11],
          }),
        })
        .bindTooltip(markerTooltip(marker), { direction: "top" })
        .addTo(this._markers);
    }

    for (const path of sectionPaths(payload.sections)) {
      const under = this._L.polyline(path.latlngs, {
        color: CASING_COLOR,
        weight: CASING_WEIGHT,
        opacity: 0.9,
        interactive: false,
      });
      const line = this._L.polyline(path.latlngs, {
        color: path.kind === "dashed" ? STRAIGHT_COLOR : PATH_COLOR,
        weight: LINE_WEIGHT,
        opacity: 1,
        dashArray: path.kind === "dashed" ? STRAIGHT_DASH_ARRAY : null,
        lineCap: "round",
      });
      line.on("click", () => this._fitSection(line));
      under.addTo(this._sections);
      line.addTo(this._sections);
      this._sectionLayers.push(line);
    }

    this._fit();
  },

  _fit() {
    if (!this._map || !this._L) return;

    const latlngs = this._sectionLayers.flatMap((line) =>
      line.getLatLngs(),
    );
    if (latlngs.length > 1) {
      this._map.fitBounds(this._L.latLngBounds(latlngs), {
        padding: FIT_PADDING,
        maxZoom: FIT_MAX_ZOOM,
        animate: false,
      });
    } else if (latlngs.length === 1) {
      this._map.setView(latlngs[0], SINGLE_POINT_ZOOM, { animate: false });
    }
  },

  _fitSection(line) {
    if (!this._map || !this._L) return;
    this._map.fitBounds(this._L.latLngBounds(line.getLatLngs()), {
      padding: FIT_PADDING,
      maxZoom: FIT_MAX_ZOOM,
      animate: false,
    });
  },

  _showError() {
    const message = document.getElementById(ERROR_MESSAGE_ID);
    if (message) message.hidden = false;
  },
};

export default FillPreviewMapHook;
