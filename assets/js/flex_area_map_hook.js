/**
 * FlexAreaMap
 *
 * Owns every read-only flex map: the list's "Where flex runs" card, the service
 * page's map (step 22) and the area editor's map (step 24, read-only until
 * step 25). The server renders the hook root (`#flex-list-map`) with a
 * `.flex-map-stage` container inside it and, outside the root, the legend; the
 * root is `phx-update="ignore"`, so this hook owns the stage for the life of the
 * mount and tears every Leaflet object down in destroyed().
 *
 * Protocol:
 *   hook → server  flex_map_ready {} → server → hook  flex_map:load {payload}
 *
 * Payload (built by `GtfsPlanner.Gtfs.Flex.map_payload/2`):
 *   areas  [{id, geojson, role?}]  one stored area per entry. `role` is
 *                                  "selected" | "other" | "overlap" and adds
 *                                  that treatment; an entry without a role
 *                                  (the list, where every area it draws is
 *                                  equally in play) gets the plain one.
 *   routes [{id, color, coordinates}]  one line per route; `coordinates` are
 *                                  [lon, lat], converted with `toLatLng/1`.
 *   stops  [{id, name, lon, lat, hub}]  `hub` picks the connecting-stop glyph
 *                                  and its always-on label.
 *
 * The basemap is streets, through the app's own Geoapify proxy, so a flex area
 * is read against the roads it covers and no key reaches the browser. A failed
 * tile changes nothing here: the areas, lines and stops stay drawn over a blank
 * background, which is what the card shows in the browser tests.
 *
 * Read-only: no layer is interactive, so a drag or a wheel is the map's own
 * gesture. Leaflet keeps its default zoom control (keyboard reachable) and its
 * attribution control (the tile credit stays visible).
 */

import { addStreetBasemap, STREET_MAX_ZOOM } from "./basemap_layers";
import { toLatLng } from "./alignment_geometry";

// A world view before any payload lands. The payload's own fit replaces it
// immediately; a version with nothing drawable keeps it.
const WORLD_CENTER = [20, 0];
const WORLD_ZOOM = 2;
const MIN_ZOOM = 2;
const FIT_PADDING = [24, 24];
// The street tiles stop here, so a fit must not ask for more.
const FIT_MAX_ZOOM = STREET_MAX_ZOOM;

const STAGE_SELECTOR = ".flex-map-stage";

// Area treatments, by the prototype's zone classes (`.zone`, `.is-selected`,
// `.is-other`, `.zone.is-overlap`). The plain class is what the reference's own
// list draws; the role modifiers arrive with the service page and the editor.
const AREA_CLASS = "flex-map-area";
const AREA_ROLE_CLASSES = {
  selected: "flex-map-area--selected",
  other: "flex-map-area--other",
  overlap: "flex-map-area--overlap",
};

const ROUTE_WEIGHT = 3;
// The legend's "Fixed route" swatch and the app's own line colour; a route
// without a `route_color` in the feed is drawn with it.
const ROUTE_FALLBACK_COLOR = "#0d737d";

// The prototype's stop glyph: a white disc with a dark ring, and, for a
// connecting stop, a dark core and its always-on name.
const STOP_RADIUS = 4.5;
const STOP_WEIGHT = 1.6;
const HUB_RADIUS = 6.5;
const HUB_WEIGHT = 2.4;
const HUB_CORE_RADIUS = 2.5;
const STOP_FILL = "#ffffff";
const STOP_COLOR = "#0a1330";
const LABEL_OFFSET = [10, 0];

/** The area's class list for its role; an unknown or absent role is the plain one. */
export function areaClassName(role) {
  const modifier = AREA_ROLE_CLASSES[role];
  return modifier ? `${AREA_CLASS} ${modifier}` : AREA_CLASS;
}

/** `[lon, lat]` storage order to Leaflet's `[lat, lng]`; the one axis swap here (INV-1). */
function latLngs(coordinates) {
  if (!Array.isArray(coordinates)) return [];
  return coordinates.filter(Array.isArray).map(toLatLng);
}

// A payload may carry a geometry the server drew from a stored area; anything
// else (a null, a string) is skipped rather than handed to Leaflet.
function areaGeometry(area) {
  return area && typeof area === "object" && area.geojson ? area.geojson : null;
}

function stopPoint(stop) {
  if (!stop) return null;

  const lon = Number(stop.lon);
  const lat = Number(stop.lat);
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;

  // The map draws a stop's own name, its point and whether it is a connecting
  // stop; the payload's id stays the server's identity for the row.
  return { name: stop.name || "", lat, lon, hub: Boolean(stop.hub) };
}

const FlexAreaMap = {
  mounted() {
    this._leaflet = null;
    this._map = null;
    this._areas = [];
    this._layers = [];

    const stage = this.el.querySelector(STAGE_SELECTOR);
    if (!stage) return;

    const leaflet = window.L;
    if (!leaflet) return;
    this._leaflet = leaflet;

    // A remount can reuse a container the previous hook's destroyed() did not
    // release; Leaflet refuses to initialize a container it still owns.
    if (stage._leaflet_id) {
      stage._leaflet_id = undefined;
      stage.innerHTML = "";
    }

    const map = leaflet.map(stage, {
      center: WORLD_CENTER,
      zoom: WORLD_ZOOM,
      minZoom: MIN_ZOOM,
      maxZoom: STREET_MAX_ZOOM,
      // A page scroll over the card must scroll the page, not zoom the map.
      // Leaflet keeps its zoom control, its attribution control and its
      // keyboard panning (arrow keys, +/−) at their defaults.
      scrollWheelZoom: false,
    });
    this._map = map;

    addStreetBasemap(leaflet, map);

    this.handleEvent("flex_map:load", (payload) => this._load(payload));
    this.pushEvent("flex_map_ready", {});
  },

  destroyed() {
    if (this._map) {
      try {
        this._map.remove();
      } catch (_) {
        // LiveView already remounted a hook on this container.
      }
      this._map = null;
    }

    this._layers = [];
    this._areas = [];
    this._leaflet = null;
  },

  // --- Drawing ---------------------------------------------------------------

  // Every load replaces what the previous one drew: the map is a view of the
  // server's payload, not a growing stack of layers.
  _load(payload) {
    if (!this._map || !payload || typeof payload !== "object") return;

    this._clear();
    this._drawAreas(Array.isArray(payload.areas) ? payload.areas : []);
    this._drawRoutes(Array.isArray(payload.routes) ? payload.routes : []);
    this._drawStops(Array.isArray(payload.stops) ? payload.stops : []);
    this._fit();
  },

  _clear() {
    this._layers.forEach((layer) => this._map.removeLayer(layer));
    this._layers = [];
    this._areas = [];
  },

  _add(layer) {
    layer.addTo(this._map);
    this._layers.push(layer);
    return layer;
  },

  // One geoJSON layer per stored area, in payload order: the polygon's ring
  // order (holes included) is the server's GeoJSON, and `fill-rule: evenodd`
  // is Leaflet's own default for a path.
  _drawAreas(areas) {
    areas.forEach((area) => {
      const geojson = areaGeometry(area);
      if (!geojson) return;

      const layer = this._add(
        this._leaflet.geoJSON(geojson, {
          className: areaClassName(area.role),
          interactive: false,
        }),
      );

      const bounds = typeof layer.getBounds === "function" ? layer.getBounds() : null;
      if (bounds && (!bounds.isValid || bounds.isValid())) this._areas.push(bounds);
    });
  },

  _drawRoutes(routes) {
    routes.forEach((route) => {
      if (!route || typeof route !== "object") return;

      const points = latLngs(route.coordinates);
      if (points.length < 2) return;

      this._add(
        this._leaflet.polyline(points, {
          color: route.color || ROUTE_FALLBACK_COLOR,
          weight: ROUTE_WEIGHT,
          interactive: false,
        }),
      );
    });
  },

  _drawStops(stops) {
    stops.forEach((raw) => {
      const stop = stopPoint(raw);
      if (!stop) return;

      const centre = [stop.lat, stop.lon];
      const options = stop.hub
        ? { radius: HUB_RADIUS, weight: HUB_WEIGHT }
        : { radius: STOP_RADIUS, weight: STOP_WEIGHT };

      const marker = this._add(
        this._leaflet.circleMarker(centre, {
          ...options,
          color: STOP_COLOR,
          fillColor: STOP_FILL,
          fillOpacity: 1,
          interactive: false,
        }),
      );

      if (!stop.hub) return;

      // The connecting stop's core, then its name: the map is read without a
      // hover on a touch screen, so a hub's label is permanent.
      this._add(
        this._leaflet.circleMarker(centre, {
          radius: HUB_CORE_RADIUS,
          stroke: false,
          fillColor: STOP_COLOR,
          fillOpacity: 1,
          interactive: false,
        }),
      );

      marker.bindTooltip(stop.name, {
        permanent: true,
        direction: "right",
        offset: LABEL_OFFSET,
        className: "flex-map-stop-label",
      });
    });
  },

  // The frame is the flex areas when any is stored (the reference fits its
  // service shapes); a version whose areas are all underived falls back to its
  // route lines and connecting stops, and a version with nothing drawable keeps
  // the world view.
  _fit() {
    if (!this._map) return;

    const bounds = this._leaflet.latLngBounds([]);
    this._areas.forEach((areaBounds) => bounds.extend(areaBounds));

    if (!bounds.isValid()) {
      this._layers.forEach((layer) => {
        if (typeof layer.getLatLng === "function") bounds.extend(layer.getLatLng());
        else if (typeof layer.getBounds === "function") bounds.extend(layer.getBounds());
      });
    }

    if (!bounds.isValid()) return;

    this._map.fitBounds(bounds, {
      padding: FIT_PADDING,
      maxZoom: FIT_MAX_ZOOM,
      animate: !prefersReducedMotion(),
    });
  },
};

function prefersReducedMotion() {
  return Boolean(
    typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  );
}

export default FlexAreaMap;
