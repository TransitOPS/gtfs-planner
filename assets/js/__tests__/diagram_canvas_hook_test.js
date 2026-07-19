/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import DiagramCanvasHook from "../diagram_canvas_hook.js";

const SVG_NS = "http://www.w3.org/2000/svg";

function elSVG(tag, attrs = {}) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v != null) el.setAttribute(k, String(v));
  }
  // SVG elements in jsdom lack a native click(); provide one for spying
  if (!el.click) {
    el.click = () => el.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  }
  return el;
}

function makeCanvas() {
  const container = document.createElement("div");

  const svg = elSVG("svg", { "data-canvas-key": "test-canvas" });
  container.appendChild(svg);

  const overlay = elSVG("svg", { id: "diagram-overlay", "data-mode": "view" });
  container.appendChild(overlay);

  document.body.appendChild(container);

  return { container, svg, overlay };
}

function makeStopGroup(overlay, { id = "stop-g-1", stopId = "STOP_1", tabindex = "0" } = {}) {
  const group = elSVG("g", {
    id,
    "data-stop-id": stopId,
    "data-stop-center-x": "50",
    "data-stop-center-y": "50",
    "data-editable": "stop",
    tabindex
  });

  const hitTarget = elSVG("rect", {
    "data-stop-hit-target": "true",
    "data-center-x": "50",
    "data-center-y": "50",
    "data-tooltip-trigger": "true",
    "data-location-type": "0",
    "phx-click": "stop_clicked",
    "phx-value-id": stopId
  });
  group.appendChild(hitTarget);

  overlay.appendChild(group);
  return { group, hitTarget };
}

function makePathwayGroup(overlay, { id = "pw-g-1", pathwayId = 1, tabindex = "0" } = {}) {
  const group = elSVG("g", {
    id,
    "data-from-stop-id": "S1",
    "data-to-stop-id": "S2",
    "data-editable": "pathway",
    tabindex,
    "phx-click": "edit_pathway",
    "phx-value-id": String(pathwayId)
  });
  overlay.appendChild(group);
  return group;
}

function makeBadgeGroup(overlay, { id = "badge-g-1", pathwayId = 1, tabindex = "0" } = {}) {
  const group = elSVG("g", {
    id,
    "data-cross-level-pathway-badge": "true",
    "data-pathway-id": String(pathwayId),
    tabindex,
    "phx-click": "edit_pathway",
    "phx-value-id": String(pathwayId)
  });
  overlay.appendChild(group);
  return group;
}

function makeHook(svg) {
  const hook = Object.create(DiagramCanvasHook);
  hook.el = svg;
  hook.pushEvent = vi.fn();
  hook.handleEvent = vi.fn();
  return hook;
}

function dispatchDocumentKeydown(key, { shiftKey = false } = {}) {
  const event = new KeyboardEvent("keydown", {
    key,
    code: key === " " ? "Space" : key,
    bubbles: true,
    cancelable: true,
    shiftKey
  });
  document.dispatchEvent(event);
  return event;
}

describe("DiagramCanvasHook — group activation", () => {
  let _container;
  let svg;
  let overlay;

  beforeEach(() => {
    document.body.innerHTML = "";
    const canvas = makeCanvas();
    _container = canvas.container;
    svg = canvas.svg;
    overlay = canvas.overlay;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("edit intent activation via Enter/Space", () => {
    it("clicks the stop hit-target rect when Enter is pressed on a focused stop group", () => {
      const { group, hitTarget } = makeStopGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      const clickSpy = vi.spyOn(hitTarget, "click");
      group.focus();
      dispatchDocumentKeydown("Enter");

      expect(clickSpy).toHaveBeenCalledTimes(1);
    });

    it("clicks the stop hit-target rect when Space is pressed on a focused stop group", () => {
      const { group, hitTarget } = makeStopGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      const clickSpy = vi.spyOn(hitTarget, "click");
      group.focus();
      const event = dispatchDocumentKeydown(" ");

      expect(clickSpy).toHaveBeenCalledTimes(1);
      expect(event.defaultPrevented).toBe(true);
    });

    it("clicks the pathway group when Enter is pressed on a focused pathway group", () => {
      const group = makePathwayGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      const clickSpy = vi.spyOn(group, "click");
      group.focus();
      dispatchDocumentKeydown("Enter");

      expect(clickSpy).toHaveBeenCalledTimes(1);
    });

    it("clicks the pathway group when Space is pressed on a focused pathway group", () => {
      const group = makePathwayGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      const clickSpy = vi.spyOn(group, "click");
      group.focus();
      const event = dispatchDocumentKeydown(" ");

      expect(clickSpy).toHaveBeenCalledTimes(1);
      expect(event.defaultPrevented).toBe(true);
    });

    it("clicks the badge group when Enter is pressed on a focused badge group", () => {
      const group = makeBadgeGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      const clickSpy = vi.spyOn(group, "click");
      group.focus();
      dispatchDocumentKeydown("Enter");

      expect(clickSpy).toHaveBeenCalledTimes(1);
    });

    it("clicks the badge group when Space is pressed on a focused badge group", () => {
      const group = makeBadgeGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      const clickSpy = vi.spyOn(group, "click");
      group.focus();
      const event = dispatchDocumentKeydown(" ");

      expect(clickSpy).toHaveBeenCalledTimes(1);
      expect(event.defaultPrevented).toBe(true);
    });
  });

  describe("activation guards", () => {
    it("does not activate when the focused element lacks tabindex", () => {
      const { group, hitTarget } = makeStopGroup(overlay, { tabindex: null });
      const hook = makeHook(svg);
      hook.mounted();

      const groupClickSpy = vi.spyOn(group, "click");
      const hitClickSpy = vi.spyOn(hitTarget, "click");
      group.focus();
      dispatchDocumentKeydown("Enter");

      expect(groupClickSpy).not.toHaveBeenCalled();
      expect(hitClickSpy).not.toHaveBeenCalled();
    });

    it("does not activate when the overlay data-mode is not view", () => {
      overlay.setAttribute("data-mode", "add");
      const { group, hitTarget } = makeStopGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      const hitClickSpy = vi.spyOn(hitTarget, "click");
      group.focus();
      dispatchDocumentKeydown("Enter");

      expect(hitClickSpy).not.toHaveBeenCalled();
    });

    it("does not activate when the focused element is outside the overlay", () => {
      const { group } = makeStopGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      const outsideBtn = document.createElement("button");
      document.body.appendChild(outsideBtn);
      outsideBtn.focus();

      const groupClickSpy = vi.spyOn(group, "click");
      dispatchDocumentKeydown("Enter");

      expect(groupClickSpy).not.toHaveBeenCalled();
    });

    it("does not activate for non-Enter/non-Space keys", () => {
      const group = makePathwayGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      const clickSpy = vi.spyOn(group, "click");
      group.focus();
      dispatchDocumentKeydown("Escape");
      dispatchDocumentKeydown("Tab");
      dispatchDocumentKeydown("ArrowDown");

      expect(clickSpy).not.toHaveBeenCalled();
    });

    it("still handles Escape to cancel drag (existing behavior preserved)", () => {
      const { group } = makeStopGroup(overlay);
      const hook = makeHook(svg);
      hook.mounted();

      // Simulate a mid-drag state
      hook.dragging = {
        stopId: "STOP_1",
        groupEl: group,
        centerX: 50,
        centerY: 50,
        startSvgX: 50,
        startSvgY: 50,
        currentX: 60,
        currentY: 60,
        pathwayElements: []
      };

      const pushEventSpy = vi.spyOn(hook, "pushEvent");
      dispatchDocumentKeydown("Escape");

      expect(hook.dragging).toBeNull();
      expect(pushEventSpy).toHaveBeenCalledWith("drag_cancel", {});
      // The group should not activate via Enter path when Escape is pressed
    });
  });
});
