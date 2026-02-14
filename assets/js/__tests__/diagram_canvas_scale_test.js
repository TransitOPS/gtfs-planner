import { beforeEach, describe, expect, it } from "vitest";
import DiagramCanvasHook from "../diagram_canvas_hook";

describe("DiagramCanvasHook.scaleOverlayElements", () => {
  beforeEach(() => {
    document.body.innerHTML = `
      <div id="container">
        <svg id="diagram-overlay">
          <g id="stops-svg">
            <circle id="stop-hit" data-stop-hit-target="true" stroke-width="0"></circle>
            <circle id="stop-normal" data-stop-marker="true" stroke-width="0.15"></circle>
            <circle id="stop-cross" data-stop-marker="true" data-cross-level="true" stroke-width="0.25"></circle>
          </g>
          <g id="pathways-svg">
            <g>
              <line id="path-hit" stroke-width="2"></line>
              <line id="path-visible" stroke-width="0.5"></line>
            </g>
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

  it("keeps overlay geometry visually constant across zoom levels", () => {
    const hook = {
      ...DiagramCanvasHook,
      el: document.querySelector("#canvas")
    };

    const normalCircle = document.querySelector("#stop-normal");
    const crossCircle = document.querySelector("#stop-cross");
    const hitCircle = document.querySelector("#stop-hit");
    const hitLine = document.querySelector("#path-hit");
    const visibleLine = document.querySelector("#path-visible");
    const pending = document.querySelector("#pending");

    [1, 2, 5].forEach((scale) => {
      hook.scale = scale;
      hook.scaleOverlayElements();

      expect(normalCircle.getAttribute("r")).toBe(`${0.75 / scale}`);
      expect(normalCircle.getAttribute("stroke-width")).toBe(`${0.15 / scale}`);
      expect(crossCircle.getAttribute("stroke-width")).toBe(`${0.25 / scale}`);
      expect(hitCircle.getAttribute("r")).toBe(`${2.5 / scale}`);
      expect(hitCircle.getAttribute("stroke-width")).toBe("0");
      expect(hitLine.getAttribute("stroke-width")).toBe(`${2 / scale}`);
      expect(visibleLine.getAttribute("stroke-width")).toBe(`${0.5 / scale}`);
      expect(pending.getAttribute("stroke-width")).toBe(`${0.15 / scale}`);

      const offY = 1 / scale;
      const offX = 0.75 / scale;
      const bottomOffsetY = 0.5 / scale;
      expect(pending.getAttribute("points")).toBe(
        `10,${20 - offY} ${10 - offX},${20 + bottomOffsetY} ${10 + offX},${20 + bottomOffsetY}`
      );
    });
  });
});
