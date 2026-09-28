/* @vitest-environment jsdom */
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import {
  addSatelliteBasemap,
  addStreetBasemap,
  STREET_MAX_ZOOM,
  STREET_TILE_URL,
} from "../basemap_layers";

// Merge evidence (EV-25) for the shared basemaps. The two kinds of basemap —
// satellite for the Map tool, streets for every planning surface — live in this
// one module (CR-8) and both hooks consume them here, so the URLs, options and
// attributions are asserted as literals rather than read back from the module: a
// changed tile URL or a dropped option must fail here rather than reach any
// map.
const IMAGERY_URL =
  "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}";
const ROADS_URL =
  "https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}";
const LAYER_OPTIONS = {
  keepBuffer: 8,
  maxNativeZoom: 19,
  maxZoom: 22,
  updateWhenIdle: false,
  updateWhenZooming: true,
};
const IMAGERY_ATTRIBUTION = "Imagery © Esri, Maxar, Earthstar Geographics";
const ROADS_ATTRIBUTION = "Roads © Esri";

function stubLeaflet(returnValue) {
  return { tileLayer: vi.fn(returnValue) };
}

function readModule(relativePath) {
  return readFileSync(new URL(relativePath, import.meta.url), "utf8");
}

describe("basemap_layers", () => {
  it("adds the World Imagery and World Transportation tiles with their published options", () => {
    const map = {};
    const L = stubLeaflet(() => ({ addTo: vi.fn() }));

    addSatelliteBasemap(L, map);

    expect(L.tileLayer).toHaveBeenCalledTimes(2);

    expect(L.tileLayer.mock.calls[0][0]).toBe(IMAGERY_URL);
    expect(L.tileLayer.mock.calls[0][1]).toEqual({
      ...LAYER_OPTIONS,
      attribution: IMAGERY_ATTRIBUTION,
    });

    expect(L.tileLayer.mock.calls[1][0]).toBe(ROADS_URL);
    expect(L.tileLayer.mock.calls[1][1]).toEqual({
      ...LAYER_OPTIONS,
      attribution: ROADS_ATTRIBUTION,
    });
  });

  it("adds each layer to the given map and returns the two addTo results in layering order", () => {
    const map = {};
    const addedImagery = { layer: "imagery" };
    const addedRoads = { layer: "roads" };
    const imagery = { addTo: vi.fn(() => addedImagery) };
    const roads = { addTo: vi.fn(() => addedRoads) };
    const L = stubLeaflet();
    L.tileLayer.mockReturnValueOnce(imagery).mockReturnValueOnce(roads);

    expect(addSatelliteBasemap(L, map)).toEqual([addedImagery, addedRoads]);

    expect(imagery.addTo).toHaveBeenCalledWith(map);
    expect(roads.addTo).toHaveBeenCalledWith(map);
  });

  it("returns the addTo results even when they are undefined, so the diagram's falsy-layer tolerance stays intact", () => {
    // The Map tab's own tests stub `addTo: vi.fn()`, whose result is
    // `undefined`; `MapAlignmentHook` keeps whatever `addTo` gave it, in the
    // same order, rather than substituting the layers.
    const L = stubLeaflet(() => ({ addTo: vi.fn() }));

    expect(addSatelliteBasemap(L, {})).toEqual([undefined, undefined]);
  });

  it("leaves the satellite definitions in this module alone and has the diagram hook consume them", () => {
    const helper = readModule("../basemap_layers.js");
    const hook = readModule("../map_alignment_hook.js");

    expect(helper).toContain(IMAGERY_URL);
    expect(helper).toContain(ROADS_URL);
    expect(hook).not.toContain("arcgisonline.com");
    expect(hook).toContain('import { addSatelliteBasemap } from "./basemap_layers"');
    expect(hook).toContain("addSatelliteBasemap(L, map)");
  });

  // The audit this module exists for: a planning surface that silently inherits
  // the aerial basemap hides the streets the surface is read against, and no
  // other test would notice, because each hook's own suite stubs the basemap out.
  it("adds the proxied street tiles, not satellite, for the planning surfaces", () => {
    const map = {};
    const L = stubLeaflet(() => ({ addTo: vi.fn() }));

    addStreetBasemap(L, map);

    expect(L.tileLayer).toHaveBeenCalledTimes(1);
    expect(L.tileLayer.mock.calls[0][0]).toBe(STREET_TILE_URL);
    expect(L.tileLayer.mock.calls[0][0]).toBe("/map/tiles/osm-bright/{z}/{x}/{y}");
    expect(L.tileLayer.mock.calls[0][0]).not.toBe(IMAGERY_URL);
    expect(L.tileLayer.mock.calls[0][1]).toEqual({
      attribution:
        "© OpenStreetMap contributors © OpenMapTiles © Geoapify",
      maxNativeZoom: STREET_MAX_ZOOM,
      maxZoom: STREET_MAX_ZOOM,
    });
  });

  it("adds the street layer to the given map and returns it as a one-item list", () => {
    const map = {};
    const added = { layer: "streets" };
    const streets = { addTo: vi.fn(() => added) };
    const L = stubLeaflet();
    L.tileLayer.mockReturnValueOnce(streets);

    expect(addStreetBasemap(L, map)).toEqual([added]);
    expect(streets.addTo).toHaveBeenCalledWith(map);
  });

  it("keeps both basemap kinds in this module and has the two planning hooks consume the streets", () => {
    const helper = readModule("../basemap_layers.js");
    const transferHook = readModule("../transfer_map_hook.js");
    const fareZoneHook = readModule("../fare_zone_map_hook.js");

    expect(helper).toContain('const STREET_STYLE = "osm-bright"');
    expect(helper).toContain("`/map/tiles/${STREET_STYLE}/{z}/{x}/{y}`");
    expect(transferHook).not.toContain("arcgisonline.com");
    expect(transferHook).toContain(
      'import { addStreetBasemap, STREET_MAX_ZOOM } from "./basemap_layers"',
    );
    expect(transferHook).toContain("addStreetBasemap(L, this.map)");
    expect(fareZoneHook).toContain('from "./basemap_layers"');
    expect(fareZoneHook).toContain(".tileLayer(STREET_TILE_URL");
  });
});
