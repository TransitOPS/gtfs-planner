import { describe, expect, it } from "vitest";
import {
  containedImageRect,
  normalizeDiagramPoint,
  previewPointForDiagramCoordinate,
} from "../floorplan_preview_points";

describe("normalizeDiagramPoint", () => {
  it("accepts numeric and numeric-string coordinate keys", () => {
    expect(normalizeDiagramPoint({ x: 50, y: 40 })).toEqual({ x: 50, y: 40 });
    expect(normalizeDiagramPoint({ x: "50", y: "40.5" })).toEqual({
      x: 50,
      y: 40.5,
    });
  });

  it("rejects missing or non-finite coordinates", () => {
    expect(normalizeDiagramPoint(null)).toBeNull();
    expect(normalizeDiagramPoint({ x: 50 })).toBeNull();
    expect(normalizeDiagramPoint({ x: 50, y: "abc" })).toBeNull();
    expect(normalizeDiagramPoint({ x: NaN, y: 1 })).toBeNull();
  });
});

describe("containedImageRect", () => {
  it("returns the letterboxed bounds for an aspect mismatch", () => {
    // 1000x1000 image in a 500x400 canvas: contain scale 0.4, 50px horizontal
    // letterbox, zero vertical letterbox.
    expect(
      containedImageRect({
        canvasWidth: 500,
        canvasHeight: 400,
        imageNaturalWidth: 1000,
        imageNaturalHeight: 1000,
      }),
    ).toEqual({ x: 50, y: 0, width: 400, height: 400 });
  });

  it("rejects non-positive dimensions", () => {
    expect(
      containedImageRect({
        canvasWidth: 0,
        canvasHeight: 400,
        imageNaturalWidth: 1000,
        imageNaturalHeight: 1000,
      }),
    ).toBeNull();
    expect(
      containedImageRect({
        canvasWidth: 500,
        canvasHeight: 400,
        imageNaturalWidth: -1000,
        imageNaturalHeight: 1000,
      }),
    ).toBeNull();
  });
});

describe("previewPointForDiagramCoordinate", () => {
  it("rejects invalid transforms", () => {
    const base = {
      coordinate: { x: 50, y: 40 },
      canvasWidth: 500,
      canvasHeight: 400,
      imageNaturalWidth: 1000,
      imageNaturalHeight: 800,
    };

    expect(
      previewPointForDiagramCoordinate({
        ...base,
        transform: { tx: 0, ty: 0, rotation: 0 },
      }),
    ).toBeNull();
    expect(
      previewPointForDiagramCoordinate({
        ...base,
        transform: { tx: 0, ty: 0, rotation: Infinity, scale: 1 },
      }),
    ).toBeNull();
    expect(
      previewPointForDiagramCoordinate({
        ...base,
        transform: { tx: 0, ty: 0, rotation: 0, scale: 0 },
      }),
    ).toBeNull();
  });

  it("rejects an invalid coordinate", () => {
    expect(
      previewPointForDiagramCoordinate({
        coordinate: { x: 50 },
        transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
        canvasWidth: 500,
        canvasHeight: 400,
        imageNaturalWidth: 1000,
        imageNaturalHeight: 800,
      }),
    ).toBeNull();
  });

  it("applies the letterbox offset for the image-center point", () => {
    // 1000x1000 image in 500x400 canvas. The image-center diagram point lands
    // at canvas x=250 ONLY when the 50px horizontal letterbox offset is added;
    // dropping the offset would yield x=200.
    expect(
      previewPointForDiagramCoordinate({
        coordinate: { x: 50, y: 50 },
        transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
        canvasWidth: 500,
        canvasHeight: 400,
        imageNaturalWidth: 1000,
        imageNaturalHeight: 1000,
      }),
    ).toEqual({ x: 250, y: 200 });
  });

  it("maps the center golden fixture with translation", () => {
    expect(
      previewPointForDiagramCoordinate({
        coordinate: { x: 50, y: 40 },
        transform: { tx: 12, ty: -8, rotation: 0, scale: 1 },
        canvasWidth: 500,
        canvasHeight: 400,
        imageNaturalWidth: 1000,
        imageNaturalHeight: 800,
      }),
    ).toEqual({ x: 262, y: 192 });
  });

  it("maps the 90-degree off-center golden fixture", () => {
    expect(
      previewPointForDiagramCoordinate({
        coordinate: { x: 60, y: 40 },
        transform: { tx: 0, ty: 0, rotation: 90, scale: 1 },
        canvasWidth: 500,
        canvasHeight: 400,
        imageNaturalWidth: 1000,
        imageNaturalHeight: 800,
      }),
    ).toEqual({ x: 250, y: 250 });
  });

  it("applies scale before rotation around the canvas center", () => {
    // Off-center point {60,40} sits 50px right of center in contained pixels.
    // scale:2 magnifies that to 100px, then rotation:90 sends it downward, so
    // the result lands 100px below center: { x: 250, y: 300 }. Without scale
    // the same rotation would land at { x: 250, y: 250 }.
    expect(
      previewPointForDiagramCoordinate({
        coordinate: { x: 60, y: 40 },
        transform: { tx: 0, ty: 0, rotation: 90, scale: 2 },
        canvasWidth: 500,
        canvasHeight: 400,
        imageNaturalWidth: 1000,
        imageNaturalHeight: 800,
      }),
    ).toEqual({ x: 250, y: 300 });
  });
});
