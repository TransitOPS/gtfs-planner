/* @vitest-environment jsdom */
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { addEsriBasemap } from "../basemap_layers";

// Merge evidence (EV-25) for the shared Esri basemap. The two layer
// definitions belong to this one module (CR-8) and step 27's TransferMap hook
// consumes them too, so the URLs, options and attributions are asserted as
// literals rather than read back from the module: a changed tile URL or a
// dropped option must fail here rather than reach either map.
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

    addEsriBasemap(L, map);

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

    expect(addEsriBasemap(L, map)).toEqual([addedImagery, addedRoads]);

    expect(imagery.addTo).toHaveBeenCalledWith(map);
    expect(roads.addTo).toHaveBeenCalledWith(map);
  });

  it("returns the addTo results even when they are undefined, so the diagram's falsy-layer tolerance stays intact", () => {
    // The Map tab's own tests stub `addTo: vi.fn()`, whose result is
    // `undefined`; `MapAlignmentHook` keeps whatever `addTo` gave it, in the
    // same order, rather than substituting the layers.
    const L = stubLeaflet(() => ({ addTo: vi.fn() }));

    expect(addEsriBasemap(L, {})).toEqual([undefined, undefined]);
  });

  it("leaves these two definitions in this module alone and has the diagram hook consume them", () => {
    const helper = readModule("../basemap_layers.js");
    const hook = readModule("../map_alignment_hook.js");

    expect(helper).toContain(IMAGERY_URL);
    expect(helper).toContain(ROADS_URL);
    expect(hook).not.toContain("arcgisonline.com");
    expect(hook).toContain('import { addEsriBasemap } from "./basemap_layers"');
    expect(hook).toContain("addEsriBasemap(L, map)");
  });
});
