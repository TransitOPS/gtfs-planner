/* @vitest-environment jsdom */
import { afterEach, describe, expect, it, vi } from "vitest";
import FillPreviewMapHook, {
  leafletLatLng,
  markerClass,
  markerHtml,
  markerTooltip,
  parsePayload,
  sectionPaths,
  visitMarkers,
} from "../fill_preview_map";

// Merge evidence for the fill preview map (spec 23, step 14). jsdom has no
// Leaflet, so these cases establish the hook's own contract: what the fill
// panel payload may become on screen (one marker per visit with its kind and
// label, one line per section with [lon, lat] converted to Leaflet
// [lat, lon]), how straight sections and kinds are styled, how updates
// redraw without re-creating the map, how a section click fits, and how the
// hook degrades when the runtime is missing. The rendered pixels are the
// step 13/16 journey's contract (EV gates deferred to branch review);
// nothing here loads a tile.

const PAYLOAD = {
  stops: [
    {
      position: 1,
      name: "Depoe Bay",
      coord: [-124.065, 44.81],
      kind: "timepoint",
      label: "08:00",
    },
    {
      position: 2,
      name: "Taft Village",
      coord: [-124.02, 44.72],
      kind: "estimate",
      label: "08:05",
    },
    {
      position: 3,
      name: "Lincoln City",
      coord: null,
      kind: "blocked",
      label: null,
    },
  ],
  sections: [
    {
      from: 1,
      to: 2,
      points: [
        [-124.065, 44.81],
        [-124.04, 44.76],
        [-124.02, 44.72],
      ],
      source: "path",
    },
    {
      from: 2,
      to: 3,
      points: [
        [-124.02, 44.72],
        [-124.0, 44.7],
      ],
      source: "straight",
    },
  ],
};

// A minimal window.L: captures markers, polylines and view calls without
// drawing anything.
function fakeLeaflet() {
  const calls = {
    maps: 0,
    markers: [],
    polylines: [],
    fitBounds: [],
    setView: [],
    removed: 0,
  };

  const fakeMap = {
    setView(center, zoom, _opts) {
      calls.setView.push({ center, zoom });
      return fakeMap;
    },
    fitBounds(bounds, _opts) {
      calls.fitBounds.push(bounds);
      return fakeMap;
    },
    remove() {
      calls.removed += 1;
    },
  };

  const L = {
    map(_el, _opts) {
      calls.maps += 1;
      return fakeMap;
    },
    tileLayer(_url, _opts) {
      return { addTo: () => ({}) };
    },
    layerGroup() {
      return {
        clearLayers: vi.fn(),
        addTo: vi.fn(function () {
          return this;
        }),
      };
    },
    marker(latlng, options) {
      const marker = {
        latlng,
        options,
        tooltip: null,
        bindTooltip(text, _opts) {
          marker.tooltip = text;
          return marker;
        },
        addTo: vi.fn(() => marker),
      };
      calls.markers.push(marker);
      return marker;
    },
    divIcon(options) {
      return options;
    },
    polyline(latlngs, options) {
      const line = {
        latlngs,
        options,
        handlers: {},
        getLatLngs: () => latlngs,
        on(event, handler) {
          line.handlers[event] = handler;
          return line;
        },
        addTo: vi.fn(() => line),
      };
      calls.polylines.push(line);
      return line;
    },
    latLngBounds(latlngs) {
      return { latlngs };
    },
  };

  return { L, calls };
}

function mountHook(payload) {
  const el = document.createElement("div");
  el.id = "fill-map";
  el.dataset.fillMap = JSON.stringify(payload);
  document.body.appendChild(el);

  const error = document.createElement("p");
  error.id = "fill-map-error";
  error.hidden = true;
  document.body.appendChild(error);

  const hook = Object.create(FillPreviewMapHook);
  hook.el = el;
  hook.pushEvent = vi.fn();
  return hook;
}

describe("parsePayload", () => {
  it("accepts the fill_map_payload JSON shape", () => {
    expect(parsePayload(JSON.stringify(PAYLOAD))).toEqual(PAYLOAD);
  });

  it("defaults a missing sections array to empty", () => {
    expect(parsePayload(JSON.stringify({ stops: [] }))).toEqual({
      stops: [],
      sections: [],
    });
  });

  it("rejects garbage, truncation and shapes without a stops array", () => {
    expect(parsePayload(undefined)).toBeNull();
    expect(parsePayload("")).toBeNull();
    expect(parsePayload("not json {")).toBeNull();
    expect(parsePayload("{}")).toBeNull();
    expect(parsePayload(JSON.stringify({ sections: [] }))).toBeNull();
    expect(
      parsePayload(JSON.stringify({ stops: "no", sections: [] })),
    ).toBeNull();
    expect(
      parsePayload(JSON.stringify({ stops: [], sections: "no" })),
    ).toBeNull();
  });
});

describe("leafletLatLng", () => {
  it("converts the model's [lon, lat] to Leaflet's [lat, lon]", () => {
    expect(leafletLatLng([-124.065, 44.81])).toEqual([44.81, -124.065]);
  });

  it("refuses anything that would draw at (0, 0) or NaN", () => {
    expect(leafletLatLng(undefined)).toBeNull();
    expect(leafletLatLng(null)).toBeNull();
    expect(leafletLatLng([-124.065])).toBeNull();
    expect(leafletLatLng(["west", 44.81])).toBeNull();
    expect(leafletLatLng([null, null])).toBeNull();
  });
});

describe("visitMarkers", () => {
  it("adds one marker per visit with its kind and label", () => {
    const markers = visitMarkers(PAYLOAD.stops);
    expect(markers).toHaveLength(2);
    expect(markers[0]).toEqual({
      key: "visit-1",
      position: 1,
      name: "Depoe Bay",
      label: "08:00",
      kind: "timepoint",
      latlng: [44.81, -124.065],
    });
    expect(markers[1].kind).toBe("estimate");
    expect(markers[1].label).toBe("08:05");
  });

  it("never draws a visit without coordinates", () => {
    expect(visitMarkers(PAYLOAD.stops).map((m) => m.position)).toEqual([1, 2]);
  });

  it("falls back to a stop name and a null label", () => {
    const [marker] = visitMarkers([{ position: 4, coord: [-124.0, 44.7] }]);
    expect(marker.name).toBe("stop 4");
    expect(marker.label).toBeNull();
    expect(marker.kind).toBe("stop");
  });
});

describe("sectionPaths", () => {
  it("draws one line per section with converted points", () => {
    const paths = sectionPaths(PAYLOAD.sections);
    expect(paths).toHaveLength(2);
    expect(paths[0]).toEqual({
      key: "section-1-2",
      from: 1,
      to: 2,
      kind: "solid",
      latlngs: [
        [44.81, -124.065],
        [44.76, -124.04],
        [44.72, -124.02],
      ],
    });
    expect(paths[1].kind).toBe("dashed");
  });

  it("drops a section with fewer than two valid points instead of fabricating it", () => {
    expect(
      sectionPaths([{ from: 2, to: 3, points: [[-124.0, 44.7]], source: "straight" }]),
    ).toEqual([]);
    expect(
      sectionPaths([{ from: 2, to: 3, points: [[null, null], [-124.0, 44.7]], source: "path" }]),
    ).toEqual([]);
  });
});

describe("marker vocabulary", () => {
  it("timepoints use the square marker class and estimates the dashed circle", () => {
    expect(markerClass("timepoint")).toBe("fill-preview-timepoint");
    expect(markerClass("estimate")).toBe("fill-preview-estimate");
    expect(markerHtml({ position: 1, kind: "timepoint" })).toContain(
      "fill-preview-timepoint",
    );
    expect(markerHtml({ position: 2, kind: "estimate" })).toContain(
      "fill-preview-estimate",
    );
  });

  it("blocked stops use the warning class and unknown kinds fall back to plain", () => {
    expect(markerClass("blocked")).toBe("fill-preview-blocked");
    expect(markerClass("blank")).toBe("fill-preview-stop");
    expect(markerClass("stop")).toBe("fill-preview-stop");
    expect(markerClass("something_new")).toBe("fill-preview-stop");
  });

  it("tooltips name the visit and its time, or say there is no time", () => {
    expect(
      markerTooltip({ name: "Taft Village", label: "08:05" }),
    ).toBe("Taft Village · 08:05");
    expect(markerTooltip({ name: "Lincoln City", label: null })).toBe(
      "Lincoln City · no time",
    );
  });
});

describe("hook lifecycle with Leaflet", () => {
  afterEach(() => {
    document.body.innerHTML = "";
    delete window.L;
  });

  function interactiveLines(calls) {
    return calls.polylines.filter((line) => line.options.interactive !== false);
  }

  it("mounted() draws one marker per visit and one line per section", () => {
    const { L, calls } = fakeLeaflet();
    window.L = L;
    const hook = mountHook(PAYLOAD);
    hook.mounted();

    expect(calls.maps).toBe(1);
    expect(calls.markers).toHaveLength(2);
    expect(calls.markers[0].latlng).toEqual([44.81, -124.065]);
    expect(calls.markers[0].options.icon.html).toContain(
      "fill-preview-timepoint",
    );
    expect(calls.markers[0].tooltip).toBe("Depoe Bay · 08:00");
    expect(calls.markers[1].options.icon.html).toContain(
      "fill-preview-estimate",
    );

    const lines = interactiveLines(calls);
    expect(lines).toHaveLength(2);
    expect(lines[0].latlngs).toEqual([
      [44.81, -124.065],
      [44.76, -124.04],
      [44.72, -124.02],
    ]);
    hook.destroyed();
  });

  it("straight sections use the dashed warning style and path sections draw solid", () => {
    const { L, calls } = fakeLeaflet();
    window.L = L;
    const hook = mountHook(PAYLOAD);
    hook.mounted();

    const lines = interactiveLines(calls);
    expect(lines[0].options.dashArray).toBeNull();
    expect(lines[1].options.dashArray).toBe("8 6");
    expect(lines[1].options.color).toBe("#8a5a0e");
    hook.destroyed();
  });

  it("updated() redraws from the new payload without re-creating the map", () => {
    const { L, calls } = fakeLeaflet();
    window.L = L;
    const hook = mountHook(PAYLOAD);
    hook.mounted();
    expect(calls.markers).toHaveLength(2);

    hook.el.dataset.fillMap = JSON.stringify({
      ...PAYLOAD,
      stops: [PAYLOAD.stops[0]],
      sections: [],
    });
    hook.updated();

    expect(calls.maps).toBe(1);
    expect(calls.markers).toHaveLength(3);
    expect(calls.markers[2].latlng).toEqual([44.81, -124.065]);
    hook.destroyed();
  });

  it("an unchanged payload draws nothing more on updated()", () => {
    const { L, calls } = fakeLeaflet();
    window.L = L;
    const hook = mountHook(PAYLOAD);
    hook.mounted();
    const markers = calls.markers.length;
    hook.updated();
    expect(calls.markers).toHaveLength(markers);
    hook.destroyed();
  });

  it("clicking a section fits the map to that section's bounds", () => {
    const { L, calls } = fakeLeaflet();
    window.L = L;
    const hook = mountHook(PAYLOAD);
    hook.mounted();

    const fitsBefore = calls.fitBounds.length;
    expect(fitsBefore).toBeGreaterThan(0);

    const lines = interactiveLines(calls);
    lines[0].handlers.click();

    expect(calls.fitBounds.length).toBe(fitsBefore + 1);
    expect(calls.fitBounds.at(-1)).toEqual({
      latlngs: [
        [44.81, -124.065],
        [44.76, -124.04],
        [44.72, -124.02],
      ],
    });
    hook.destroyed();
  });

  it("destroyed() removes the map", () => {
    const { L, calls } = fakeLeaflet();
    window.L = L;
    const hook = mountHook(PAYLOAD);
    hook.mounted();
    hook.destroyed();
    expect(calls.removed).toBe(1);
  });
});

describe("hook lifecycle without Leaflet", () => {
  afterEach(() => {
    document.body.innerHTML = "";
    delete window.L;
  });

  it("degrades to the one-line message without an exception when Leaflet is missing", () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const hook = mountHook(PAYLOAD);

    expect(() => hook.mounted()).not.toThrow();
    expect(hook._map).toBeUndefined();
    expect(document.getElementById("fill-map-error").hidden).toBe(false);
    expect(errorSpy).toHaveBeenCalledWith(
      expect.stringContaining("window.L (Leaflet) is not available"),
    );
    errorSpy.mockRestore();

    expect(() => hook.updated()).not.toThrow();
    expect(() => hook.destroyed()).not.toThrow();
  });
});
