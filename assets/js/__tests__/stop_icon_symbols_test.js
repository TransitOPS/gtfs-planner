/* @vitest-environment jsdom */
import { describe, expect, it } from "vitest";
import {
  DIAGRAM_ACTIVE_COLOR,
  DIAGRAM_BASE_COLOR,
  HALO_COLOR,
  appendStopBadges,
  badgeSymbolForMode,
  borderRadiusForSymbol,
  createBadgeElement,
  dimensionsForSymbol,
  paletteColor,
  symbolForLocationType,
  treatmentForLocationType,
} from "../stop_icon_symbols";

describe("stop_icon_symbols vocabulary", () => {
  it("maps location_type values to the diagram symbol grammar", () => {
    expect(symbolForLocationType(0)).toBe("rect_upright");
    expect(symbolForLocationType(1)).toBe("circle");
    expect(symbolForLocationType(2)).toBe("rect_upright");
    expect(symbolForLocationType(3)).toBe("circle");
    expect(symbolForLocationType(4)).toBe("rect_square");
    expect(symbolForLocationType("2")).toBe("rect_upright");
    expect(symbolForLocationType(undefined)).toBe("circle");
    expect(symbolForLocationType(null)).toBe("circle");
    expect(symbolForLocationType("not-a-location-type")).toBe("circle");
  });

  it("exports the canonical diagram colors", () => {
    expect(DIAGRAM_BASE_COLOR).toBe("#0B5FFF");
    expect(DIAGRAM_ACTIVE_COLOR).toBe("#BE123C");
    expect(HALO_COLOR).toBe("#FFFFFF");
  });

  it("reads a named palette role from the production page root with a safe fallback", () => {
    const root = document.createElement("div");
    root.style.setProperty("--diagram-active-stop", "#7C3AED");
    document.body.appendChild(root);

    expect(paletteColor(root, "--diagram-active-stop", DIAGRAM_BASE_COLOR)).toBe("#7C3AED");
    expect(paletteColor(root, "--diagram-missing", DIAGRAM_BASE_COLOR)).toBe(DIAGRAM_BASE_COLOR);
  });

  it("defines dimensions and border radii for every symbol", () => {
    expect(dimensionsForSymbol("rect_upright")).toEqual({
      width: "12px",
      height: "18px",
    });
    expect(borderRadiusForSymbol("rect_upright")).toBe("2px");

    expect(dimensionsForSymbol("rect_square")).toEqual({
      width: "15px",
      height: "15px",
    });
    expect(borderRadiusForSymbol("rect_square")).toBe("2px");

    expect(dimensionsForSymbol("circle")).toEqual({
      width: "15px",
      height: "15px",
    });
    expect(borderRadiusForSymbol("circle")).toBe("9999px");
  });

  it("renders every location type in one unified level color, fill and stroke", () => {
    const color = "#123ABC";

    expect(treatmentForLocationType(0, color)).toEqual({
      symbol: "rect_upright",
      fill: color,
      stroke: color,
      width: "12px",
      height: "18px",
      borderRadius: "2px",
    });

    // Entrance/Exit (2) gets no white-outline treatment — solid level color.
    expect(treatmentForLocationType(2, color)).toEqual({
      symbol: "rect_upright",
      fill: color,
      stroke: color,
      width: "12px",
      height: "18px",
      borderRadius: "2px",
    });

    expect(treatmentForLocationType(4, color)).toEqual({
      symbol: "rect_square",
      fill: color,
      stroke: color,
      width: "15px",
      height: "15px",
      borderRadius: "2px",
    });

    expect(treatmentForLocationType("not-a-location-type", color)).toEqual({
      symbol: "circle",
      fill: color,
      stroke: color,
      width: "15px",
      height: "15px",
      borderRadius: "9999px",
    });
  });
});

describe("cross-level pathway badges", () => {
  it("maps stairs and escalator modes to the staircase glyph", () => {
    expect(badgeSymbolForMode(2)).toBe("stairs");
    expect(badgeSymbolForMode(4)).toBe("stairs");
    expect(badgeSymbolForMode("2")).toBe("stairs");
  });

  it("maps every other cross-level mode to the elevator glyph", () => {
    expect(badgeSymbolForMode(5)).toBe("elevator");
    expect(badgeSymbolForMode(1)).toBe("elevator");
    expect(badgeSymbolForMode(undefined)).toBe("elevator");
  });

  it("renders an SVG glyph in the level color tagged by symbol", () => {
    const stairs = createBadgeElement(2, "#123ABC", 0);
    expect(stairs.tagName.toLowerCase()).toBe("svg");
    expect(stairs.dataset.badgeSymbol).toBe("stairs");
    const path = stairs.querySelector("path");
    expect(path.getAttribute("fill")).toBe("#123ABC");
    // No white halo — the badge is a single unified color.
    expect(path.getAttribute("stroke")).toBe(null);

    const elevator = createBadgeElement(5, "#123ABC", 0);
    expect(elevator.dataset.badgeSymbol).toBe("elevator");
  });

  it("stacks successive badges horizontally by index", () => {
    const first = createBadgeElement(2, "#123ABC", 0);
    const second = createBadgeElement(5, "#123ABC", 1);
    expect(first.style.left).not.toBe(second.style.left);
  });

  it("appends one badge element per pathway in the level color, and nothing without badges", () => {
    const marker = document.createElement("div");
    appendStopBadges(marker, [{ pathway_mode: 2 }, { pathway_mode: 5 }], "#123ABC");
    const badges = marker.querySelectorAll("svg.map-stop-badge");
    expect(badges).toHaveLength(2);
    expect(badges[0].querySelector("path").getAttribute("fill")).toBe("#123ABC");

    const empty = document.createElement("div");
    appendStopBadges(empty, [], "#123ABC");
    appendStopBadges(empty, undefined, "#123ABC");
    expect(empty.querySelectorAll("svg.map-stop-badge")).toHaveLength(0);
  });
});
