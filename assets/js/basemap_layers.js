/**
 * The Esri basemap shared by every Leaflet surface.
 *
 * Every Leaflet surface in the app draws the same aerial imagery under the
 * same transparent road reference layer, so those two definitions live here
 * and nowhere else (CR-8). The caller passes its own Leaflet namespace and
 * map, which keeps this module free of `window.L` and of any one hook's
 * lifecycle.
 */

// Adds the basemap to `map` and returns `[imageryLayer, roadsLayer]` — the
// results of each layer's own `addTo`, not the layers themselves, so a caller
// that receives a falsy result keeps whatever tolerance it already had.
export function addEsriBasemap(L, map) {
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
