/* @vitest-environment jsdom */
import { describe, expect, it } from "vitest";
import {
  DIAGRAM_ACTIVE_COLOR,
  DIAGRAM_BASE_COLOR,
  HALO_COLOR,
  borderRadiusForSymbol,
  dimensionsForSymbol,
  isOutlineType,
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
    expect(DIAGRAM_BASE_COLOR).toBe("#0080FF");
    expect(DIAGRAM_ACTIVE_COLOR).toBe("#FF4500");
    expect(HALO_COLOR).toBe("#FFFFFF");
  });

  it("defines dimensions and border radii for every symbol", () => {
    expect(dimensionsForSymbol("rect_upright")).toEqual({
      width: "8px",
      height: "12px",
    });
    expect(borderRadiusForSymbol("rect_upright")).toBe("2px");

    expect(dimensionsForSymbol("rect_square")).toEqual({
      width: "10px",
      height: "10px",
    });
    expect(borderRadiusForSymbol("rect_square")).toBe("2px");

    expect(dimensionsForSymbol("circle")).toEqual({
      width: "10px",
      height: "10px",
    });
    expect(borderRadiusForSymbol("circle")).toBe("9999px");
  });

  it("treats only Entrance/Exit location types as outline markers", () => {
    expect(isOutlineType(0)).toBe(false);
    expect(isOutlineType(1)).toBe(false);
    expect(isOutlineType(2)).toBe(true);
    expect(isOutlineType("2")).toBe(true);
    expect(isOutlineType(3)).toBe(false);
    expect(isOutlineType(4)).toBe(false);
    expect(isOutlineType(undefined)).toBe(false);
    expect(isOutlineType(null)).toBe(false);
    expect(isOutlineType("not-a-location-type")).toBe(false);
  });

  it("returns the exact icon treatment table for map render paths", () => {
    const color = "#123ABC";

    expect(treatmentForLocationType(0, color)).toEqual({
      symbol: "rect_upright",
      outline: false,
      fill: color,
      stroke: "#FFFFFF",
      width: "8px",
      height: "12px",
      borderRadius: "2px",
    });

    expect(treatmentForLocationType(2, color)).toEqual({
      symbol: "rect_upright",
      outline: true,
      fill: "#FFFFFF",
      stroke: color,
      width: "8px",
      height: "12px",
      borderRadius: "2px",
    });

    expect(treatmentForLocationType(4, color)).toEqual({
      symbol: "rect_square",
      outline: false,
      fill: color,
      stroke: "#FFFFFF",
      width: "10px",
      height: "10px",
      borderRadius: "2px",
    });

    expect(treatmentForLocationType("not-a-location-type", color)).toEqual({
      symbol: "circle",
      outline: false,
      fill: color,
      stroke: "#FFFFFF",
      width: "10px",
      height: "10px",
      borderRadius: "9999px",
    });
  });
});
