/* @vitest-environment jsdom */
import { describe, expect, it } from "vitest";

import {
  SIMILAR_COLOR_DELTA,
  automaticTextColor,
  contrastRatio,
  normalizeHex,
  similarColor,
} from "../route_identity_preview";

describe("route_identity_preview local color calculations", () => {
  // Fixtures and expectations below are the same pairs asserted for
  // GtfsPlannerWeb.Components.RouteIdentity in
  // test/gtfs_planner_web/components/route_identity_test.exs. A divergence
  // between this file and that one means the browser preview and the server
  // no longer agree on the same color pair.

  it("normalizes the same six-digit hex the server accepts", () => {
    expect(normalizeHex("D32F2F")).toBe("D32F2F");
    expect(normalizeHex("d32f2f")).toBe("D32F2F");
    expect(normalizeHex("1a2B3c")).toBe("1A2B3C");
    expect(normalizeHex("#FFFFFF")).toBe("FFFFFF");
    expect(normalizeHex("  #000000  ")).toBe("000000");
  });

  it("rejects everything the server rejects", () => {
    for (const value of [
      null,
      undefined,
      123_456,
      {route_color: "D32F2F"},
      [],
      "",
      "   ",
      "FFF",
      "#FFF",
      "FFFFFFFF",
      "GGGGGG",
      "ZZZZZZ",
      "12345G",
      "abc",
    ]) {
      expect(normalizeHex(value)).toBeNull();
    }
  });

  it("matches the server contrast pairs, including black/white at 21:1", () => {
    expect(contrastRatio("FFFFFF", "000000")).toBeCloseTo(21.0, 10);
    expect(contrastRatio("000000", "FFFFFF")).toBeCloseTo(21.0, 10);
    expect(contrastRatio("808080", "808080")).toBeCloseTo(1.0, 10);
    expect(contrastRatio("808080", "999999")).toBeLessThan(4.5);
    expect(contrastRatio("767676", "FFFFFF")).toBeGreaterThanOrEqual(4.5);
    expect(contrastRatio("757575", "FFFFFF")).toBeGreaterThanOrEqual(4.5);
  });

  it("is symmetric and accepts raw browser input", () => {
    expect(contrastRatio("5BC5F2", "000000")).toBeCloseTo(
      contrastRatio("000000", "5bc5f2"),
      12,
    );
    expect(contrastRatio("#5BC5F2", " #000000 ")).toBeCloseTo(
      contrastRatio("5BC5F2", "000000"),
      12,
    );
  });

  it("picks the same automatic text color the server picks", () => {
    // RouteIdentity's badge renders FFFF00 with black text and keeps white on
    // 1A1A1A; the same two picks drive a trusted `text_mode: "automatic"` save.
    expect(automaticTextColor("FFFFFF")).toBe("000000");
    expect(automaticTextColor("FFFF00")).toBe("000000");
    expect(automaticTextColor("#ffff00")).toBe("000000");
    expect(automaticTextColor("1A1A1A")).toBe("FFFFFF");
    expect(automaticTextColor("FFD200")).toBe("000000");
  });

  it("yields no usable style for invalid input", () => {
    for (const value of [null, undefined, "", "#FFF", "GGGGGG", 42, {}]) {
      expect(normalizeHex(value)).toBeNull();
      expect(automaticTextColor(value)).toBeNull();
      expect(contrastRatio(value, "000000")).toBeNull();
      expect(contrastRatio("000000", value)).toBeNull();
    }

    // Nothing usable survives, so a preview caller has no background-color or
    // text color to interpolate and shows the neutral surface instead. This
    // mirrors route_badge/1, which renders no style attribute at all for an
    // invalid or missing route_color.
    expect(similarColor("ZZZZZZ", [{route_color: "D32F2F"}])).toBeNull();
  });

  it("excludes white from similarity on both sides", () => {
    // FEFEFE/FFFFFF and FEFEFE/FDFDFD are 0.345 apart, well under the
    // threshold, so only the white exclusion can keep these out.
    expect(similarColor("FFFFFF", [{route_color: "D32F2F"}])).toBeNull();
    expect(similarColor("FEFEFE", [{route_color: "FFFFFF"}])).toBeNull();
    expect(similarColor("FEFEFE", [{route_color: "FDFDFD"}])).not.toBeNull();
  });

  it("warns only below the 12 delta, and only as advisory", () => {
    expect(SIMILAR_COLOR_DELTA).toBe(12);

    // CIE76: D32F2F/C0392B 9.803 (inside), D32F2F/B7352B 12.529 (outside).
    const inside = similarColor("D32F2F", [{route_color: "C0392B"}]);
    expect(inside).not.toBeNull();
    expect(inside.severity).toBe("advisory");
    expect(inside.delta).toBeLessThan(SIMILAR_COLOR_DELTA);
    expect(inside.route).toEqual({route_color: "C0392B"});

    expect(similarColor("D32F2F", [{route_color: "B7352B"}])).toBeNull();
    expect(similarColor("1A73E8", [{route_color: "5A8BF0"}])).toBeNull();
  });

  it("names the nearest candidate and skips unusable ones", () => {
    // E0393B is 4.363 from the subject, C0392B is 9.803.
    const nearest = similarColor("D32F2F", [
      {route_color: "C0392B", route_short_name: "far"},
      {route_color: "e0393b", route_short_name: "near"},
    ]);

    expect(nearest.route.route_short_name).toBe("near");
    expect(nearest.delta).toBeCloseTo(4.363, 2);

    expect(
      similarColor("D32F2F", [
        {route_color: null},
        {route_color: "nope"},
        {},
        null,
        {route_color: "FFFFFF"},
        {route_color: "B7352B"},
      ]),
    ).toBeNull();

    expect(similarColor("D32F2F", [])).toBeNull();
    expect(similarColor("D32F2F", undefined)).toBeNull();
  });
});
