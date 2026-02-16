/* @vitest-environment jsdom */
import { beforeEach, describe, expect, it } from "vitest";
import DiagramCanvasHook from "../diagram_canvas_hook";

describe("DiagramCanvasHook.scaleOverlayElements", () => {
  beforeEach(() => {
    document.body.innerHTML = `
      <div id="container">
        <svg id="diagram-overlay">
          <defs>
            <marker id="pathway-arrow" markerWidth="1.5" markerHeight="1.5"></marker>
          </defs>
          <g id="stops-svg">
            <rect
              id="stop-hit"
              data-stop-hit-target="true"
              data-center-x="10"
              data-center-y="20"
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
            <text
              id="stop-label"
              data-stop-label="true"
              data-center-x="10"
              data-center-y="20"
              data-label-offset-x="1"
            ></text>
            <path
              id="cross-level-stairs"
              data-cross-level-badge-stairs="true"
              data-center-x="10"
              data-center-y="20"
              data-badge-offset-x="1.1"
            ></path>
            <path
              id="cross-level-elevator"
              data-cross-level-badge-elevator="true"
              data-center-x="10"
              data-center-y="20"
              data-badge-offset-x="1.1"
            ></path>
          </g>
          <g id="pathways-svg">
            <line id="path-hit" data-pathway-hit="true" data-base-stroke="2"></line>
            <line id="path-line" data-pathway-line="true" data-base-stroke="0.5"></line>
            <line
              id="path-dashed"
              data-pathway-line="true"
              data-base-stroke="0.5"
              data-base-dash="2,1"
            ></line>
            <rect
              id="elevator-box"
              data-pathway-elevator-box="true"
              data-center-x="30"
              data-center-y="40"
              data-base-width="2"
              data-base-height="2"
              data-base-stroke="0.4"
            ></rect>
            <text
              id="elevator-text"
              data-pathway-elevator-text="true"
              data-center-x="30"
              data-center-y="40"
              data-base-font-size="1.2"
            ></text>
            <text
              id="path-label"
              data-pathway-label="true"
              data-midpoint-x="50"
              data-midpoint-y="60"
              data-offset-x="1.4"
              data-offset-y="-1.4"
              data-base-font-size="0.9"
              data-base-stroke="0.2"
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

  it("scales stop and pathway overlay elements from base data attributes", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas")
    };

    hook.scale = 2;
    hook.scaleOverlayElements();

    expect(document.querySelector("#stop-hit").getAttribute("width")).toBe("1.75");
    expect(document.querySelector("#stop-hit").getAttribute("height")).toBe("1.75");
    expect(document.querySelector("#stop-marker").getAttribute("r")).toBe("0.3");
    expect(document.querySelector("#stop-platform").getAttribute("width")).toBe("0.5");
    expect(document.querySelector("#stop-platform").getAttribute("height")).toBe("1");
    expect(document.querySelector("#stop-entrance").getAttribute("width")).toBe("0.5");
    expect(document.querySelector("#stop-entrance").getAttribute("height")).toBe("1");
    expect(document.querySelector("#stop-boarding-area").getAttribute("x")).toBe("19.7");
    expect(document.querySelector("#stop-boarding-area").getAttribute("y")).toBe("29.7");
    expect(document.querySelector("#stop-boarding-area").getAttribute("width")).toBe("0.6");
    expect(document.querySelector("#stop-boarding-area").getAttribute("height")).toBe("0.6");
    expect(document.querySelector("#stop-label").getAttribute("x")).toBe("10.5");
    expect(document.querySelector("#stop-label").getAttribute("font-size")).toBe("0.55");
    expect(document.querySelector("#cross-level-stairs").getAttribute("d")).toBe(
      "M 10.325000000000001 20.224999999999998 L 10.325000000000001 20.075 L 10.475000000000001 20.075 L 10.475000000000001 19.924999999999997 L 10.625 19.924999999999997 L 10.625 19.775 L 10.775 19.775 L 10.775 20.224999999999998 Z"
    );
    expect(document.querySelector("#cross-level-elevator").getAttribute("d")).toBe(
      "M 10.55 19.775 L 10.725000000000001 19.975 L 10.375 19.975 Z M 10.55 20.225 L 10.725000000000001 20.025 L 10.375 20.025 Z"
    );

    expect(document.querySelector("#path-hit").getAttribute("stroke-width")).toBe("1");
    expect(document.querySelector("#path-line").getAttribute("stroke-width")).toBe("0.17857142857142858");
    expect(document.querySelector("#path-dashed").getAttribute("stroke-width")).toBe("0.17857142857142858");
    expect(document.querySelector("#path-dashed").getAttribute("stroke-dasharray")).toBe(
      "0.7142857142857143 0.35714285714285715"
    );

    expect(document.querySelector("#pathway-arrow").getAttribute("markerWidth")).toBe(
      "0.5357142857142857"
    );
    expect(document.querySelector("#pathway-arrow").getAttribute("markerHeight")).toBe(
      "0.5357142857142857"
    );

    expect(document.querySelector("#elevator-box").getAttribute("x")).toBe("29.5");
    expect(document.querySelector("#elevator-box").getAttribute("y")).toBe("39.5");
    expect(document.querySelector("#elevator-box").getAttribute("width")).toBe("1");
    expect(document.querySelector("#elevator-box").getAttribute("height")).toBe("1");
    expect(document.querySelector("#elevator-box").getAttribute("stroke-width")).toBe(
      "0.14285714285714288"
    );

    expect(document.querySelector("#elevator-text").getAttribute("font-size")).toBe("0.6");
    expect(document.querySelector("#path-label").getAttribute("x")).toBe("50.7");
    expect(document.querySelector("#path-label").getAttribute("y")).toBe("59.3");
    expect(document.querySelector("#path-label").getAttribute("font-size")).toBe("0.45");
    expect(document.querySelector("#path-label").getAttribute("stroke-width")).toBe(
      "0.07142857142857144"
    );

    expect(document.querySelector("#pending").getAttribute("stroke-width")).toBe("0.075");
    expect(document.querySelector("#pending").getAttribute("points")).toBe("10,19.5 9.625,20.25 10.375,20.25");
  });

  it("keeps pathway visuals less chunky when zoomed out while preserving hit targets", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas")
    };

    hook.scale = 0.5;
    hook.scaleOverlayElements();

    const hitStroke = parseFloat(document.querySelector("#path-hit").getAttribute("stroke-width"));
    const lineStroke = parseFloat(document.querySelector("#path-line").getAttribute("stroke-width"));
    const markerWidth = parseFloat(document.querySelector("#pathway-arrow").getAttribute("markerWidth"));
    const dashed = document
      .querySelector("#path-dashed")
      .getAttribute("stroke-dasharray")
      .split(" ")
      .map((value) => parseFloat(value));

    expect(hitStroke).toBeCloseTo(4, 5);
    expect(lineStroke).toBeCloseTo(0.4201680672, 5);
    expect(markerWidth).toBeCloseTo(1.2605042017, 5);
    expect(dashed[0]).toBeCloseTo(1.6806722689, 5);
    expect(dashed[1]).toBeCloseTo(0.8403361344, 5);

    const iconRadius = parseFloat(document.querySelector("#stop-marker").getAttribute("r"));
    const platformHeight = parseFloat(document.querySelector("#stop-platform").getAttribute("height"));
    const entranceHeight = parseFloat(document.querySelector("#stop-entrance").getAttribute("height"));
    const boardingWidth = parseFloat(
      document.querySelector("#stop-boarding-area").getAttribute("width")
    );

    // Icon visuals should scale down slightly when zoomed out to avoid chunky markers.
    expect(iconRadius).toBeCloseTo(0.5882352941, 5);
    expect(platformHeight).toBeCloseTo(2.380952381, 5);
    expect(entranceHeight).toBeCloseTo(2.380952381, 5);
    expect(boardingWidth).toBeCloseTo(1.1764705882, 5);
  });
});
