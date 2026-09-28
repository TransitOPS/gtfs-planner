/**
 * The two basemaps every Leaflet surface draws under its data.
 *
 * Not every map wants the same ground. A surface that positions something over
 * the real world — the Map tool aligning a floorplan to the station it was
 * surveyed from — needs aerial imagery to match the survey photo. Every other
 * surface is a planning view: reading a transfer connection, a zone boundary or
 * a stop's position against the streets around it, which an aerial photo hides.
 *
 * So the definitions live here and nowhere else (CR-8), split by what the map is
 * for rather than by which vendor serves it. Each caller passes its own Leaflet
 * namespace and map, which keeps this module free of `window.L` and of any one
 * hook's lifecycle.
 */

// The Geoapify raster styles this app proxies. `satellite` is listed so the
// split reads as a choice rather than an omission; see the note on the proxy in
// MapTilesController for why tiles reach the browser through the server.
const STREET_STYLE = "osm-bright";

// Street tiles are served by this app's own Geoapify proxy, so the API key never
// reaches the browser. The proxy accepts {z}/{x}/{y} in that order; only the
// direct-to-vendor Esri tiles below swap y and x.
export const STREET_TILE_URL = `/map/tiles/${STREET_STYLE}/{z}/{x}/{y}`;
export const STREET_TILE_ATTRIBUTION =
  "© OpenStreetMap contributors © OpenMapTiles © Geoapify";

// Geoapify's raster styles stop at this zoom; a map allowed past it shows empty
// tiles, so the layer and any map that uses it share the same ceiling.
export const STREET_MAX_ZOOM = 19;

/**
 * Adds the street basemap to `map` and returns `[streetLayer]`.
 *
 * Returned as a list, like the satellite pair below, because a caller that
 * binds per-tile state or redraws on retry should not care how many basemap
 * layers it was handed. The result is the layer's own `addTo` return, not the
 * layer, so a caller that receives a falsy value keeps whatever tolerance it
 * already had.
 */
export function addStreetBasemap(L, map) {
  const streetLayer = L.tileLayer(STREET_TILE_URL, {
    attribution: STREET_TILE_ATTRIBUTION,
    maxNativeZoom: STREET_MAX_ZOOM,
    maxZoom: STREET_MAX_ZOOM,
  }).addTo(map);

  return [streetLayer];
}

/**
 * Adds the satellite basemap to `map` and returns `[imageryLayer, roadsLayer]`
 * — the results of each layer's own `addTo`, in that layering order, so imagery
 * sits under the transparent road reference drawn over it.
 */
export function addSatelliteBasemap(L, map) {
  // Esri World Imagery: free aerial tiles, no API key. URL uses z/y/x
  // (note: y before x). Goes direct from the browser — no credential to hide.
  const imageryLayer = L.tileLayer(
    "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
    {
      keepBuffer: 8,
      maxNativeZoom: 19,
      maxZoom: 22,
      updateWhenIdle: false,
      updateWhenZooming: true,
      attribution: "Imagery © Esri, Maxar, Earthstar Geographics",
    },
  ).addTo(map);

  // Transparent reference layer with roads and road names tuned to overlay
  // on World_Imagery.
  const roadsLayer = L.tileLayer(
    "https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}",
    {
      keepBuffer: 8,
      maxNativeZoom: 19,
      maxZoom: 22,
      updateWhenIdle: false,
      updateWhenZooming: true,
      attribution: "Roads © Esri",
    },
  ).addTo(map);

  return [imageryLayer, roadsLayer];
}
