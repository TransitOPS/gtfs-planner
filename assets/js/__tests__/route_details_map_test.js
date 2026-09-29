/* @vitest-environment jsdom */
import { afterEach, describe, expect, it, vi } from "vitest";
import RouteDetailsMapHook, {
  casingFor,
  isZoomWheel,
  leafletLatLng,
  lineColorFor,
  nextMapAction,
  occurrenceMarkers,
  parseColors,
  parsePayload,
  sectionPaths,
  swatchColorFor,
  unlocatedPhrase,
  variantPaths,
} from "../route_details_map";

// Merge evidence for the saved route map (spec 16, step 30). jsdom has no
// Leaflet, so these cases establish the hook's own contract: what the step-17
// projection may become on screen (solid/dashed/absent by section source and
// status), which occurrences stay distinct, how a color-only patch behaves,
// and how the hook degrades when the runtime is missing. The rendered
// canvas is the Playwright lane's contract (EV gates deferred to branch
// review); nothing here loads a tile.

const PAYLOAD = {
  route_uuid: "11111111-1111-1111-1111-111111111111",
  route_id: "W1",
  status: "ok",
  saved_alignment: "unavailable",
  patterns: [],
  imported_shape_variants: [],
};

function patternFixture(overrides = {}) {
  return {
    route_pattern_id: "P1",
    direction_id: 0,
    route_pattern_name: "Central – Valley Hospital",
    visits: [
      { position: 1, stop_id: "A", coordinates: [-75.0, 40.0] },
      { position: 2, stop_id: "B", coordinates: [-75.1, 40.1] },
    ],
    sections: [
      {
        source: "stop_pair",
        status: "saved",
        from_position: 1,
        to_position: 2,
        coordinates: [
          [-75.0, 40.0],
          [-75.1, 40.1],
        ],
        unlocated: [],
      },
    ],
    ...overrides,
  };
}

describe("parsePayload", () => {
  it("accepts the route_map/3 JSON shape", () => {
    const raw = JSON.stringify(PAYLOAD);
    expect(parsePayload(raw)).toEqual(PAYLOAD);
  });

  it("rejects garbage, truncation and shapes without pattern arrays", () => {
    expect(parsePayload(undefined)).toBeNull();
    expect(parsePayload("")).toBeNull();
    expect(parsePayload("not json {")).toBeNull();
    expect(parsePayload("{}")).toBeNull();
    expect(parsePayload(JSON.stringify({ patterns: [] }))).toBeNull();
    expect(
      parsePayload(
        JSON.stringify({ patterns: "no", imported_shape_variants: [] }),
      ),
    ).toBeNull();
  });
});

describe("leafletLatLng", () => {
  it("converts the model's [lon, lat] to Leaflet's [lat, lon]", () => {
    expect(leafletLatLng([-75.0, 40.5])).toEqual([40.5, -75.0]);
  });

  it("refuses anything that would draw at (0, 0) or NaN", () => {
    expect(leafletLatLng(undefined)).toBeNull();
    expect(leafletLatLng([-75.0])).toBeNull();
    expect(leafletLatLng(["west", 40.0])).toBeNull();
    expect(leafletLatLng([null, null])).toBeNull();
  });
});

describe("sectionPaths", () => {
  it("draws a saved stop_pair section solid from its own coordinates", () => {
    const paths = sectionPaths(patternFixture());
    expect(paths).toHaveLength(1);
    expect(paths[0]).toEqual({
      key: "P1:1-2",
      kind: "solid",
      latlngs: [
        [40.0, -75.0],
        [40.1, -75.1],
      ],
    });
  });

  it("draws a missing section dashed only when both endpoint visits have coordinates (AC-25)", () => {
    const pattern = patternFixture({
      sections: [
        {
          source: "stop_pair",
          status: "missing",
          from_position: 1,
          to_position: 2,
          unlocated: [{ ref: "B", reason: "coordinates_absent" }],
        },
      ],
    });
    const paths = sectionPaths(pattern);
    expect(paths).toHaveLength(1);
    expect(paths[0].kind).toBe("dashed");
    expect(paths[0].latlngs).toEqual([
      [40.0, -75.0],
      [40.1, -75.1],
    ]);
  });

  it("never draws a missing section whose endpoint has no coordinates", () => {
    const pattern = patternFixture({
      visits: [
        { position: 1, stop_id: "A", coordinates: [-75.0, 40.0] },
        {
          position: 2,
          stop_id: "B",
          unlocated: [{ ref: "B", reason: "coordinates_absent" }],
        },
      ],
      sections: [
        {
          source: "stop_pair",
          status: "missing",
          from_position: 1,
          to_position: 2,
          unlocated: [{ ref: "B", reason: "coordinates_absent" }],
        },
      ],
    });
    expect(sectionPaths(pattern)).toEqual([]);
  });

  it("never draws unavailable geometry (INV-5)", () => {
    const pattern = patternFixture({
      sections: [
        {
          source: "stop_pair",
          status: "unavailable",
          from_position: 1,
          to_position: 2,
          unlocated: [{ ref: "ghost", reason: "stop_not_found" }],
        },
      ],
    });
    expect(sectionPaths(pattern)).toEqual([]);
  });

  it("drops a saved section with a broken coordinate instead of fabricating it", () => {
    const pattern = patternFixture({
      sections: [
        {
          source: "stop_pair",
          status: "saved",
          from_position: 1,
          to_position: 2,
          coordinates: [
            [-75.0, 40.0],
            [null, null],
          ],
        },
      ],
    });
    expect(sectionPaths(pattern)).toEqual([]);
  });

  it("ignores non-stop_pair sources", () => {
    const pattern = patternFixture({
      sections: [
        {
          source: "imported_shape",
          status: "saved",
          from_position: 1,
          to_position: 2,
          coordinates: [
            [-75.0, 40.0],
            [-75.1, 40.1],
          ],
        },
      ],
    });
    expect(sectionPaths(pattern)).toEqual([]);
  });
});

describe("variantPaths", () => {
  it("draws each distinct saved imported shape once, keyed by shape_id", () => {
    const variant = {
      source: "imported_shape",
      status: "saved",
      shape_id: "SHAPE_1",
      variant: 1,
      label: "Variant 1",
      route_pattern_ids: ["P1"],
      coordinates: [
        [-75.0, 40.0],
        [-75.05, 40.05],
        [-75.1, 40.1],
      ],
    };
    expect(variantPaths(variant)).toEqual([
      {
        key: "SHAPE_1",
        kind: "solid",
        latlngs: [
          [40.0, -75.0],
          [40.05, -75.05],
          [40.1, -75.1],
        ],
      },
    ]);
  });

  it("never draws a missing variant's shape and ignores other sources", () => {
    expect(
      variantPaths({
        source: "imported_shape",
        status: "missing",
        shape_id: "SHAPE_9",
        variant: 2,
        label: "Variant 2",
        route_pattern_ids: [],
        unlocated: [{ ref: "SHAPE_9", reason: "shape_points_absent" }],
      }),
    ).toEqual([]);
    expect(
      variantPaths({ source: "stop_pair", status: "saved", coordinates: [] }),
    ).toEqual([]);
  });
});

describe("occurrenceMarkers", () => {
  it("keeps one distinct marker per visit for a repeated stop (AC-25)", () => {
    const markers = occurrenceMarkers(
      patternFixture({
        visits: [
          { position: 1, stop_id: "LOOP", coordinates: [-75.0, 40.0] },
          { position: 2, stop_id: "MID", coordinates: [-75.05, 40.05] },
          { position: 3, stop_id: "LOOP", coordinates: [-75.0, 40.0] },
          {
            position: 4,
            stop_id: "UNLOCATED",
            unlocated: [{ ref: "UNLOCATED", reason: "coordinates_absent" }],
          },
        ],
      }),
    );
    expect(markers.map((marker) => marker.key)).toEqual([
      "P1:1",
      "P1:2",
      "P1:3",
    ]);
    expect(markers[0].stopId).toBe("LOOP");
    expect(markers[2].stopId).toBe("LOOP");
    expect(markers[0].latlng).toEqual(markers[2].latlng);
  });
});

describe("colors", () => {
  it("parses the colors attribute defensively", () => {
    expect(parseColors('{"route_color":"0B6E4F"}')).toEqual({
      route_color: "0B6E4F",
      route_text_color: "",
    });
    expect(parseColors("not json")).toEqual({
      route_color: "",
      route_text_color: "",
    });
    expect(parseColors(undefined)).toEqual({
      route_color: "",
      route_text_color: "",
    });
  });

  it("resolves the line color like the badge preview, blank to the white default", () => {
    expect(lineColorFor({ route_color: "#0b6e4f" })).toBe("0B6E4F");
    expect(lineColorFor({ route_color: "" })).toBe("FFFFFF");
    expect(lineColorFor({ route_color: "zzz" })).toBe("FFFFFF");
  });

  it("gives a white line the grey casing and any other line a white casing", () => {
    expect(casingFor("FFFFFF")).toBe("#7a8698");
    expect(casingFor("FEFEFE")).toBe("#7a8698");
    expect(casingFor("0B6E4F")).toBe("#ffffff");
  });

  it("keeps list swatches visible when the line color is white", () => {
    expect(swatchColorFor("FFFFFF")).toBe("#7A8698");
    expect(swatchColorFor("0B6E4F")).toBe("#0B6E4F");
  });
});

describe("unlocatedPhrase", () => {
  it("names every reason the projection emits, without inventing paths", () => {
    expect(unlocatedPhrase("coordinates_absent")).toBe(
      "a stop has no coordinates",
    );
    expect(unlocatedPhrase("stop_not_found")).toBe(
      "a referenced stop is missing",
    );
    expect(unlocatedPhrase("shape_points_absent")).toBe(
      "the shape has no points",
    );
    expect(unlocatedPhrase("something_new")).toBe("the path is unknown");
  });
});

describe("isZoomWheel", () => {
  it("accepts Ctrl and Cmd gestures and leaves plain wheel to the page", () => {
    expect(isZoomWheel({ ctrlKey: true, metaKey: false })).toBe(true);
    expect(isZoomWheel({ ctrlKey: false, metaKey: true })).toBe(true);
    expect(isZoomWheel({ ctrlKey: false, metaKey: false })).toBe(false);
    expect(isZoomWheel(null)).toBe(false);
  });
});

describe("nextMapAction", () => {
  it("refits the first render and a different opened route", () => {
    const payload = { ...PAYLOAD };
    expect(nextMapAction(null, payload)).toBe("refit");
    expect(nextMapAction("22222222-2222-2222-2222-222222222222", payload)).toBe(
      "refit",
    );
  });

  it("redraws the same route in place so color patches never reset pan/zoom (AC-26)", () => {
    expect(nextMapAction(PAYLOAD.route_uuid, PAYLOAD)).toBe("redraw");
  });

  it("does nothing without a payload", () => {
    expect(nextMapAction(PAYLOAD.route_uuid, null)).toBe("none");
  });
});

describe("hook lifecycle without Leaflet", () => {
  afterEach(() => {
    document.body.innerHTML = "";
    delete window.L;
  });

  function mountHook(dataset = {}) {
    const el = document.createElement("div");
    el.id = "route-map";
    Object.assign(el.dataset, dataset);
    document.body.appendChild(el);

    const hook = Object.create(RouteDetailsMapHook);
    hook.el = el;
    hook.pushEvent = vi.fn();
    hook.handleEvent = vi.fn();
    return hook;
  }

  it("degrades to the plain frame without an exception when Leaflet is missing", () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const hook = mountHook({
      mapPayload: JSON.stringify(PAYLOAD),
      mapColors: '{"route_color":"0B6E4F"}',
    });

    expect(() => hook.mounted()).not.toThrow();
    expect(hook._map).toBeUndefined();
    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(errorSpy).toHaveBeenCalledWith(
      expect.stringContaining("window.L (Leaflet) is not available"),
    );
    errorSpy.mockRestore();

    expect(() => hook.destroyed()).not.toThrow();
  });

  it("tears down cleanly after a full Leaflet-free mount/updated cycle", () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const hook = mountHook({ mapPayload: JSON.stringify(PAYLOAD) });
    hook.mounted();
    expect(() => hook.updated()).not.toThrow();
    hook.destroyed();
    expect(hook._cleanup).toEqual([]);
    errorSpy.mockRestore();
  });
});
