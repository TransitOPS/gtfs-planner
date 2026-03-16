/* @vitest-environment jsdom */
import { beforeEach, describe, expect, it, vi } from "vitest";
import DiagramCanvasHook from "../diagram_canvas_hook";

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
              data-label-offset-x="-0.5"
              data-label-offset-y="1"
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
            <line id="path-hit" data-pathway-hit="true" data-base-stroke="2"></line>
            <line id="path-line" data-pathway-line="true" data-base-stroke="0.5"></line>
            <line
              id="path-line-paired"
              data-pathway-line="true"
              data-base-stroke="0.54"
            ></line>
            <line
              id="path-dashed"
              data-pathway-line="true"
              data-base-stroke="0.5"
              data-base-dash="2,1"
            ></line>
            <line
              id="path-arrow-trim"
              x1="10"
              y1="10"
              x2="20"
              y2="10"
              marker-end="url(#pathway-arrow)"
              data-pathway-end-trim="0.9"
              data-base-stroke="0.3"
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
              data-rotation="15"
              data-base-font-size="0.9"
              data-base-stroke="0.2"
            ></text>
          </g>
          <g id="ruler-layer">
            <line
              id="ruler-line"
              data-ruler-line="true"
              data-base-stroke="0.25"
              data-base-dash="0.8,0.5"
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
              data-base-radius="0.35"
              data-base-stroke="0.13"
            ></circle>
            <text
              id="ruler-label"
              data-ruler-label="true"
              data-midpoint-x="15"
              data-midpoint-y="15"
              data-label-offset-y="-0.9"
              data-base-font-size="0.72"
              data-base-stroke="0.16"
            ></text>
            <text
              id="ruler-label-saved"
              data-ruler-label="true"
              data-label-anchor-x="10"
              data-label-anchor-y="10"
              data-label-offset-x="0.5"
              data-label-offset-y="0"
              data-base-font-size="0.72"
              data-base-stroke="0.16"
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

  it("scales stop and pathway overlay elements from base data attributes", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
    };

    hook.scale = 2;
    hook.scaleOverlayElements();

    expect(document.querySelector("#stop-hit").getAttribute("width")).toBe(
      "1.75",
    );
    expect(document.querySelector("#stop-hit").getAttribute("height")).toBe(
      "1.75",
    );
    expect(document.querySelector("#stop-marker").getAttribute("r")).toBe(
      "0.3",
    );
    expect(document.querySelector("#stop-platform").getAttribute("width")).toBe(
      "0.5",
    );
    expect(
      document.querySelector("#stop-platform").getAttribute("height"),
    ).toBe("1");
    expect(document.querySelector("#stop-platform").getAttribute("y")).toBe(
      "23.2",
    );
    expect(document.querySelector("#stop-entrance").getAttribute("width")).toBe(
      "0.5",
    );
    expect(
      document.querySelector("#stop-entrance").getAttribute("height"),
    ).toBe("1");
    expect(document.querySelector("#stop-entrance").getAttribute("y")).toBe(
      "25.2",
    );
    expect(
      document.querySelector("#stop-boarding-area").getAttribute("x"),
    ).toBe("19.7");
    expect(
      document.querySelector("#stop-boarding-area").getAttribute("y"),
    ).toBe("29.52");
    expect(
      document.querySelector("#stop-boarding-area").getAttribute("width"),
    ).toBe("0.6");
    expect(
      document.querySelector("#stop-boarding-area").getAttribute("height"),
    ).toBe("0.6");
    expect(document.querySelector("#stop-label").getAttribute("x")).toBe(
      "9.75",
    );
    expect(document.querySelector("#stop-label").getAttribute("y")).toBe(
      "20.5",
    );
    expect(
      document.querySelector("#stop-label").getAttribute("font-size"),
    ).toBe("0.36");
    expect(
      document.querySelector("#cross-level-stairs").getAttribute("d"),
    ).toBe(
      "M 10.325000000000001 20.224999999999998 L 10.325000000000001 20.075 L 10.475000000000001 20.075 L 10.475000000000001 19.924999999999997 L 10.625 19.924999999999997 L 10.625 19.775 L 10.775 19.775 L 10.775 20.224999999999998 Z",
    );
    expect(
      document.querySelector("#cross-level-elevator").getAttribute("d"),
    ).toBe(
      "M 10.55 19.775 L 10.725000000000001 19.975 L 10.375 19.975 Z M 10.55 20.225 L 10.725000000000001 20.025 L 10.375 20.025 Z",
    );

    expect(
      document.querySelector("#path-hit").getAttribute("stroke-width"),
    ).toBe("1");
    expect(
      document.querySelector("#path-line").getAttribute("stroke-width"),
    ).toBe("0.1388888888888889");
    expect(
      document.querySelector("#path-line-paired").getAttribute("stroke-width"),
    ).toBe("0.15");
    expect(
      document.querySelector("#path-dashed").getAttribute("stroke-width"),
    ).toBe("0.1388888888888889");
    expect(
      document.querySelector("#path-dashed").getAttribute("stroke-dasharray"),
    ).toBe("0.5555555555555556 0.2777777777777778");
    expect(
      parseFloat(document.querySelector("#path-arrow-trim").getAttribute("x1")),
    ).toBeCloseTo(10.25, 5);
    expect(
      parseFloat(document.querySelector("#path-arrow-trim").getAttribute("x2")),
    ).toBeCloseTo(19.75, 5);

    expect(
      document.querySelector("#pathway-arrow").getAttribute("markerWidth"),
    ).toBe("0.41666666666666663");
    expect(
      document.querySelector("#pathway-arrow").getAttribute("markerHeight"),
    ).toBe("0.41666666666666663");

    expect(document.querySelector("#elevator-box").getAttribute("x")).toBe(
      "29.5",
    );
    expect(document.querySelector("#elevator-box").getAttribute("y")).toBe(
      "39.5",
    );
    expect(document.querySelector("#elevator-box").getAttribute("width")).toBe(
      "1",
    );
    expect(document.querySelector("#elevator-box").getAttribute("height")).toBe(
      "1",
    );
    expect(
      document.querySelector("#elevator-box").getAttribute("stroke-width"),
    ).toBe("0.11111111111111112");

    expect(
      document.querySelector("#elevator-text").getAttribute("font-size"),
    ).toBe("0.6");
    expect(document.querySelector("#path-label").getAttribute("x")).toBe(
      "50.7",
    );
    expect(document.querySelector("#path-label").getAttribute("y")).toBe(
      "59.3",
    );
    expect(
      document.querySelector("#path-label").getAttribute("font-size"),
    ).toBe("0.45");
    expect(
      document.querySelector("#path-label").getAttribute("stroke-width"),
    ).toBe("0.05555555555555556");
    expect(document.querySelector("#path-label").getAttribute("transform")).toBe(
      "rotate(15, 50.7, 59.3)",
    );

    expect(document.querySelector("#ruler-line").getAttribute("stroke-width")).toBe(
      "0.125",
    );
    expect(document.querySelector("#ruler-line").getAttribute("stroke-dasharray")).toBe(
      "0.4 0.25",
    );
    expect(document.querySelector("#ruler-endpoint-a").getAttribute("r")).toBe(
      "0.14583333333333334",
    );
    expect(
      document.querySelector("#ruler-endpoint-a").getAttribute("stroke-width"),
    ).toBe("0.05416666666666667");
    expect(document.querySelector("#ruler-label").getAttribute("x")).toBe("15");
    expect(document.querySelector("#ruler-label").getAttribute("y")).toBe("14.55");
    expect(document.querySelector("#ruler-label").getAttribute("font-size")).toBe(
      "0.36",
    );
    expect(
      document.querySelector("#ruler-label").getAttribute("stroke-width"),
    ).toBe("0.08");
    expect(document.querySelector("#ruler-label-saved").getAttribute("x")).toBe(
      "10.25",
    );
    expect(document.querySelector("#ruler-label-saved").getAttribute("y")).toBe(
      "10",
    );

    expect(
      document.querySelector("#pending").getAttribute("stroke-width"),
    ).toBe("0.075");
    expect(document.querySelector("#pending").getAttribute("points")).toBe(
      "10,19.5 9.625,20.25 10.375,20.25",
    );
  });

  it("keeps pathway visuals less chunky when zoomed out while preserving hit targets", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
    };

    hook.scale = 0.5;
    hook.scaleOverlayElements();

    const hitStroke = parseFloat(
      document.querySelector("#path-hit").getAttribute("stroke-width"),
    );
    const lineStroke = parseFloat(
      document.querySelector("#path-line").getAttribute("stroke-width"),
    );
    const markerWidth = parseFloat(
      document.querySelector("#pathway-arrow").getAttribute("markerWidth"),
    );
    const dashed = document
      .querySelector("#path-dashed")
      .getAttribute("stroke-dasharray")
      .split(" ")
      .map((value) => parseFloat(value));

    expect(hitStroke).toBeCloseTo(4, 5);
    expect(lineStroke).toBeCloseTo(0.5555555556, 5);
    expect(markerWidth).toBeCloseTo(1.6666666667, 5);
    expect(dashed[0]).toBeCloseTo(2.2222222222, 5);
    expect(dashed[1]).toBeCloseTo(1.1111111111, 5);

    const iconRadius = parseFloat(
      document.querySelector("#stop-marker").getAttribute("r"),
    );
    const platformHeight = parseFloat(
      document.querySelector("#stop-platform").getAttribute("height"),
    );
    const entranceHeight = parseFloat(
      document.querySelector("#stop-entrance").getAttribute("height"),
    );
    const boardingWidth = parseFloat(
      document.querySelector("#stop-boarding-area").getAttribute("width"),
    );

    // Icon visuals should scale down slightly when zoomed out to avoid chunky markers.
    expect(iconRadius).toBeCloseTo(0.5882352941, 5);
    expect(platformHeight).toBeCloseTo(1.9607843137, 5);
    expect(entranceHeight).toBeCloseTo(1.9607843137, 5);
    expect(boardingWidth).toBeCloseTo(1.1764705882, 5);
    expect(document.querySelector("#stop-label").getAttribute("display")).toBe(
      "none",
    );
    expect(document.querySelector("#path-label").getAttribute("display")).toBe(
      "none",
    );
    expect(
      document.querySelector("#ruler-endpoint-a").getAttribute("r"),
    ).toBe("0.25");
    expect(
      document.querySelector("#ruler-endpoint-a").getAttribute("stroke-width"),
    ).toBe("0.09285714285714286");
  });

  it("keeps ruler elements anchored while scaling with zoom", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
    };

    hook.scale = 1;
    hook.scaleOverlayElements();
    const initialY = document.querySelector("#ruler-label").getAttribute("y");

    hook.scale = 3;
    hook.scaleOverlayElements();

    expect(document.querySelector("#ruler-endpoint-a").getAttribute("cx")).toBe("10");
    expect(document.querySelector("#ruler-endpoint-a").getAttribute("cy")).toBe("10");
    expect(document.querySelector("#ruler-label").getAttribute("x")).toBe("15");
    expect(document.querySelector("#ruler-label").getAttribute("y")).not.toBe(initialY);
  });

  it("skips pathway label transform updates when rotation is non-numeric", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
    };

    const pathLabel = document.querySelector("#path-label");
    pathLabel.setAttribute("data-rotation", "invalid");
    pathLabel.setAttribute("transform", "rotate(45, 1, 1)");

    hook.scale = 2;
    hook.scaleOverlayElements();

    expect(pathLabel.getAttribute("transform")).toBe("rotate(45, 1, 1)");
  });

  it("hides pathway labels at baseline scale and restores above threshold", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
    };

    const pathLabel = document.querySelector("#path-label");

    hook.scale = 1;
    hook.scaleOverlayElements();
    expect(pathLabel.getAttribute("display")).toBe("none");

    hook.scale = 1.2;
    hook.scaleOverlayElements();
    expect(pathLabel.getAttribute("display")).toBe(null);

    expect(parseFloat(pathLabel.getAttribute("x"))).toBeCloseTo(51.1666666667, 5);
    expect(parseFloat(pathLabel.getAttribute("y"))).toBeCloseTo(58.8333333333, 5);
    expect(parseFloat(pathLabel.getAttribute("font-size"))).toBeCloseTo(0.75, 5);
    expect(parseFloat(pathLabel.getAttribute("stroke-width"))).toBeCloseTo(
      0.119047619,
      5,
    );
  });

  it("hides ruler labels when zoomed out below threshold and restores above threshold", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
    };

    hook.scale = 0.8;
    hook.scaleOverlayElements();
    expect(document.querySelector("#ruler-label").getAttribute("display")).toBe(
      "none",
    );
    expect(
      document.querySelector("#ruler-label-saved").getAttribute("display"),
    ).toBe("none");

    hook.scale = 1;
    hook.scaleOverlayElements();
    expect(document.querySelector("#ruler-label").getAttribute("display")).toBe(
      null,
    );
    expect(
      document.querySelector("#ruler-label-saved").getAttribute("display"),
    ).toBe("none");

    hook.scale = 2;
    hook.scaleOverlayElements();
    expect(
      document.querySelector("#ruler-label-saved").getAttribute("display"),
    ).toBe(null);
  });

  it("hides ruler endpoints at or near 1x zoom and shows them outside that range", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
    };

    hook.scale = 1;
    hook.scaleOverlayElements();
    expect(
      document.querySelector("#ruler-endpoint-a").getAttribute("display"),
    ).toBe("none");

    hook.scale = 1.05;
    hook.scaleOverlayElements();
    expect(
      document.querySelector("#ruler-endpoint-a").getAttribute("display"),
    ).toBe("none");

    hook.scale = 0.8;
    hook.scaleOverlayElements();
    expect(
      document.querySelector("#ruler-endpoint-a").getAttribute("display"),
    ).toBe(null);

    hook.scale = 2;
    hook.scaleOverlayElements();
    expect(
      document.querySelector("#ruler-endpoint-a").getAttribute("display"),
    ).toBe(null);
  });

  it("slims ruler endpoints in mid-level zoom", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas"),
    };

    hook.scale = 0.8;
    hook.scaleOverlayElements();

    expect(document.querySelector("#ruler-endpoint-a").getAttribute("r")).toBe(
      "0.2734375",
    );
    expect(
      document.querySelector("#ruler-endpoint-a").getAttribute("stroke-width"),
    ).toBe("0.1015625");
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
