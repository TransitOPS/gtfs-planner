/* @vitest-environment jsdom */
import { beforeEach, describe, expect, it, vi } from "vitest";
import DiagramCanvasHook from "../diagram_canvas_hook";

// The overlay draws in viewBox units. On screen, one unit is `pxPerUnit` CSS
// pixels: the plan's fitted size (px per unit at 100% zoom) times the zoom.
// Tests stub that conversion the way the browser reports it (the overlay's
// screen CTM) and read sizes back in screen pixels.
const FITTED_PX_PER_UNIT = 6.5;

describe("DiagramCanvasHook.scaleOverlayElements", () => {
  beforeEach(() => {
    document.body.innerHTML = `
      <div id="container">
        <div
          id="diagram-edit-tooltip"
          class="diagram-edit-tooltip is-hidden"
          role="tooltip"
          aria-hidden="true"
        ></div>
        <svg id="diagram-overlay">
          <defs>
            <marker id="pathway-arrow" markerWidth="1.5" markerHeight="1.5"></marker>
          </defs>
          <g id="stops-svg">
            <g
              id="editable-stop"
              data-tooltip="Click to edit stop"
              data-tooltip-color="#0080FF"
              tabindex="0"
              aria-label="Stop Editable Stop (EDIT_STOP)"
            >
              <rect
                id="editable-stop-hit"
                x="10"
                y="10"
                width="2"
                height="2"
                data-tooltip-trigger="true"
              ></rect>
            </g>
            <rect
              id="stop-hit"
              data-stop-hit-target="true"
              data-center-x="10"
              data-center-y="20"
            ></rect>
            <rect
              id="platform-hit"
              data-stop-hit-target="true"
              data-location-type="0"
              data-center-x="14"
              data-center-y="24"
            ></rect>
            <circle
              id="stop-marker"
              data-stop-marker="true"
              data-location-type="3"
              data-center-x="10"
              data-center-y="20"
            ></circle>
            <rect
              id="stop-platform"
              data-stop-marker="true"
              data-location-type="0"
              data-center-x="14"
              data-center-y="24"
            ></rect>
            <rect
              id="stop-entrance"
              data-stop-marker="true"
              data-location-type="2"
              data-center-x="16"
              data-center-y="26"
            ></rect>
            <rect
              id="stop-boarding-area"
              data-stop-marker="true"
              data-location-type="4"
              data-center-x="20"
              data-center-y="30"
            ></rect>
            <rect
              id="stop-label-box"
              data-stop-label-box="true"
              data-center-x="10"
              data-center-y="20"
              data-base-width="80"
              data-base-height="32"
              data-base-padding-x="6"
              data-base-padding-y="2"
              data-base-stroke="1"
            ></rect>
            <text
              id="stop-label"
              data-stop-label="true"
              data-center-x="10"
              data-center-y="20"
              data-label-offset-x="2"
              data-label-offset-y="10"
              data-base-font-size="12"
              data-base-stroke="3"
              data-base-line-height="14"
            >
              <tspan id="stop-label-line-1">Line one</tspan>
              <tspan id="stop-label-line-2">Line two</tspan>
            </text>
            <path
              id="cross-level-stairs"
              data-cross-level-badge-stairs="true"
              data-center-x="10"
              data-center-y="20"
              data-badge-offset-x="22"
            ></path>
            <rect
              id="cross-level-stairs-hit"
              data-cross-level-badge-hit="true"
              data-base-size="20"
              data-center-x="10"
              data-center-y="20"
              data-badge-offset-x="22"
            ></rect>
            <path
              id="cross-level-elevator"
              data-cross-level-badge-elevator="true"
              data-center-x="10"
              data-center-y="20"
              data-badge-offset-x="22"
            ></path>
            <rect
              id="cross-level-elevator-hit"
              data-cross-level-badge-hit="true"
              data-base-size="20"
              data-center-x="10"
              data-center-y="20"
              data-badge-offset-x="22"
            ></rect>
          </g>
          <g id="journal-markers-svg" phx-update="stream">
            <g id="journal-pin-g" data-journal-pin="true" data-center-x="40" data-center-y="50"></g>
            <circle id="journal-dot" data-journal-dot="true" data-center-x="25" data-center-y="35"></circle>
            <circle id="journal-ring" data-journal-ring="true" data-center-x="40" data-center-y="50"></circle>
            <rect id="journal-hit" data-journal-hit-target="true" data-journal-kind="pin" data-center-x="40" data-center-y="50"></rect>
            <rect id="journal-node-hit" data-journal-hit-target="true" data-journal-kind="node" data-center-x="25" data-center-y="35"></rect>
            <rect id="journal-invalid-hit" data-journal-hit-target="true" data-journal-kind="pin" data-center-x="invalid" data-center-y="50"></rect>
          </g>
          <g id="pathways-svg">
            <g
              id="editable-pathway"
              data-tooltip="Click to edit pathway"
              data-tooltip-color="#FF00FF"
              tabindex="0"
              aria-label="Walkway pathway from A to B"
            >
              <line
                id="editable-pathway-hit"
                x1="20"
                y1="20"
                x2="30"
                y2="20"
                stroke="transparent"
                data-tooltip-trigger="true"
              ></line>
            </g>
            <line id="path-hit" data-pathway-hit="true" data-base-stroke="14"></line>
            <line id="path-tooltip-hit" data-pathway-tooltip-hit="true" data-base-stroke="6"></line>
            <line id="path-casing" data-pathway-casing="true" data-base-stroke="4.5"></line>
            <line id="path-line" data-pathway-line="true" data-base-stroke="2.5"></line>
            <line
              id="path-casing-paired"
              data-pathway-casing="true"
              data-base-stroke="5.5"
            ></line>
            <line
              id="path-line-paired"
              data-pathway-line="true"
              data-base-stroke="3.5"
            ></line>
            <line
              id="path-dashed"
              data-pathway-line="true"
              data-base-stroke="2.5"
              data-base-dash="6,3"
            ></line>
            <line
              id="casing-arrow-trim"
              x1="10"
              y1="10"
              x2="20"
              y2="10"
              data-pathway-casing="true"
              data-pathway-end-trim="10"
              data-base-stroke="4.5"
            ></line>
            <line
              id="path-arrow-trim"
              x1="10"
              y1="10"
              x2="20"
              y2="10"
              marker-end="url(#pathway-arrow)"
              data-pathway-end-trim="10"
              data-base-stroke="2.5"
            ></line>
            <line
              id="stairs-bar"
              x1="40"
              y1="40"
              x2="40"
              y2="40"
              data-glyph-mid-x="40"
              data-glyph-mid-y="40"
              data-glyph-dir-x="1"
              data-glyph-dir-y="0"
              data-glyph-along="5"
              data-glyph-half-along="0"
              data-glyph-half-perp="5"
              data-base-stroke="2"
            ></line>
            <line
              id="gate-guide"
              x1="10"
              y1="70"
              x2="30"
              y2="70"
              data-pathway-arrow-guide="true"
            ></line>
            <line
              id="gate-rail-casing"
              data-pathway-casing="true"
              data-rail-base-offset="3.5"
              data-base-stroke="4.5"
            ></line>
            <line
              id="gate-rail"
              data-pathway-rail="true"
              data-rail-base-offset="3.5"
              data-base-stroke="2.5"
            ></line>
            <rect
              id="elevator-box"
              data-pathway-elevator-box="true"
              data-center-x="30"
              data-center-y="40"
              data-base-width="16"
              data-base-height="16"
              data-base-stroke="2.5"
            ></rect>
            <text
              id="elevator-text"
              data-pathway-elevator-text="true"
              data-center-x="30"
              data-center-y="40"
              data-base-font-size="11"
            ></text>
            <text
              id="path-label"
              data-pathway-label="true"
              data-midpoint-x="50"
              data-midpoint-y="60"
              data-offset-x="10"
              data-offset-y="-10"
              data-rotation="15"
              data-base-font-size="11"
              data-base-stroke="3"
            ></text>
          </g>
          <g id="ruler-layer">
            <line
              id="ruler-hit-area"
              data-ruler-hit-area="true"
              data-base-stroke="12"
              x1="10"
              y1="10"
              x2="20"
              y2="20"
            ></line>
            <line
              id="ruler-line"
              data-ruler-line="true"
              data-base-stroke="2"
              data-base-dash="6,4"
              x1="10"
              y1="10"
              x2="20"
              y2="20"
            ></line>
            <circle
              id="ruler-endpoint-a"
              data-ruler-endpoint="true"
              data-center-x="10"
              data-center-y="10"
              data-base-radius="4"
              data-base-stroke="2"
            ></circle>
            <text
              id="ruler-label"
              data-ruler-label="true"
              data-midpoint-x="15"
              data-midpoint-y="15"
              data-label-offset-y="-12"
              data-base-font-size="11"
              data-base-stroke="3"
            ></text>
            <text
              id="ruler-label-saved"
              data-ruler-label="true"
              data-label-anchor-x="10"
              data-label-anchor-y="10"
              data-label-offset-x="8"
              data-label-offset-y="0"
              data-base-font-size="11"
              data-base-stroke="3"
            ></text>
          </g>
          <polygon
            id="pending"
            data-cx="10"
            data-cy="20"
            points="10,19 9.25,20.5 10.75,20.5"
            stroke-width="0.15"
          ></polygon>
        </svg>
        <svg id="canvas"></svg>
      </div>
    `;
  });

  const overlay = () => document.querySelector("#diagram-overlay");
  const attr = (selector, name) => parseFloat(document.querySelector(selector).getAttribute(name));

  // Lays the overlay out at `fitted` px per unit and applies `zoom`, then runs
  // the hook. Returns the px-per-unit so tests can convert attributes to pixels.
  const render = ({ fitted = FITTED_PX_PER_UNIT, zoom = 1 } = {}) => {
    const pxPerUnit = fitted * zoom;
    overlay().getScreenCTM = () => ({ a: pxPerUnit });

    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
    };

    hook.scale = zoom;
    hook.scaleOverlayElements();

    return { hook, pxPerUnit };
  };

  const buildTooltipHook = () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
      viewBox: { x: 0, y: 0, w: 100, h: 100 },
      scale: 1,
      tooltipState: { activeTarget: null, visible: false, anchor: null },
      tooltipListenersBound: false,
      tooltipListenerOverlay: null,
    };

    hook.refreshTooltipElements();
    hook.setupTooltipListeners();
    return hook;
  };

  describe("text", () => {
    it.each([
      ["a wide canvas at 100% zoom", 13, 1],
      ["a narrow canvas at 100% zoom", 3.2, 1],
      ["a wide canvas at 250% zoom", 13, 2.5],
      ["a narrow canvas at 250% zoom", 3.2, 2.5],
    ])("renders a point label 12px with a 3px halo on %s", (_name, fitted, zoom) => {
      const { pxPerUnit } = render({ fitted, zoom });

      expect(attr("#stop-label", "font-size") * pxPerUnit).toBeCloseTo(12, 6);
      expect(attr("#stop-label", "stroke-width") * pxPerUnit).toBeCloseTo(3, 6);
    });

    it.each([
      ["100%", 1],
      ["250%", 2.5],
    ])("spaces point label lines 14px apart at %s zoom", (_name, zoom) => {
      const { pxPerUnit } = render({ zoom });

      expect(attr("#stop-label-line-1", "dy")).toBe(0);
      expect(attr("#stop-label-line-2", "dy") * pxPerUnit).toBeCloseTo(14, 6);
    });

    it("places a point label 2px right of and 10px below its marker at any zoom", () => {
      const { pxPerUnit } = render({ zoom: 2.5 });

      expect((attr("#stop-label", "x") - 10) * pxPerUnit).toBeCloseTo(2, 6);
      expect((attr("#stop-label", "y") - 20) * pxPerUnit).toBeCloseTo(10, 6);
      expect(attr("#stop-label-line-2", "x")).toBe(attr("#stop-label", "x"));
    });

    it("sizes the point label box in px around the label", () => {
      const { pxPerUnit } = render();

      expect(attr("#stop-label-box", "width") * pxPerUnit).toBeCloseTo(80, 6);
      expect(attr("#stop-label-box", "height") * pxPerUnit).toBeCloseTo(32, 6);
      expect((attr("#stop-label", "x") - attr("#stop-label-box", "x")) * pxPerUnit).toBeCloseTo(6, 6);
    });

    it.each([
      ["200%", 2],
      ["250%", 2.5],
    ])("renders pathway sign, elevator and ruler text 11px at %s zoom", (_name, zoom) => {
      const { pxPerUnit } = render({ zoom });

      expect(attr("#path-label", "font-size") * pxPerUnit).toBeCloseTo(11, 6);
      expect(attr("#elevator-text", "font-size") * pxPerUnit).toBeCloseTo(11, 6);
      expect(attr("#ruler-label", "font-size") * pxPerUnit).toBeCloseTo(11, 6);
      expect(attr("#ruler-label-saved", "font-size") * pxPerUnit).toBeCloseTo(11, 6);
    });

    it("keeps ruler text 11px where the label first shows, at 90% zoom", () => {
      const { pxPerUnit } = render({ zoom: 0.9 });

      expect(attr("#ruler-label", "font-size") * pxPerUnit).toBeCloseTo(11, 6);
    });

    it("keeps point label text at 12px where labels first show, at 85% zoom", () => {
      const { pxPerUnit } = render({ fitted: 13, zoom: 0.85 });

      expect(attr("#stop-label", "font-size") * pxPerUnit).toBeCloseTo(12, 6);
    });

    it("offsets pathway signs 10px from the line and rotates them about the text", () => {
      const { pxPerUnit } = render({ zoom: 1.2 });
      const x = attr("#path-label", "x");
      const y = attr("#path-label", "y");

      expect((x - 50) * pxPerUnit).toBeCloseTo(10, 6);
      expect((y - 60) * pxPerUnit).toBeCloseTo(-10, 6);
      expect(document.querySelector("#path-label").getAttribute("transform")).toBe(
        `rotate(15, ${x}, ${y})`,
      );
    });
  });

  describe("markers", () => {
    it.each([
      ["a wide canvas", 13],
      ["a narrow canvas", 3.2],
    ])("draws a node circle 12px across with a 2px ring on %s", (_name, fitted) => {
      const { pxPerUnit } = render({ fitted });

      expect(attr("#stop-marker", "r") * pxPerUnit * 2).toBeCloseTo(12, 6);
      // The ring is painted under the fill, so half its stroke shows.
      expect((attr("#stop-marker", "stroke-width") * pxPerUnit) / 2).toBeCloseTo(2, 6);
    });

    it.each([
      ["100%", 1],
      ["250%", 2.5],
    ])("draws platforms and entrances 12x20px and boarding areas 12px at %s zoom", (_name, zoom) => {
      const { pxPerUnit } = render({ zoom });

      expect(attr("#stop-platform", "width") * pxPerUnit).toBeCloseTo(12, 6);
      expect(attr("#stop-platform", "height") * pxPerUnit).toBeCloseTo(20, 6);
      expect(attr("#stop-entrance", "width") * pxPerUnit).toBeCloseTo(12, 6);
      expect(attr("#stop-entrance", "height") * pxPerUnit).toBeCloseTo(20, 6);
      expect(attr("#stop-boarding-area", "width") * pxPerUnit).toBeCloseTo(12, 6);
      expect(attr("#stop-boarding-area", "height") * pxPerUnit).toBeCloseTo(12, 6);
    });

    it("anchors upright markers so 80% of their height sits above the stop coordinate", () => {
      const { pxPerUnit } = render({ zoom: 2.5 });

      expect((24 - attr("#stop-platform", "y")) * pxPerUnit).toBeCloseTo(16, 6);
      expect(attr("#stop-platform", "x") + attr("#stop-platform", "width") / 2).toBeCloseTo(14, 6);
    });

    it("shrinks markers to 75% at 50% zoom while text keeps its size", () => {
      const { pxPerUnit } = render({ fitted: 13, zoom: 0.5 });

      expect(attr("#stop-platform", "height") * pxPerUnit).toBeCloseTo(15, 6);
      expect(attr("#stop-platform", "width") * pxPerUnit).toBeCloseTo(9, 6);
      expect(attr("#stop-marker", "r") * pxPerUnit * 2).toBeCloseTo(9, 6);
      expect(attr("#ruler-endpoint-a", "r") * pxPerUnit).toBeCloseTo(4, 6);
    });

    it("keeps markers full size at 100% zoom and above", () => {
      const { pxPerUnit } = render({ zoom: 1 });

      expect(attr("#stop-platform", "height") * pxPerUnit).toBeCloseTo(20, 6);
    });

    it.each([
      ["a wide canvas", 13, 1],
      ["a narrow canvas", 3.2, 1],
      ["50% zoom", 6.5, 0.5],
      ["250% zoom", 6.5, 2.5],
    ])("gives every stop a hit target at least 24px square on %s", (_name, fitted, zoom) => {
      const { pxPerUnit } = render({ fitted, zoom });

      expect(attr("#stop-hit", "width") * pxPerUnit).toBeGreaterThanOrEqual(24 - 1e-9);
      expect(attr("#stop-hit", "height") * pxPerUnit).toBeGreaterThanOrEqual(24 - 1e-9);
      expect(attr("#platform-hit", "width") * pxPerUnit).toBeGreaterThanOrEqual(24 - 1e-9);
      expect(attr("#platform-hit", "height") * pxPerUnit).toBeGreaterThanOrEqual(24 - 1e-9);
    });

    it("centers the hit target on the marker body", () => {
      const { pxPerUnit } = render();

      // A circle sits on the coordinate; an upright marker's body center is 6px above it.
      expect(attr("#stop-hit", "x") + attr("#stop-hit", "width") / 2).toBeCloseTo(10, 6);
      expect(attr("#stop-hit", "y") + attr("#stop-hit", "height") / 2).toBeCloseTo(20, 6);
      expect(attr("#platform-hit", "x") + attr("#platform-hit", "width") / 2).toBeCloseTo(14, 6);
      expect(24 - (attr("#platform-hit", "y") + attr("#platform-hit", "height") / 2)).toBeCloseTo(
        6 / pxPerUnit,
        6,
      );
    });

    it("draws the pending marker as a 16px-wide triangle", () => {
      const { pxPerUnit } = render({ zoom: 2 });
      const points = document
        .querySelector("#pending")
        .getAttribute("points")
        .split(" ")
        .map((pair) => pair.split(",").map(parseFloat));

      expect((points[2][0] - points[1][0]) * pxPerUnit).toBeCloseTo(16, 6);
      expect((points[1][1] - points[0][1]) * pxPerUnit).toBeCloseTo(16, 6);
    });
  });

  describe("pathways", () => {
    it.each([
      ["100%", 1],
      ["250%", 2.5],
    ])("draws pathway lines 2.5px, and 3.5px when paired, at %s zoom", (_name, zoom) => {
      const { pxPerUnit } = render({ zoom });

      expect(attr("#path-line", "stroke-width") * pxPerUnit).toBeCloseTo(2.5, 6);
      expect(attr("#path-dashed", "stroke-width") * pxPerUnit).toBeCloseTo(2.5, 6);
      expect(attr("#path-line-paired", "stroke-width") * pxPerUnit).toBeCloseTo(3.5, 6);
    });

    it.each([
      ["100%", 1],
      ["250%", 2.5],
    ])("draws the white casing 1px wider than its line on each side at %s zoom", (_name, zoom) => {
      const { pxPerUnit } = render({ zoom });
      const casing = attr("#path-casing", "stroke-width") * pxPerUnit;
      const line = attr("#path-line", "stroke-width") * pxPerUnit;

      expect(casing).toBeCloseTo(4.5, 6);
      expect(casing - line).toBeCloseTo(2, 6);
      expect(attr("#path-casing-paired", "stroke-width") * pxPerUnit).toBeCloseTo(5.5, 6);
    });

    it("ends a casing 10px short of each stop, like its line", () => {
      const { pxPerUnit } = render({ zoom: 2 });

      expect((attr("#casing-arrow-trim", "x1") - 10) * pxPerUnit).toBeCloseTo(10, 6);
      expect((20 - attr("#casing-arrow-trim", "x2")) * pxPerUnit).toBeCloseTo(10, 6);
    });

    it("offsets a rail casing 3.5px from the pathway line, with its rail", () => {
      const { pxPerUnit } = render({ zoom: 2 });

      expect((attr("#gate-rail-casing", "y1") - 70) * pxPerUnit).toBeCloseTo(3.5, 6);
      expect(attr("#gate-rail-casing", "y1")).toBeCloseTo(attr("#gate-rail", "y1"), 9);
    });

    it("scales dashes with the pathway line", () => {
      const { pxPerUnit } = render({ zoom: 2 });
      const dashes = document
        .querySelector("#path-dashed")
        .getAttribute("stroke-dasharray")
        .split(" ")
        .map((value) => parseFloat(value) * pxPerUnit);

      expect(dashes[0]).toBeCloseTo(6, 6);
      expect(dashes[1]).toBeCloseTo(3, 6);
    });

    it("draws the arrowhead 8px", () => {
      const { pxPerUnit } = render({ zoom: 2 });

      expect(attr("#pathway-arrow", "markerWidth") * pxPerUnit).toBeCloseTo(8, 6);
      expect(attr("#pathway-arrow", "markerHeight") * pxPerUnit).toBeCloseTo(8, 6);
    });

    it("ends an arrow line 10px short of each stop", () => {
      const { pxPerUnit } = render({ zoom: 2 });

      expect((attr("#path-arrow-trim", "x1") - 10) * pxPerUnit).toBeCloseTo(10, 6);
      expect((20 - attr("#path-arrow-trim", "x2")) * pxPerUnit).toBeCloseTo(10, 6);
    });

    it("keeps the pathway click target 14px wide at any zoom", () => {
      const { pxPerUnit } = render({ zoom: 0.5 });

      expect(attr("#path-hit", "stroke-width") * pxPerUnit).toBeCloseTo(14, 6);
      expect(attr("#path-tooltip-hit", "stroke-width") * pxPerUnit).toBeCloseTo(6, 6);
    });

    it("lays a stairs bar 10px across, centered 5px along the pathway from its midpoint", () => {
      const { pxPerUnit } = render({ zoom: 2 });
      const x1 = attr("#stairs-bar", "x1");
      const y1 = attr("#stairs-bar", "y1");
      const x2 = attr("#stairs-bar", "x2");
      const y2 = attr("#stairs-bar", "y2");

      expect(Math.hypot(x2 - x1, y2 - y1) * pxPerUnit).toBeCloseTo(10, 6);
      expect(((x1 + x2) / 2 - 40) * pxPerUnit).toBeCloseTo(5, 6);
      expect(x1).toBeCloseTo(x2, 9);
    });

    it("offsets gate rails 3.5px from the pathway line", () => {
      const { pxPerUnit } = render({ zoom: 2 });

      expect((attr("#gate-rail", "y1") - 70) * pxPerUnit).toBeCloseTo(3.5, 6);
      expect(attr("#gate-rail", "y2")).toBeCloseTo(attr("#gate-rail", "y1"), 9);
    });

    it("draws the elevator box 16px square with a 2.5px outline that does not shrink", () => {
      const { pxPerUnit } = render({ fitted: 13, zoom: 0.5 });

      expect(attr("#elevator-box", "width") * pxPerUnit).toBeCloseTo(16, 6);
      expect(attr("#elevator-box", "height") * pxPerUnit).toBeCloseTo(16, 6);
      expect(attr("#elevator-box", "stroke-width") * pxPerUnit).toBeCloseTo(2.5, 6);
      expect(attr("#elevator-box", "x") + attr("#elevator-box", "width") / 2).toBeCloseTo(30, 6);
    });
  });

  describe("cross-level badges and journal markers", () => {
    it("draws stairs and elevator badges 15px and 16px tall, 22px right of the stop", () => {
      const { pxPerUnit } = render({ zoom: 2 });
      const stairs = document.querySelector("#cross-level-stairs").getAttribute("d");
      const stairsXs = [...stairs.matchAll(/[ML] ([-\d.e]+) ([-\d.e]+)/g)].map((m) => parseFloat(m[1]));
      const stairsYs = [...stairs.matchAll(/[ML] ([-\d.e]+) ([-\d.e]+)/g)].map((m) => parseFloat(m[2]));
      const elevator = document.querySelector("#cross-level-elevator").getAttribute("d");
      const elevatorYs = [...elevator.matchAll(/[ML] ([-\d.e]+) ([-\d.e]+)/g)].map((m) => parseFloat(m[2]));

      expect((Math.max(...stairsXs) - Math.min(...stairsXs)) * pxPerUnit).toBeCloseTo(15, 6);
      expect((Math.max(...stairsYs) - Math.min(...stairsYs)) * pxPerUnit).toBeCloseTo(15, 6);
      expect(((Math.max(...stairsXs) + Math.min(...stairsXs)) / 2 - 10) * pxPerUnit).toBeCloseTo(22, 6);
      expect((Math.max(...elevatorYs) - Math.min(...elevatorYs)) * pxPerUnit).toBeCloseTo(16, 6);
    });

    it.each([
      ["100%", 1],
      ["250%", 2.5],
    ])("gives badges a 20px hit target at %s zoom", (_name, zoom) => {
      const { pxPerUnit } = render({ zoom });

      for (const id of ["#cross-level-stairs-hit", "#cross-level-elevator-hit"]) {
        expect(attr(id, "width") * pxPerUnit).toBeCloseTo(20, 6);
        expect(attr(id, "height") * pxPerUnit).toBeCloseTo(20, 6);
        expect((attr(id, "x") + attr(id, "width") / 2 - 10) * pxPerUnit).toBeCloseTo(22, 6);
      }
    });

    it("defaults the badge hit target to 20px when the server sends no size", () => {
      document.querySelector("#cross-level-stairs-hit").removeAttribute("data-base-size");
      const { pxPerUnit } = render();

      expect(attr("#cross-level-stairs-hit", "width") * pxPerUnit).toBeCloseTo(20, 6);
    });

    it("leaves a badge hit target unchanged when its center is not a number", () => {
      const stairsHit = document.querySelector("#cross-level-stairs-hit");
      stairsHit.setAttribute("data-center-x", "not-a-number");
      stairsHit.setAttribute("width", "1.23");
      stairsHit.setAttribute("height", "4.56");

      expect(() => render({ zoom: 2 })).not.toThrow();
      expect(stairsHit.getAttribute("width")).toBe("1.23");
      expect(stairsHit.getAttribute("height")).toBe("4.56");
    });

    it("draws journal dots, rings, pins and hit targets in px and skips malformed geometry", () => {
      const { pxPerUnit } = render({ zoom: 2 });
      const invalidHit = document.querySelector("#journal-invalid-hit");

      expect(attr("#journal-dot", "cx")).toBe(25);
      expect(attr("#journal-dot", "cy")).toBe(35);
      expect(attr("#journal-dot", "r") * pxPerUnit).toBeCloseTo(6, 6);
      expect(attr("#journal-ring", "cx")).toBe(40);
      expect(attr("#journal-ring", "r") * pxPerUnit).toBeCloseTo(13, 6);
      const pinTransform = document.querySelector("#journal-pin-g").getAttribute("transform");
      const [, pinScale] = pinTransform.match(/^translate\(40, 50\) scale\(([-\d.e]+)\)$/);
      // The pin path is drawn in its own units; each covers 11px.
      expect(parseFloat(pinScale) * pxPerUnit).toBeCloseTo(11, 6);
      expect(attr("#journal-hit", "width") * pxPerUnit).toBeCloseTo(24, 6);
      expect(attr("#journal-hit", "height") * pxPerUnit).toBeCloseTo(24, 6);
      expect(attr("#journal-node-hit", "width") * pxPerUnit).toBeCloseTo(24, 6);
      expect(invalidHit.getAttribute("x")).toBe(null);
    });

    it("puts a pin's hit target over its body, above the tip", () => {
      const { pxPerUnit } = render();

      expect((50 - attr("#journal-hit", "y")) * pxPerUnit).toBeCloseTo(22, 6);
      expect((attr("#journal-hit", "y") + attr("#journal-hit", "height") - 50) * pxPerUnit).toBeCloseTo(2, 6);
    });
  });

  describe("ruler", () => {
    it.each([
      ["80%", 0.8],
      ["250%", 2.5],
    ])("draws the ruler line 2px with 4px-radius endpoints at %s zoom", (_name, zoom) => {
      const { pxPerUnit } = render({ zoom });

      expect(attr("#ruler-line", "stroke-width") * pxPerUnit).toBeCloseTo(2, 6);
      expect(attr("#ruler-hit-area", "stroke-width") * pxPerUnit).toBeCloseTo(12, 6);
      expect(attr("#ruler-endpoint-a", "r") * pxPerUnit).toBeCloseTo(4, 6);
      expect(attr("#ruler-endpoint-a", "stroke-width") * pxPerUnit).toBeCloseTo(2, 6);
    });

    it("scales ruler dashes in px", () => {
      const { pxPerUnit } = render({ zoom: 2 });
      const dashes = document
        .querySelector("#ruler-line")
        .getAttribute("stroke-dasharray")
        .split(" ")
        .map((value) => parseFloat(value) * pxPerUnit);

      expect(dashes[0]).toBeCloseTo(6, 6);
      expect(dashes[1]).toBeCloseTo(4, 6);
    });

    it("keeps ruler elements anchored while zooming", () => {
      const { hook } = render({ zoom: 1 });
      const initialY = document.querySelector("#ruler-label").getAttribute("y");

      overlay().getScreenCTM = () => ({ a: FITTED_PX_PER_UNIT * 3 });
      hook.scale = 3;
      hook.scaleOverlayElements();

      expect(document.querySelector("#ruler-endpoint-a").getAttribute("cx")).toBe("10");
      expect(document.querySelector("#ruler-endpoint-a").getAttribute("cy")).toBe("10");
      expect(document.querySelector("#ruler-label").getAttribute("x")).toBe("15");
      expect(document.querySelector("#ruler-label").getAttribute("y")).not.toBe(initialY);
    });

    it("offsets the measure label 12px above the midpoint and the saved label 8px right of its anchor", () => {
      const { pxPerUnit } = render({ zoom: 2 });

      expect((15 - attr("#ruler-label", "y")) * pxPerUnit).toBeCloseTo(12, 6);
      expect((attr("#ruler-label-saved", "x") - 10) * pxPerUnit).toBeCloseTo(8, 6);
    });
  });

  describe("visibility thresholds", () => {
    it("hides point labels below 85% zoom and shows them from 85%", () => {
      const label = () => document.querySelector("#stop-label");

      const { hook } = render({ fitted: 13, zoom: 0.8 });
      expect(label().getAttribute("display")).toBe("none");
      expect(document.querySelector("#stop-label-box").getAttribute("display")).toBe("none");

      overlay().getScreenCTM = () => ({ a: 13 * 0.85 });
      hook.scale = 0.85;
      hook.scaleOverlayElements();
      expect(label().getAttribute("display")).toBe(null);
    });

    it("hides pathway labels at 100% zoom and shows them above 110%", () => {
      const pathLabel = document.querySelector("#path-label");

      const { hook } = render({ zoom: 1 });
      expect(pathLabel.getAttribute("display")).toBe("none");

      overlay().getScreenCTM = () => ({ a: FITTED_PX_PER_UNIT * 1.2 });
      hook.scale = 1.2;
      hook.scaleOverlayElements();
      expect(pathLabel.getAttribute("display")).toBe(null);
    });

    it("skips pathway label updates when rotation is non-numeric", () => {
      const pathLabel = document.querySelector("#path-label");
      pathLabel.setAttribute("data-rotation", "invalid");
      pathLabel.setAttribute("transform", "rotate(45, 1, 1)");

      render({ zoom: 2 });

      expect(pathLabel.getAttribute("transform")).toBe("rotate(45, 1, 1)");
    });

    it("hides ruler labels below their zoom thresholds and shows them above", () => {
      const measure = () => document.querySelector("#ruler-label").getAttribute("display");
      const saved = () => document.querySelector("#ruler-label-saved").getAttribute("display");

      const { hook } = render({ zoom: 0.8 });
      expect([measure(), saved()]).toEqual(["none", "none"]);

      overlay().getScreenCTM = () => ({ a: FITTED_PX_PER_UNIT });
      hook.scale = 1;
      hook.scaleOverlayElements();
      expect([measure(), saved()]).toEqual([null, "none"]);

      overlay().getScreenCTM = () => ({ a: FITTED_PX_PER_UNIT * 2 });
      hook.scale = 2;
      hook.scaleOverlayElements();
      expect([measure(), saved()]).toEqual([null, null]);
    });

    it("hides ruler endpoints at or near 100% zoom and shows them outside that range", () => {
      const endpoint = () => document.querySelector("#ruler-endpoint-a").getAttribute("display");

      const { hook } = render({ zoom: 1 });
      expect(endpoint()).toBe("none");

      overlay().getScreenCTM = () => ({ a: FITTED_PX_PER_UNIT * 1.05 });
      hook.scale = 1.05;
      hook.scaleOverlayElements();
      expect(endpoint()).toBe("none");

      overlay().getScreenCTM = () => ({ a: FITTED_PX_PER_UNIT * 0.8 });
      hook.scale = 0.8;
      hook.scaleOverlayElements();
      expect(endpoint()).toBe(null);

      overlay().getScreenCTM = () => ({ a: FITTED_PX_PER_UNIT * 2 });
      hook.scale = 2;
      hook.scaleOverlayElements();
      expect(endpoint()).toBe(null);
    });
  });

  describe("layout", () => {
    it("leaves sizes untouched while the overlay has no layout", () => {
      overlay().getScreenCTM = () => null;
      const hook = { ...DiagramCanvasHook, el: document.querySelector("#canvas"), scale: 1 };

      expect(() => hook.scaleOverlayElements()).not.toThrow();
      expect(document.querySelector("#stop-label").getAttribute("font-size")).toBe(null);
      expect(document.querySelector("#stop-marker").getAttribute("r")).toBe(null);
    });

    it("resizes to the new canvas when the window changes", () => {
      const { hook } = render({ fitted: 13 });
      const before = attr("#stop-label", "font-size");

      overlay().getScreenCTM = () => ({ a: 3.2 });
      hook.scaleOverlayElements();

      expect(attr("#stop-label", "font-size") * 3.2).toBeCloseTo(12, 6);
      expect(attr("#stop-label", "font-size")).not.toBe(before);
    });

    it("exposes one screen pixel in overlay units to stylesheets", () => {
      const { pxPerUnit } = render({ zoom: 2 });

      expect(parseFloat(overlay().style.getPropertyValue("--diagram-px")) * pxPerUnit).toBeCloseTo(1, 6);
    });
  });

  describe("point label collisions", () => {
    // One overlay unit is one px, so coordinates and sizes below are px. Every
    // label is 60x14 (jsdom cannot measure text; the box attributes carry the
    // server's estimate, less 6px/2px padding).
    const LABEL_W = 60;
    const LABEL_H = 14;

    const point = ({ id, x, y, type = 3, selected = false, label = true }) => {
      const marker =
        type === 3
          ? `<circle data-stop-marker="true" data-location-type="${type}" data-center-x="${x}" data-center-y="${y}"></circle>`
          : `<rect data-stop-marker="true" data-location-type="${type}" data-center-x="${x}" data-center-y="${y}"></rect>`;
      const text = label
        ? `<rect id="${id}-box" data-stop-label-box="true" data-center-x="${x}" data-center-y="${y}"
             data-base-width="${LABEL_W + 12}" data-base-height="${LABEL_H + 4}"
             data-base-padding-x="6" data-base-padding-y="2" data-base-stroke="1"></rect>
           <text id="${id}-label" data-stop-label="true" data-location-type="${type}"
             data-center-x="${x}" data-center-y="${y}" data-label-offset-x="2" data-label-offset-y="10"
             data-base-font-size="12" data-base-stroke="3" data-base-line-height="14">
             <tspan id="${id}-line">${id}</tspan>
           </text>`
        : "";

      return `<g id="${id}" data-stop-state="${selected ? "selected" : "active"}">${marker}${text}</g>`;
    };

    const mount = (points) => {
      document.body.innerHTML = `
        <div id="container">
          <svg id="diagram-overlay"><g id="stops-svg">${points.map(point).join("")}</g></svg>
          <svg id="canvas"></svg>
        </div>
      `;
    };

    const label = (id) => document.querySelector(`#${id}-label`);
    const shown = (id) => label(id).getAttribute("display") === null;
    const labelRect = (id) => ({
      x: attr(`#${id}-label`, "x"),
      y: attr(`#${id}-label`, "y"),
      width: LABEL_W,
      height: LABEL_H,
    });
    const overlaps = (a, b) =>
      a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
    const renderPx = (options = {}) => render({ fitted: 1, ...options });

    it("moves a label that overlaps an earlier one to another side of its marker", () => {
      mount([
        { id: "a", x: 100, y: 100 },
        { id: "b", x: 110, y: 100 },
      ]);

      renderPx();

      expect(shown("a")).toBe(true);
      expect(shown("b")).toBe(true);
      expect(attr("#a-label", "y")).toBe(110);
      expect(attr("#b-label", "y") + LABEL_H).toBeLessThan(94);
      expect(overlaps(labelRect("a"), labelRect("b"))).toBe(false);
      expect(attr("#b-line", "x")).toBe(attr("#b-label", "x"));
      expect(attr("#b-box", "x")).toBe(attr("#b-label", "x") - 6);
    });

    it("keeps a label off every other point's marker", () => {
      mount([
        { id: "a", x: 100, y: 100 },
        { id: "blocker", x: 130, y: 118, label: false },
      ]);

      renderPx();

      const blocker = { x: 124, y: 112, width: 12, height: 12 };
      expect(shown("a")).toBe(true);
      expect(overlaps(labelRect("a"), blocker)).toBe(false);
    });

    it("hides a label with no free side and keeps the platform label", () => {
      mount([
        { id: "node", x: 200, y: 200 },
        { id: "right", x: 240, y: 200, label: false },
        { id: "left", x: 160, y: 200, label: false },
        { id: "above", x: 200, y: 183, label: false },
        { id: "below", x: 230, y: 217, label: false },
        { id: "platform", x: 400, y: 400, type: 0 },
      ]);

      renderPx();

      expect(shown("node")).toBe(false);
      expect(document.querySelector("#node-box").getAttribute("display")).toBe("none");
      expect(shown("platform")).toBe(true);
    });

    it("gives a platform its default spot before a node listed earlier", () => {
      mount([
        { id: "node", x: 100, y: 100 },
        { id: "platform", x: 104, y: 100, type: 0 },
      ]);

      renderPx();

      expect(attr("#platform-label", "x")).toBe(106);
      expect(attr("#platform-label", "y")).toBe(110);
      expect(overlaps(labelRect("node"), labelRect("platform"))).toBe(false);
    });

    it("gives the selected point its default spot before a platform listed earlier", () => {
      mount([
        { id: "platform", x: 100, y: 100, type: 0 },
        { id: "picked", x: 104, y: 100, selected: true },
      ]);

      renderPx();

      expect(attr("#picked-label", "x")).toBe(106);
      expect(attr("#picked-label", "y")).toBe(110);
      expect(overlaps(labelRect("picked"), labelRect("platform"))).toBe(false);
    });

    it("keeps every label hidden below the zoom threshold and shows them at it", () => {
      mount([
        { id: "a", x: 100, y: 100 },
        { id: "b", x: 300, y: 300 },
      ]);

      const { hook } = renderPx({ zoom: 0.8 });
      expect(shown("a")).toBe(false);
      expect(shown("b")).toBe(false);

      overlay().getScreenCTM = () => ({ a: 0.85 });
      hook.scale = 0.85;
      hook.scaleOverlayElements();
      expect(shown("a")).toBe(true);
      expect(shown("b")).toBe(true);
    });

    it("places labels identically on a second run", () => {
      mount([
        { id: "a", x: 100, y: 100 },
        { id: "b", x: 110, y: 100 },
        { id: "c", x: 120, y: 104, type: 2 },
        { id: "d", x: 105, y: 96, selected: true },
      ]);
      const snapshot = () =>
        ["a", "b", "c", "d"].map((id) => [
          shown(id),
          label(id).getAttribute("x"),
          label(id).getAttribute("y"),
          document.querySelector(`#${id}-box`).getAttribute("x"),
        ]);

      const { hook } = renderPx();
      const first = snapshot();
      hook.scaleOverlayElements();

      expect(snapshot()).toEqual(first);
    });
  });

  it("names a point in its tooltip when its label is hidden", () => {
    const hook = buildTooltipHook();
    const tooltip = document.querySelector("#diagram-edit-tooltip");
    const group = document.querySelector("#editable-stop");
    const hit = document.querySelector("#editable-stop-hit");
    const hover = () =>
      hit.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, clientX: 100, clientY: 120 }));

    group.setAttribute("data-label-text", "Stairs to Platform 1");
    group.insertAdjacentHTML("beforeend", `<text data-stop-label="true"></text>`);

    hover();
    expect(tooltip.textContent).toBe("Click to edit stop");

    group.querySelector("[data-stop-label]").setAttribute("display", "none");
    hit.dispatchEvent(new MouseEvent("mouseout", { bubbles: true, relatedTarget: document.body }));
    hover();
    expect(tooltip.textContent).toBe("Stairs to Platform 1\nClick to edit stop");

    hook.removeTooltipListeners();
  });

  it("shows and hides tooltip on hover for stop and pathway targets", () => {
    const hook = buildTooltipHook();
    const tooltip = document.querySelector("#diagram-edit-tooltip");
    const stopGroup = document.querySelector("#editable-stop");
    const stopHit = document.querySelector("#editable-stop-hit");
    const pathwayHit = document.querySelector("#editable-pathway-hit");

    stopGroup.dispatchEvent(
      new MouseEvent("mouseover", { bubbles: true, clientX: 100, clientY: 120 }),
    );
    expect(tooltip.getAttribute("aria-hidden")).toBe("true");

    stopHit.dispatchEvent(
      new MouseEvent("mouseover", { bubbles: true, clientX: 100, clientY: 120 }),
    );

    expect(tooltip.textContent).toBe("Click to edit stop");
    expect(tooltip.getAttribute("aria-hidden")).toBe("false");
    expect(tooltip.classList.contains("is-visible")).toBe(true);

    stopHit.dispatchEvent(
      new MouseEvent("mouseout", { bubbles: true, relatedTarget: document.body }),
    );

    expect(tooltip.getAttribute("aria-hidden")).toBe("true");
    expect(tooltip.classList.contains("is-hidden")).toBe(true);

    pathwayHit.dispatchEvent(
      new MouseEvent("mouseover", { bubbles: true, clientX: 160, clientY: 180 }),
    );

    expect(tooltip.textContent).toBe("Click to edit pathway");
    expect(tooltip.getAttribute("aria-hidden")).toBe("false");

    hook.removeTooltipListeners();
  });

  it("shows on focus, hides on blur, and repositions on view updates", () => {
    const hook = buildTooltipHook();
    const tooltip = document.querySelector("#diagram-edit-tooltip");
    const editableStop = document.querySelector("#editable-stop");
    const baseRect = { left: 40, top: 80, width: 20, height: 10, right: 60, bottom: 90 };

    editableStop.getBoundingClientRect = () => baseRect;

    editableStop.dispatchEvent(new Event("focusin", { bubbles: true }));

    expect(tooltip.getAttribute("aria-hidden")).toBe("false");
    const initialLeft = tooltip.style.left;
    const initialTop = tooltip.style.top;

    editableStop.getBoundingClientRect = () => ({
      left: 140,
      top: 160,
      width: 20,
      height: 10,
      right: 160,
      bottom: 170,
    });

    hook.updateViewBox();

    expect(tooltip.style.left).not.toBe(initialLeft);
    expect(tooltip.style.top).not.toBe(initialTop);

    editableStop.dispatchEvent(new Event("focusout", { bubbles: true }));
    expect(tooltip.getAttribute("aria-hidden")).toBe("true");

    hook.removeTooltipListeners();
  });
});

describe("DiagramCanvasHook pending center validation", () => {
  it("ignores invalid pending center coordinates", () => {
    const centerOnPoint = vi.fn();
    const hook = {
      ...DiagramCanvasHook,
      _pendingCenter: { x: Number.NaN, y: 20 },
      centerOnPoint,
    };

    hook.applyPendingCenter();

    expect(centerOnPoint).not.toHaveBeenCalled();
    expect(hook._pendingCenter).toBeNull();
  });

  it("accepts finite pending center coordinates", () => {
    const centerOnPoint = vi.fn();
    const hook = {
      ...DiagramCanvasHook,
      _pendingCenter: { x: 12.5, y: 42 },
      centerOnPoint,
    };

    hook.applyPendingCenter();

    expect(centerOnPoint).toHaveBeenCalledWith(12.5, 42);
    expect(hook._pendingCenter).toBeNull();
  });
});
