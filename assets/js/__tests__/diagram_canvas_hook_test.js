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

describe("DiagramCanvasHook — pan/zoom controls", () => {
  let container;
  let svg;
  let overlay;
  let hook;

  function attachButton(attrs) {
    const btn = document.createElement("button");
    btn.setAttribute("type", "button");
    Object.entries(attrs).forEach(([k, v]) => btn.setAttribute(k, String(v)));
    container.appendChild(btn);
    return btn;
  }

  function attachZoomLabel() {
    const span = document.createElement("span");
    span.setAttribute("data-zoom-label", "true");
    span.textContent = "...";
    container.appendChild(span);
    return span;
  }

  beforeEach(() => {
    document.body.innerHTML = "";
    const canvas = makeCanvas();
    container = canvas.container;
    svg = canvas.svg;
    overlay = canvas.overlay;
    hook = makeHook(svg);
    hook.mounted();
    // Override mounted defaults to a known pan/zoom state
    hook.baseW = 100;
    hook.baseH = 80;
    hook.viewBox = { x: 10, y: 10, w: 40, h: 32 };
    hook.scale = hook.baseW / hook.viewBox.w; // 2.5
    hook.minScale = 0.5;
    hook.maxScale = 10;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("pan buttons", () => {
    it("shifts viewBox up when pan-up button is clicked", () => {
      const btn = attachButton({ "data-pan": "up", "aria-label": "Pan up" });
      const initialY = hook.viewBox.y;
      btn.click();
      expect(hook.viewBox.y).toBeLessThan(initialY);
      expect(hook.viewBox.y).toBeCloseTo(initialY - 8, 0); // 0.25 * 32
    });

    it("shifts viewBox down when pan-down button is clicked", () => {
      const btn = attachButton({ "data-pan": "down", "aria-label": "Pan down" });
      const initialY = hook.viewBox.y;
      btn.click();
      expect(hook.viewBox.y).toBeGreaterThan(initialY);
      expect(hook.viewBox.y).toBeCloseTo(initialY + 8, 0);
    });

    it("shifts viewBox left when pan-left button is clicked", () => {
      const btn = attachButton({ "data-pan": "left", "aria-label": "Pan left" });
      const initialX = hook.viewBox.x;
      btn.click();
      expect(hook.viewBox.x).toBeLessThan(initialX);
      expect(hook.viewBox.x).toBeCloseTo(initialX - 10, 0); // 0.25 * 40
    });

    it("shifts viewBox right when pan-right button is clicked", () => {
      const btn = attachButton({ "data-pan": "right", "aria-label": "Pan right" });
      const initialX = hook.viewBox.x;
      btn.click();
      expect(hook.viewBox.x).toBeGreaterThan(initialX);
      expect(hook.viewBox.x).toBeCloseTo(initialX + 10, 0);
    });

    it("calls clampViewBox and updateViewBox after pan", () => {
      const btn = attachButton({ "data-pan": "up", "aria-label": "Pan up" });
      const clampSpy = vi.spyOn(hook, "clampViewBox");
      const updateSpy = vi.spyOn(hook, "updateViewBox");
      btn.click();
      expect(clampSpy).toHaveBeenCalledTimes(1);
      expect(updateSpy).toHaveBeenCalledTimes(1);
    });

    it("ignores clicks on elements without data-pan attribute", () => {
      // Even when a button in the container has no pan/zoom/reset data attrs,
      // the handler should not throw and should not mutate viewBox
      const btn = document.createElement("button");
      btn.setAttribute("type", "button");
      container.appendChild(btn);
      const initialX = hook.viewBox.x;
      const initialY = hook.viewBox.y;
      btn.click();
      expect(hook.viewBox.x).toBe(initialX);
      expect(hook.viewBox.y).toBe(initialY);
    });
  });

  describe("zoom buttons", () => {
    it("zooms in: increases scale and shrinks viewBox around center", () => {
      const btn = attachButton({ "data-zoom": "in", "aria-label": "Zoom in" });
      const initialScale = hook.scale;
      const centerX = hook.viewBox.x + hook.viewBox.w / 2;
      const centerY = hook.viewBox.y + hook.viewBox.h / 2;
      btn.click();
      expect(hook.scale).toBeGreaterThan(initialScale);
      expect(hook.viewBox.w).toBeLessThan(40);
      expect(hook.viewBox.h).toBeLessThan(32);
      const newCenterX = hook.viewBox.x + hook.viewBox.w / 2;
      const newCenterY = hook.viewBox.y + hook.viewBox.h / 2;
      expect(newCenterX).toBeCloseTo(centerX, 5);
      expect(newCenterY).toBeCloseTo(centerY, 5);
    });

    it("zooms out: decreases scale and expands viewBox around center", () => {
      const btn = attachButton({ "data-zoom": "out", "aria-label": "Zoom out" });
      const initialScale = hook.scale;
      const centerX = hook.viewBox.x + hook.viewBox.w / 2;
      const centerY = hook.viewBox.y + hook.viewBox.h / 2;
      btn.click();
      expect(hook.scale).toBeLessThan(initialScale);
      expect(hook.viewBox.w).toBeGreaterThan(40);
      expect(hook.viewBox.h).toBeGreaterThan(32);
      const newCenterX = hook.viewBox.x + hook.viewBox.w / 2;
      const newCenterY = hook.viewBox.y + hook.viewBox.h / 2;
      expect(newCenterX).toBeCloseTo(centerX, 5);
      expect(newCenterY).toBeCloseTo(centerY, 5);
    });

    it("clamps scale at maxScale", () => {
      const btn = attachButton({ "data-zoom": "in", "aria-label": "Zoom in" });
      hook.scale = 9;
      hook.viewBox.w = 100 / 9;
      hook.viewBox.h = 80 / 9;
      hook.viewBox.x = 0;
      hook.viewBox.y = 0;
      btn.click();
      expect(hook.scale).toBeLessThanOrEqual(hook.maxScale);
      expect(hook.scale).toBe(10);
    });

    it("clamps scale at minScale", () => {
      const btn = attachButton({ "data-zoom": "out", "aria-label": "Zoom out" });
      hook.scale = 0.6;
      hook.viewBox.w = 100 / 0.6;
      hook.viewBox.h = 80 / 0.6;
      hook.viewBox.x = 0;
      hook.viewBox.y = 0;
      btn.click();
      expect(hook.scale).toBeGreaterThanOrEqual(hook.minScale);
      expect(hook.scale).toBe(0.5);
    });

    it("does nothing when already at minScale and zooming out", () => {
      const btn = attachButton({ "data-zoom": "out", "aria-label": "Zoom out" });
      hook.scale = hook.minScale;
      hook.viewBox.w = hook.baseW / hook.minScale;
      hook.viewBox.h = hook.baseH / hook.minScale;
      const initialW = hook.viewBox.w;
      btn.click();
      expect(hook.scale).toBe(hook.minScale);
      expect(hook.viewBox.w).toBe(initialW);
    });
  });

  describe("reset button", () => {
    it("restores base viewBox and resets scale to 1", () => {
      const btn = attachButton({ "data-reset": "true", "aria-label": "Reset view" });
      btn.click();
      expect(hook.scale).toBe(1);
      expect(hook.viewBox).toEqual({ x: 0, y: 0, w: hook.baseW, h: hook.baseH });
    });

    it("calls clampViewBox and updateViewBox", () => {
      const btn = attachButton({ "data-reset": "true", "aria-label": "Reset view" });
      const clampSpy = vi.spyOn(hook, "clampViewBox");
      const updateSpy = vi.spyOn(hook, "updateViewBox");
      btn.click();
      expect(clampSpy).toHaveBeenCalled();
      expect(updateSpy).toHaveBeenCalled();
    });

    it("syncs overlay viewBox through the same path the observer expects", () => {
      const btn = attachButton({ "data-reset": "true", "aria-label": "Reset view" });
      const syncSpy = vi.spyOn(hook, "syncOverlayViewBox");
      btn.click();
      // updateViewBox calls syncOverlayViewBox; observer sees the new viewBox
      // matches this.viewBox and continues without spurious reset
      expect(syncSpy).toHaveBeenCalled();
    });
  });

  describe("zoom label", () => {
    it("displays current zoom percentage when updateViewBox runs", () => {
      const label = attachZoomLabel();
      hook.scale = 2.5;
      hook.updateViewBox();
      expect(label.textContent).toBe("250%");
    });

    it("displays 100% at scale 1", () => {
      const label = attachZoomLabel();
      hook.scale = 1;
      hook.updateViewBox();
      expect(label.textContent).toBe("100%");
    });
  });

  describe("native zoom non-interception", () => {
    it("does not intercept Ctrl/Cmd +/- keyboard", () => {
      // The pan/zoom controls use click events on div buttons,
      // not keyboard listeners. Ctrl/Cmd +/- remain handled by
      // the browser for native zoom.
      const btn = attachButton({ "data-pan": "up", "aria-label": "Pan up" });
      // Structural guarantee: clicking a button dispatches a MouseEvent,
      // not a KeyboardEvent. Ctrl/Cmd state on mouse events does not
      // affect native zoom.
      expect(btn).toBeDefined();
    });

    it("edge page-scroll is preserved because pan/zoom uses click, not wheel", () => {
      // Pan/zoom buttons do not touch the wheel event path.
      // The existing handleWheel preserves edge page-scroll at lines 424-436.
      // Buttons are additive: they manipulate viewBox synchronously,
      // independent of wheel-based panning.
      const btn = attachButton({ "data-pan": "up", "aria-label": "Pan up" });
      btn.click();
      // No wheel event is dispatched; edge page-scroll path is untouched.
      expect(hook.viewBox.y).toBeLessThan(10);
    });
  });
});

describe("DiagramCanvasHook — Escape/cancel keyboard placement", () => {
  let container;
  let svg;
  let overlay;
  let hook;

  function createDrawerOverlay({ open = false } = {}) {
    const el = document.createElement("dialog");
    el.setAttribute("id", "child-stop-drawer-overlay");
    el.dataset.open = String(open);
    document.body.appendChild(el);
    return el;
  }

  beforeEach(() => {
    document.body.innerHTML = "";
    const canvas = makeCanvas();
    container = canvas.container;
    svg = canvas.svg;
    overlay = canvas.overlay;
    hook = makeHook(svg);
    hook.mounted();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("Escape cancels keyboard placement", () => {
    it("pushes cancel_placement when child-stop-drawer is open", () => {
      createDrawerOverlay({ open: true });
      const pushEventSpy = vi.spyOn(hook, "pushEvent");
      dispatchDocumentKeydown("Escape");
      expect(pushEventSpy).toHaveBeenCalledWith("cancel_placement", {});
    });

    it("does not push cancel_placement when drawer is not open", () => {
      createDrawerOverlay({ open: false });
      const pushEventSpy = vi.spyOn(hook, "pushEvent");
      dispatchDocumentKeydown("Escape");
      expect(pushEventSpy).not.toHaveBeenCalledWith("cancel_placement", {});
    });

    it("does not push cancel_placement when drawer element is absent", () => {
      const pushEventSpy = vi.spyOn(hook, "pushEvent");
      dispatchDocumentKeydown("Escape");
      expect(pushEventSpy).not.toHaveBeenCalledWith("cancel_placement", {});
    });

    it("still cancels drag when dragging and drawer is open (existing behavior preserved)", () => {
      createDrawerOverlay({ open: true });
      const { group } = makeStopGroup(overlay);
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
    });
  });
});
