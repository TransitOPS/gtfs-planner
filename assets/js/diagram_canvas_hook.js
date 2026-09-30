/**
 * DiagramCanvas Hook
 * Provides pan and zoom functionality for the station diagram SVG canvas.
 */
// Overlay elements that open the pathway editor; a click on one while setting
// scale places a ruler point instead.
const MEASURE_CLICK_THROUGH = '[data-editable="pathway"], [data-cross-level-pathway-badge]';
// Points that take a click from the saved ruler painted above them.
const RULER_YIELDS_TO = "[data-stop-hit-target], [data-journal-marker]";

// Overlay sizes, in CSS pixels. `scaleOverlayElements` converts them to viewBox
// units at the current window size and zoom, so on-screen size does not depend
// on how large the plan happens to be fitted. Server-rendered `data-base-*`
// attributes are in the same pixels and take precedence where present.
const OVERLAY_BASE = {
  // Point markers: 12px circle, 12x20px upright rect, 12px square.
  circleR: 6,
  rectUprightW: 12,
  rectUprightH: 20,
  rectSquareSize: 12,
  rectBottomAnchorRatio: 0.8,
  rectRx: 2,
  // Painted under the fill, so half of it (2px) shows as the white ring.
  markerRingStroke: 4,
  entranceStroke: 2,
  hitTargetSize: 24,
  // Point names.
  stopLabelFontSize: 12,
  stopLabelStrokeWidth: 3,
  stopLabelLineHeight: 14,
  stopLabelMinScale: 0.85,
  // Clear space kept around a label when it is tested against others (px), and
  // between a marker and a label moved beside it.
  stopLabelClearance: 2,
  stopLabelMarkerGap: 4,
  // Pathways.
  pathwayLabelMinScale: 1.1,
  pathwayLabelFontSize: 11,
  pathwayLabelStrokeWidth: 3,
  pathwayHitStroke: 14,
  pathwayTooltipHitStroke: 6,
  pathwayMarkerSize: 8,
  pathwayElevatorBoxSize: 16,
  pathwayElevatorBoxStroke: 2.5,
  pathwayElevatorTextSize: 11,
  // Cross-level badges.
  crossLevelStairsSize: 15,
  crossLevelStairsStep: 5,
  crossLevelElevatorHalfHeight: 8,
  crossLevelElevatorHalfWidth: 6,
  crossLevelElevatorGap: 1,
  crossLevelBadgeHitSize: 20,
  // Journal markers. The pin path is drawn in its own ~2-unit-tall units.
  journalPinPxPerUnit: 11,
  journalPinHitTop: 22,
  journalRingR: 13,
  journalRingDash: 4,
  journalRingGap: 3,
  journalStroke: 2,
  // Ruler.
  rulerLineStroke: 2,
  rulerHitStroke: 12,
  rulerEndpointRadius: 4,
  rulerEndpointStroke: 2,
  rulerLabelFontSize: 11,
  rulerLabelStroke: 3,
  rulerLabelMinScale: 0.85,
  savedRulerLabelMinScale: 2,
  rulerEndpointHideNearOneMinScale: 0.9,
  rulerEndpointHideNearOneMaxScale: 1.1,
  // Pending marker triangle.
  pendingHalfWidth: 8,
  pendingHeightAbove: 10,
  pendingHeightBelow: 6,
  pendingStroke: 1.5
};

// Below 100% zoom markers shrink, to this fraction at the minimum zoom.
const MARKER_MIN_SHRINK = 0.75;
const MIN_ZOOM = 0.5;

const TOOLTIP_POINTER_OFFSET = 12;
const TOOLTIP_VIEWPORT_PADDING = 8;
const DRAG_HOLD_MS = 200;
const DRAG_THRESHOLD_UNITS = 2;
const PAN_FRACTION = 0.25;
const ZOOM_FACTOR = 1.5;

function paletteColor(root, variable, fallback) {
  const page = root?.closest?.("#diagram-page");
  const computed = page && typeof getComputedStyle === "function"
    ? getComputedStyle(page).getPropertyValue(variable)
    : "";
  const value = (computed || page?.style?.getPropertyValue(variable) || "").trim();

  return value || fallback;
}

function parallelOffsetFromSegment(x1, y1, x2, y2, offset) {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const length = Math.sqrt(dx * dx + dy * dy);

  if (!(length > 0)) {
    return {x1, y1, x2, y2};
  }

  const perpX = -dy / length;
  const perpY = dx / length;

  return {
    x1: x1 + perpX * offset,
    y1: y1 + perpY * offset,
    x2: x2 + perpX * offset,
    y2: y2 + perpY * offset
  };
}

function trimSegmentEnds(x1, y1, x2, y2, trimStart, trimEnd) {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const length = Math.sqrt(dx * dx + dy * dy);

  if (!(length > 0) || trimStart < 0 || trimEnd < 0 || trimStart + trimEnd >= length) {
    return {x1, y1, x2, y2};
  }

  const unitX = dx / length;
  const unitY = dy / length;

  return {
    x1: x1 + unitX * trimStart,
    y1: y1 + unitY * trimStart,
    x2: x2 - unitX * trimEnd,
    y2: y2 - unitY * trimEnd
  };
}

const rectsOverlap = (a, b) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

// A marker's bounds in overlay units, from the geometry `scaleOverlayElements`
// just set; null when it has none.
const markerRect = (marker) => {
  const num = (name) => parseFloat(marker.getAttribute(name));
  const r = num("r");
  const rect = Number.isFinite(r)
    ? { x: num("cx") - r, y: num("cy") - r, width: 2 * r, height: 2 * r }
    : { x: num("x"), y: num("y"), width: num("width"), height: num("height") };

  return Object.values(rect).every(Number.isFinite) ? rect : null;
};

// Lower places first: the selected point, then platforms, entrances, boarding
// areas and other nodes.
const STOP_LABEL_TYPE_RANK = { 0: 1, 2: 2, 4: 3, 3: 4 };

const stopLabelRank = (label) => {
  if (label.closest("[data-stop-state]")?.getAttribute("data-stop-state") === "selected") {
    return 0;
  }

  return STOP_LABEL_TYPE_RANK[label.getAttribute("data-location-type")] ?? 5;
};

// The rendered text size in overlay units, or null where the browser cannot
// measure it (jsdom, or not laid out).
const measureLabel = (label) => {
  try {
    const bbox = label.getBBox?.();

    return bbox && bbox.width > 0 && bbox.height > 0
      ? { width: bbox.width, height: bbox.height }
      : null;
  } catch {
    return null;
  }
};

const DiagramCanvasHook = {
  // CSS pixels to overlay viewBox units, or 0 while the overlay has no layout.
  // The overlay fits its viewBox with `meet`, so the plan can be width- or
  // height-bound; the screen CTM already accounts for both.
  unitsPerPx(overlay) {
    const pxPerUnit = overlay.getScreenCTM?.()?.a;

    return Number.isFinite(pxPerUnit) && pxPerUnit > 0 ? 1 / pxPerUnit : 0;
  },

  // Markers hold their size from 100% zoom up; below it they ease down to 75%
  // at the minimum zoom. Text never shrinks.
  markerShrink(scale) {
    const safeScale = Number.isFinite(scale) && scale > 0 ? scale : 1;

    if (safeScale >= 1) {
      return 1;
    }

    return 1 - (1 - Math.max(safeScale, MIN_ZOOM)) * ((1 - MARKER_MIN_SHRINK) / (1 - MIN_ZOOM));
  },

  isViewMode() {
    return this.overlay?.getAttribute("data-mode") === "view";
  },

  isMeasurementEnabled() {
    return this.overlay?.getAttribute("data-measurement-enabled") === "true";
  },

  clientPointToSvg(clientX, clientY) {
    const ctm = this.el.getScreenCTM();

    if (!ctm) {
      return null;
    }

    const pt = this.el.createSVGPoint();
    pt.x = clientX;
    pt.y = clientY;
    return pt.matrixTransform(ctm.inverse());
  },

  clampSvg(value, max) {
    return Math.max(0, Math.min(max, value));
  },

  debugDrag(message, extra = {}) {
    if (!this.dragDebug) {
      return;
    }

    // eslint-disable-next-line no-console
    console.debug("[DiagramCanvas.drag]", message, extra);
  },

  cancelDragHold() {
    if (this.dragCandidate?.holdTimer) {
      clearTimeout(this.dragCandidate.holdTimer);
    }

    this.dragCandidate = null;
  },

  restoreDraggedPathways(dragging) {
    if (!dragging?.pathwayElements) {
      return;
    }

    dragging.pathwayElements.forEach((snapshot) => {
      if (!snapshot.element?.isConnected) {
        return;
      }

      snapshot.element.setAttribute("x1", `${snapshot.baseX1}`);
      snapshot.element.setAttribute("y1", `${snapshot.baseY1}`);
      snapshot.element.setAttribute("x2", `${snapshot.baseX2}`);
      snapshot.element.setAttribute("y2", `${snapshot.baseY2}`);
    });
  },

  reconcilePendingDropAfterPatch() {
    if (!this.pendingDrop) {
      return;
    }

    const pending = this.pendingDrop;
    let persisted = false;

    const currentGroup = this.overlay?.querySelector(`g[data-stop-id="${pending.stopId}"]`);

    if (currentGroup) {
      const cx = parseFloat(currentGroup.getAttribute("data-stop-center-x"));
      const cy = parseFloat(currentGroup.getAttribute("data-stop-center-y"));

      if (Number.isFinite(cx) && Number.isFinite(cy)) {
        persisted = Math.abs(cx - pending.finalX) < 0.01 && Math.abs(cy - pending.finalY) < 0.01;
      }

      currentGroup.removeAttribute("transform");
      currentGroup.classList.remove("dragging");
    }

    if (!persisted) {
      this.restoreDraggedPathways(pending);
    }

    this.pendingDrop = null;
    this.scaleOverlayElements();
  },

  handleOverlayPointerDown(e) {
    if (this.dragCandidate || this.dragging || this.pendingDrop) {
      this.debugDrag("pointer down ignored: drag already active", {
        hasCandidate: Boolean(this.dragCandidate),
        hasDragging: Boolean(this.dragging),
        hasPendingDrop: Boolean(this.pendingDrop)
      });
      return;
    }

    if (!this.overlay || !this.isViewMode() || this.isMeasurementEnabled()) {
      this.debugDrag("pointer down ignored: mode/overlay/measurement mismatch", {
        hasOverlay: Boolean(this.overlay),
        mode: this.overlay?.getAttribute("data-mode"),
        measurementEnabled: this.isMeasurementEnabled()
      });
      return;
    }

    if ((e.type === "mousedown" || e.type === "pointerdown") && e.button !== 0) {
      this.debugDrag("pointer down ignored: non-primary button", { button: e.button, type: e.type });
      return;
    }

    const hitTarget = this.pointUnderRuler(e, "[data-stop-hit-target]");
    if (!hitTarget || !this.overlay.contains(hitTarget)) {
      this.debugDrag("pointer down ignored: not on stop hit target", { type: e.type });
      return;
    }

    const groupEl = hitTarget.closest("g[data-stop-id]");
    if (!groupEl) {
      this.debugDrag("pointer down ignored: stop group not found");
      return;
    }

    const stopId = groupEl.getAttribute("data-stop-id");
    const centerX = parseFloat(groupEl.getAttribute("data-stop-center-x"));
    const centerY = parseFloat(groupEl.getAttribute("data-stop-center-y"));
    const startPoint = this.clientPointToSvg(e.clientX, e.clientY);

    if (!stopId || !Number.isFinite(centerX) || !Number.isFinite(centerY) || !startPoint) {
      this.debugDrag("pointer down ignored: missing drag candidate data", {
        stopId,
        centerX,
        centerY,
        startPoint
      });
      return;
    }

    this.cancelDragHold();

    const candidate = {
      stopId,
      groupEl,
      centerX,
      centerY,
      startSvgX: startPoint.x,
      startSvgY: startPoint.y,
      movedTooFar: false,
      holdTimer: null
    };

    this.debugDrag("drag hold started", {
      stopId,
      type: e.type,
      startSvgX: candidate.startSvgX,
      startSvgY: candidate.startSvgY
    });

    candidate.holdTimer = setTimeout(() => {
      if (!this.dragCandidate || this.dragCandidate.stopId !== candidate.stopId) {
        this.debugDrag("drag hold timer ignored: candidate changed", { stopId: candidate.stopId });
        return;
      }

      if (this.dragCandidate.movedTooFar) {
        this.debugDrag("drag hold canceled: moved before threshold", { stopId: candidate.stopId });
        this.cancelDragHold();
        return;
      }

      const pathwayElements = [];

      this.overlay
        .querySelectorAll("#pathways-svg g[data-from-stop-id][data-to-stop-id]")
        .forEach((pathwayGroup) => {
          const fromStopId = pathwayGroup.getAttribute("data-from-stop-id");
          const toStopId = pathwayGroup.getAttribute("data-to-stop-id");
          const movesStart = fromStopId === candidate.stopId;
          const movesEnd = toStopId === candidate.stopId;

          if (!movesStart && !movesEnd) {
            return;
          }

          pathwayGroup.querySelectorAll("[x1][y1][x2][y2]").forEach((element) => {
            const baseX1 = parseFloat(element.getAttribute("x1"));
            const baseY1 = parseFloat(element.getAttribute("y1"));
            const baseX2 = parseFloat(element.getAttribute("x2"));
            const baseY2 = parseFloat(element.getAttribute("y2"));

            if (
              !Number.isFinite(baseX1) ||
              !Number.isFinite(baseY1) ||
              !Number.isFinite(baseX2) ||
              !Number.isFinite(baseY2)
            ) {
              return;
            }

            pathwayElements.push({
              element,
              movesStart,
              movesEnd,
              baseX1,
              baseY1,
              baseX2,
              baseY2
            });
          });
        });

      this.dragging = {
        stopId: candidate.stopId,
        groupEl: candidate.groupEl,
        centerX: candidate.centerX,
        centerY: candidate.centerY,
        startSvgX: candidate.startSvgX,
        startSvgY: candidate.startSvgY,
        currentX: candidate.centerX,
        currentY: candidate.centerY,
        pathwayElements
      };

      this.hideTooltip();
      this.dragging.groupEl.classList.add("dragging");
      this._suppressNextClick = true;
      this.debugDrag("drag started", {
        stopId: candidate.stopId,
        connectedPathSegments: pathwayElements.length
      });
      this.pushEvent("drag_start", { id: candidate.stopId });
      this.cancelDragHold();
    }, DRAG_HOLD_MS);

    this.dragCandidate = candidate;
  },

  handleWheel(e) {
    const svg = this.el;

    if (e.ctrlKey || e.metaKey) {
      e.preventDefault();
      // Scroll up (negative deltaY) = zoom in, scroll down = zoom out
      const delta = e.deltaY > 0 ? 0.95 : 1.05;
      const newScale = Math.min(this.maxScale, Math.max(this.minScale, this.scale * delta));

      if (newScale !== this.scale) {
        const rect = svg.getBoundingClientRect();
        const mouseX = (e.clientX - rect.left) / rect.width * this.viewBox.w + this.viewBox.x;
        const mouseY = (e.clientY - rect.top) / rect.height * this.viewBox.h + this.viewBox.y;

        const newW = this.baseW / newScale;
        const newH = this.baseH / newScale;

        this.viewBox.x = mouseX - (mouseX - this.viewBox.x) * (newW / this.viewBox.w);
        this.viewBox.y = mouseY - (mouseY - this.viewBox.y) * (newH / this.viewBox.h);
        this.viewBox.w = newW;
        this.viewBox.h = newH;
        this.scale = newScale;

        this.updateViewBox();
      }
    } else {
      // Calculate limits to check if we should allow page scroll
      const margin = 0.5;
      const minY = -this.viewBox.h * margin;
      const maxY = this.baseH - this.viewBox.h * (1 - margin);

      // Use a small epsilon for float comparison
      const isAtTop = this.viewBox.y <= minY + 0.1;
      const isAtBottom = this.viewBox.y >= maxY - 0.1;

      // If we are at the edge and trying to scroll past it, let the page scroll
      if ((isAtTop && e.deltaY < 0) || (isAtBottom && e.deltaY > 0)) {
        return;
      }

      e.preventDefault();
      const panSpeed = 0.3;
      this.viewBox.x += e.deltaX * panSpeed / this.scale;
      this.viewBox.y += e.deltaY * panSpeed / this.scale;
      this.clampViewBox();
      this.updateViewBox();
    }
  },

  handleMouseDown(e) {
    if (this.dragging) {
      return;
    }

    if (e.button === 1 || (e.button === 0 && e.shiftKey)) {
      this.isPanning = true;
      this.panStart = { x: e.clientX, y: e.clientY };
      this.el.style.cursor = "grabbing";
      e.preventDefault();
    }
  },

  // The saved ruler is painted above the points, so a press or click on a point
  // beneath it lands on the ruler. Returns the point under the pointer instead.
  // Without elementsFromPoint the ruler keeps the event.
  pointUnderRuler(e, selector) {
    const direct = e.target.closest(selector);

    if (direct || !e.target.closest('[data-ruler-type="saved"]')) {
      return direct;
    }

    const stack = document.elementsFromPoint?.(e.clientX, e.clientY) ?? [];
    return (
      stack
        .map((el) => el.closest(selector))
        .find((point) => point && this.overlay.contains(point)) ?? null
    );
  },

  handleOverlayClick(e) {
    // While setting scale, a pathway or cross-level badge places a ruler point
    // like the bare floorplan does; stopping the click keeps LiveView from
    // opening the pathway editor. Keyboard activation dispatches a click with
    // detail 0 and no pointer position, so it is left to the server guard.
    if (e.detail > 0 && this.isMeasurementEnabled() && e.target.closest(MEASURE_CLICK_THROUGH)) {
      e.stopPropagation();
      this.handleCanvasClick(e);
      return;
    }

    if (!e.target.closest('[data-ruler-type="saved"]')) {
      return;
    }

    // A point under the ruler wins: hand it the click, which LiveView routes
    // through the point's own phx-click.
    const point = this.pointUnderRuler(e, RULER_YIELDS_TO);

    if (point) {
      point.dispatchEvent(
        new MouseEvent("click", {
          bubbles: true,
          cancelable: true,
          clientX: e.clientX,
          clientY: e.clientY
        })
      );
      return;
    }

    this.pushEvent("scale_line_click", {});
  },

  handleMouseMove(e) {
    if (this.dragCandidate && !this.dragging) {
      const point = this.clientPointToSvg(e.clientX, e.clientY);

      if (point) {
        const dx = point.x - this.dragCandidate.startSvgX;
        const dy = point.y - this.dragCandidate.startSvgY;
        const distance = Math.sqrt(dx * dx + dy * dy);

        if (distance > DRAG_THRESHOLD_UNITS) {
          this.debugDrag("drag hold canceled: moved too far", {
            stopId: this.dragCandidate.stopId,
            distance,
            threshold: DRAG_THRESHOLD_UNITS
          });
          this.dragCandidate.movedTooFar = true;
          this.cancelDragHold();
        }
      }
    }

    if (this.dragging) {
      const point = this.clientPointToSvg(e.clientX, e.clientY);

      if (!point) {
        return;
      }

      const dx = point.x - this.dragging.startSvgX;
      const dy = point.y - this.dragging.startSvgY;
      // Diagram space is width-normalized: x spans 0..baseW (100) and y spans
      // 0..baseH (100 * h / w), which exceeds 100 for a portrait image. A
      // landscape image keeps the 0..100 limit on y.
      const maxY = Math.max(this.baseH, 100);
      const offsetX = this.clampSvg(this.dragging.centerX + dx, this.baseW) - this.dragging.centerX;
      const offsetY = this.clampSvg(this.dragging.centerY + dy, maxY) - this.dragging.centerY;

      this.dragging.currentX = this.dragging.centerX + offsetX;
      this.dragging.currentY = this.dragging.centerY + offsetY;

      this.dragging.groupEl.setAttribute("transform", `translate(${offsetX}, ${offsetY})`);

      this.dragging.pathwayElements.forEach((snapshot) => {
        if (!snapshot.element?.isConnected) {
          return;
        }

        const x1 = snapshot.baseX1 + (snapshot.movesStart ? offsetX : 0);
        const y1 = snapshot.baseY1 + (snapshot.movesStart ? offsetY : 0);
        const x2 = snapshot.baseX2 + (snapshot.movesEnd ? offsetX : 0);
        const y2 = snapshot.baseY2 + (snapshot.movesEnd ? offsetY : 0);

        snapshot.element.setAttribute("x1", `${x1}`);
        snapshot.element.setAttribute("y1", `${y1}`);
        snapshot.element.setAttribute("x2", `${x2}`);
        snapshot.element.setAttribute("y2", `${y2}`);
      });

      return;
    }

    if (this.isPanning) {
      const rect = this.el.getBoundingClientRect();
      const dx = (e.clientX - this.panStart.x) / rect.width * this.viewBox.w;
      const dy = (e.clientY - this.panStart.y) / rect.height * this.viewBox.h;
      this.viewBox.x -= dx;
      this.viewBox.y -= dy;
      this.panStart = { x: e.clientX, y: e.clientY };
      this.clampViewBox();
      this.updateViewBox();
    }
  },

  handleMouseUp(e) {
    if (this.dragCandidate && !this.dragging) {
      this.cancelDragHold();
    }

    if (this.dragging) {
      const dragging = this.dragging;
      const finalX = Math.round(dragging.currentX * 100) / 100;
      const finalY = Math.round(dragging.currentY * 100) / 100;

      dragging.groupEl.classList.remove("dragging");
      this.pendingDrop = {
        ...dragging,
        finalX,
        finalY
      };

      this.pushEvent("drag_end", {
        id: dragging.stopId,
        x: finalX,
        y: finalY
      });
      this.debugDrag("drag ended", {
        stopId: dragging.stopId,
        x: finalX,
        y: finalY
      });

      this.dragging = null;
      this._suppressNextClick = true;
      return;
    }

    if (this.isPanning) {
      this.isPanning = false;
      this.el.style.cursor = "";
    }
  },

  handleDocumentKeyDown(e) {
    if (e.key === "Escape" && this.dragging) {
      const dragging = this.dragging;
      dragging.groupEl.classList.remove("dragging");
      dragging.groupEl.removeAttribute("transform");
      this.restoreDraggedPathways(dragging);
      this.dragging = null;
      this.cancelDragHold();
      this._suppressNextClick = true;
      this.debugDrag("drag canceled by escape", { stopId: dragging.stopId });
      this.pushEvent("drag_cancel", {});
      return;
    }

    // Cancel keyboard placement/reposition
    if (e.key === "Escape") {
      const drawer = document.getElementById("child-stop-drawer-overlay");
      if (drawer && drawer.dataset.open === "true") {
        e.preventDefault();
        this.pushEvent("cancel_placement", {});
        return;
      }
    }

    if ((e.key === "Enter" || e.key === " ") && this.isViewMode() && this.overlay) {
      const activeEl = document.activeElement;
      if (!activeEl || !this.overlay.contains(activeEl)) {
        return;
      }
      if (!activeEl.hasAttribute("tabindex")) {
        return;
      }

      if (e.key === " ") {
        e.preventDefault();
      }

      const activationTarget = activeEl.hasAttribute("data-stop-id")
        ? activeEl.querySelector("[data-stop-hit-target]")
        : activeEl;

      if (activationTarget) {
        activationTarget.dispatchEvent(
          new MouseEvent("click", {
            bubbles: true,
            cancelable: true
          })
        );
      }
    }
  },

  handleCanvasClick(e) {
    if (e.shiftKey) {
      return;
    }

    if (this._suppressNextClick) {
      this._suppressNextClick = false;
      return;
    }

    if (this.dragging || this.dragCandidate) {
      return;
    }

    const svgPt = this.clientPointToSvg(e.clientX, e.clientY);

    if (!svgPt) {
      return;
    }

    const x = Math.round(svgPt.x * 100) / 100;
    const y = Math.round(svgPt.y * 100) / 100;
    this.pushEvent("canvas_click", { x, y });
  },

  handleCapturedClick(e) {
    if (!this._suppressNextClick) {
      return;
    }

    this._suppressNextClick = false;
    e.preventDefault();
    e.stopPropagation();

    if (typeof e.stopImmediatePropagation === "function") {
      e.stopImmediatePropagation();
    }
  },

  handleGesture(e) {
    e.preventDefault();
  },

  handlePanZoomButtonClick(e) {
    const panBtn = e.target.closest("[data-pan]");
    if (panBtn) {
      const direction = panBtn.getAttribute("data-pan");
      const stepX = this.viewBox.w * PAN_FRACTION;
      const stepY = this.viewBox.h * PAN_FRACTION;

      switch (direction) {
        case "up":
          this.viewBox.y -= stepY;
          break;
        case "down":
          this.viewBox.y += stepY;
          break;
        case "left":
          this.viewBox.x -= stepX;
          break;
        case "right":
          this.viewBox.x += stepX;
          break;
      }

      this.clampViewBox();
      this.updateViewBox();
      return;
    }

    const zoomBtn = e.target.closest("[data-zoom]");
    if (zoomBtn) {
      const factor = zoomBtn.getAttribute("data-zoom") === "in" ? ZOOM_FACTOR : 1 / ZOOM_FACTOR;
      const newScale = Math.min(this.maxScale, Math.max(this.minScale, this.scale * factor));

      if (newScale !== this.scale) {
        const centerX = this.viewBox.x + this.viewBox.w / 2;
        const centerY = this.viewBox.y + this.viewBox.h / 2;
        const newW = this.baseW / newScale;
        const newH = this.baseH / newScale;

        this.viewBox.x = centerX - newW / 2;
        this.viewBox.y = centerY - newH / 2;
        this.viewBox.w = newW;
        this.viewBox.h = newH;
        this.scale = newScale;

        this.clampViewBox();
        this.updateViewBox();
      }
      return;
    }

    const resetBtn = e.target.closest("[data-reset]");
    if (resetBtn) {
      this.scale = 1;
      this.viewBox = { x: 0, y: 0, w: this.baseW, h: this.baseH };
      this.clampViewBox();
      this.updateViewBox();
      return;
    }
  },

  updateZoomLabel() {
    const container = this.el.parentElement;
    if (!container) return;
    const label = container.querySelector("[data-zoom-label]");
    if (label) {
      const pct = Math.round(this.scale * 100);
      label.textContent = `${pct}%`;
    }
  },

  setupOverlayPanZoom() {
    if (!this.overlay || this._overlayPanZoomBound === this.overlay) {
      return;
    }

    this.removeOverlayPanZoom();
    this.overlay.addEventListener("wheel", this._handleWheel, { passive: false });
    this.overlay.addEventListener("mousedown", this._handleMouseDown);
    this.overlay.addEventListener("mousedown", this._handleOverlayPointerDown);
    this.overlay.addEventListener("click", this._handleCapturedClick, true);
    this.overlay.addEventListener("click", this._handleOverlayClick);
    this.overlay.addEventListener("gesturestart", this._handleGesture);
    this.overlay.addEventListener("gesturechange", this._handleGesture);
    this._overlayPanZoomBound = this.overlay;
  },

  removeOverlayPanZoom() {
    if (!this._overlayPanZoomBound) {
      return;
    }

    this._overlayPanZoomBound.removeEventListener("wheel", this._handleWheel);
    this._overlayPanZoomBound.removeEventListener("mousedown", this._handleMouseDown);
    this._overlayPanZoomBound.removeEventListener("mousedown", this._handleOverlayPointerDown);
    this._overlayPanZoomBound.removeEventListener("click", this._handleCapturedClick, true);
    this._overlayPanZoomBound.removeEventListener("click", this._handleOverlayClick);
    this._overlayPanZoomBound.removeEventListener("gesturestart", this._handleGesture);
    this._overlayPanZoomBound.removeEventListener("gesturechange", this._handleGesture);
    this._overlayPanZoomBound = null;
  },

  mounted() {
    const svg = this.el;
    this.baseW = 100;
    this.baseH = 100;
    this.viewBox = { x: 0, y: 0, w: 100, h: 100 };
    this.scale = 1;
    this.minScale = MIN_ZOOM;
    this.maxScale = 10;
    this.isPanning = false;
    this.panStart = { x: 0, y: 0 };
    this._canvasKey = svg.getAttribute("data-canvas-key");
    this.currentImageHref = null;
    this._activeImageLoadToken = 0;
    this._imageLoadInProgress = false;
    this.overlay = null;
    this.tooltipEl = null;
    this.tooltipState = {
      activeTarget: null,
      visible: false,
      anchor: null
    };
    this.tooltipListenersBound = false;
    this.tooltipListenerOverlay = null;
    this._overlayPanZoomBound = null;
    this.dragCandidate = null;
    this.dragging = null;
    this.pendingDrop = null;
    this._suppressNextClick = false;
    this.dragDebug =
      window.localStorage.getItem("diagramDragDebug") === "1" ||
      new URLSearchParams(window.location.search).get("drag_debug") === "1";

    // Create bound references for proper add/remove
    this._handleWheel = this.handleWheel.bind(this);
    this._handleMouseDown = this.handleMouseDown.bind(this);
    this._handleMouseMove = this.handleMouseMove.bind(this);
    this._handleMouseUp = this.handleMouseUp.bind(this);
    this._handleGesture = this.handleGesture.bind(this);
    this._handleOverlayClick = this.handleOverlayClick.bind(this);
    this._handleOverlayPointerDown = this.handleOverlayPointerDown.bind(this);
    this._handleCanvasClick = this.handleCanvasClick.bind(this);
    this._handleCapturedClick = this.handleCapturedClick.bind(this);
    this._handleDocumentKeyDown = this.handleDocumentKeyDown.bind(this);
    this._handlePanZoomButtonClick = this.handlePanZoomButtonClick.bind(this);

    this.refreshTooltipElements();
    this.setupTooltipListeners();
    this.setupOverlayPanZoom();
    this.debugDrag("hook mounted", {
      mode: this.overlay?.getAttribute("data-mode"),
      measurementEnabled: this.overlay?.getAttribute("data-measurement-enabled")
    });

    // Set up MutationObserver to detect when overlay viewBox gets reset
    this.setupOverlayObserver();

    // The pixel-to-unit conversion depends on the canvas size, which changes
    // with the window and with the panels around the plan.
    if (typeof ResizeObserver === "function" && svg.parentElement) {
      this.resizeObserver = new ResizeObserver(() => this.scaleOverlayElements());
      this.resizeObserver.observe(svg.parentElement);
    }

    this.syncImageDimensions(true);
    this.scaleOverlayElements();

    // Wheel and mousedown on main canvas SVG
    svg.addEventListener("wheel", this._handleWheel, { passive: false });
    svg.addEventListener("mousedown", this._handleMouseDown);

    // Mousemove and mouseup on document so panning works seamlessly
    // across SVG layers and even outside the diagram
    document.addEventListener("mousemove", this._handleMouseMove);
    document.addEventListener("mouseup", this._handleMouseUp);
    document.addEventListener("keydown", this._handleDocumentKeyDown);

    svg.addEventListener("click", this._handleCapturedClick, true);
    svg.addEventListener("click", this._handleCanvasClick);

    svg.addEventListener("gesturestart", this._handleGesture);
    svg.addEventListener("gesturechange", this._handleGesture);

    const container = svg.parentElement;
    if (container) {
      container.addEventListener("click", this._handlePanZoomButtonClick);
    }

    this.handleEvent("center_on_stop", ({x, y}) => {
      if (!this.hasFiniteCenterPoint({x, y})) {
        this._pendingCenter = null;
        return;
      }

      this._pendingCenter = {x, y};
      this.applyPendingCenter({consume: !this._imageLoadInProgress});
    });
  },

  hasFiniteCenterPoint(point) {
    return Number.isFinite(point?.x) && Number.isFinite(point?.y);
  },

  refreshTooltipElements() {
    const container = this.el.parentElement;
    if (!container) {
      this.overlay = null;
      this.tooltipEl = null;
      return;
    }

    this.overlay = container.querySelector("#diagram-overlay");
    this.tooltipEl = container.querySelector("#diagram-edit-tooltip");
  },

  setupTooltipListeners() {
    if (!this.overlay) {
      return;
    }

    if (this.tooltipListenersBound && this.tooltipListenerOverlay === this.overlay) {
      return;
    }

    this.removeTooltipListeners();

    this.handleTooltipMouseOver = (event) => {
      if (this.dragCandidate || this.dragging) {
        return;
      }

      const target = this.resolvePointerTooltipTarget(event.target);

      if (!target) {
        return;
      }

      this.showTooltip(target, {
        type: "pointer",
        clientX: event.clientX,
        clientY: event.clientY
      });
    };

    this.handleTooltipMouseMove = (event) => {
      if (this.dragCandidate || this.dragging) {
        return;
      }

      if (!this.tooltipState.visible || this.tooltipState.activeTarget == null) {
        return;
      }

      const target = this.resolvePointerTooltipTarget(event.target);
      if (target !== this.tooltipState.activeTarget) {
        return;
      }

      this.positionTooltip({
        type: "pointer",
        clientX: event.clientX,
        clientY: event.clientY
      });
    };

    this.handleTooltipMouseOut = (event) => {
      if (!this.tooltipState.visible || this.tooltipState.activeTarget == null) {
        return;
      }

      const nextTarget = this.resolvePointerTooltipTarget(event.relatedTarget);
      if (nextTarget === this.tooltipState.activeTarget) {
        return;
      }

      this.hideTooltip();
    };

    this.handleTooltipFocusIn = (event) => {
      if (this.dragCandidate || this.dragging) {
        return;
      }

      const target = this.resolveTooltipTarget(event.target);

      if (!target) {
        return;
      }

      this.showTooltip(target, { type: "focus" });
    };

    this.handleTooltipFocusOut = (event) => {
      if (!this.tooltipState.visible || this.tooltipState.activeTarget == null) {
        return;
      }

      const nextTarget = this.resolveTooltipTarget(event.relatedTarget);
      if (nextTarget === this.tooltipState.activeTarget) {
        return;
      }

      this.hideTooltip();
    };

    this.overlay.addEventListener("mouseover", this.handleTooltipMouseOver);
    this.overlay.addEventListener("mousemove", this.handleTooltipMouseMove);
    this.overlay.addEventListener("mouseout", this.handleTooltipMouseOut);
    this.overlay.addEventListener("focusin", this.handleTooltipFocusIn);
    this.overlay.addEventListener("focusout", this.handleTooltipFocusOut);
    this.tooltipListenersBound = true;
    this.tooltipListenerOverlay = this.overlay;
  },

  removeTooltipListeners() {
    if (!this.tooltipListenersBound || !this.tooltipListenerOverlay) {
      return;
    }

    this.tooltipListenerOverlay.removeEventListener("mouseover", this.handleTooltipMouseOver);
    this.tooltipListenerOverlay.removeEventListener("mousemove", this.handleTooltipMouseMove);
    this.tooltipListenerOverlay.removeEventListener("mouseout", this.handleTooltipMouseOut);
    this.tooltipListenerOverlay.removeEventListener("focusin", this.handleTooltipFocusIn);
    this.tooltipListenerOverlay.removeEventListener("focusout", this.handleTooltipFocusOut);
    this.tooltipListenersBound = false;
    this.tooltipListenerOverlay = null;
  },

  resolveTooltipTarget(node) {
    if (!(node instanceof Element)) {
      return null;
    }

    const target = node.closest("[data-tooltip]");

    if (!target || !this.overlay || !this.overlay.contains(target)) {
      return null;
    }

    const tooltipText = target.getAttribute("data-tooltip");
    if (!tooltipText || tooltipText.trim() === "") {
      return null;
    }

    return target;
  },

  resolvePointerTooltipTarget(node) {
    if (!(node instanceof Element)) {
      return null;
    }

    const trigger = node.closest("[data-tooltip-trigger]");

    if (!trigger || !this.overlay || !this.overlay.contains(trigger)) {
      return null;
    }

    return this.resolveTooltipTarget(trigger);
  },

  showTooltip(target, anchor) {
    if (this.dragCandidate || this.dragging) {
      return;
    }

    if (!this.tooltipEl) {
      return;
    }

    const tooltipText = target.getAttribute("data-tooltip");
    if (!tooltipText || tooltipText.trim() === "") {
      this.hideTooltip();
      return;
    }

    // A point whose name was hidden to avoid overlap shows it here instead.
    const hiddenName = target.querySelector("[data-stop-label][display='none']")
      ? target.getAttribute("data-label-text")?.trim()
      : "";

    this.tooltipEl.textContent = hiddenName
      ? `${hiddenName}\n${tooltipText.trim()}`
      : tooltipText.trim();
    const tooltipColor = target.getAttribute("data-tooltip-color");

    if (tooltipColor && tooltipColor.trim() !== "") {
      this.tooltipEl.style.backgroundColor = tooltipColor.trim();
      this.tooltipEl.style.borderColor = tooltipColor.trim();
    } else {
      this.tooltipEl.style.backgroundColor = "";
      this.tooltipEl.style.borderColor = "";
    }

    this.tooltipEl.style.color = paletteColor(this.el, "--diagram-label-halo", "#FFFFFF");
    this.tooltipEl.setAttribute("aria-hidden", "false");
    this.tooltipEl.classList.remove("is-hidden");
    this.tooltipEl.classList.add("is-visible");

    this.tooltipState.activeTarget = target;
    this.tooltipState.visible = true;
    this.tooltipState.anchor = anchor;

    this.positionTooltip(anchor);
  },

  hideTooltip() {
    this.tooltipState.activeTarget = null;
    this.tooltipState.visible = false;
    this.tooltipState.anchor = null;

    if (!this.tooltipEl) {
      return;
    }

    this.tooltipEl.setAttribute("aria-hidden", "true");
    this.tooltipEl.classList.remove("is-visible");
    this.tooltipEl.classList.add("is-hidden");
  },

  positionTooltip(anchor) {
    if (!this.tooltipEl || !this.tooltipState.visible) {
      return;
    }

    const container = this.el.parentElement;
    if (!container) {
      return;
    }

    const activeTarget = this.tooltipState.activeTarget;
    if (!activeTarget || !activeTarget.isConnected) {
      this.hideTooltip();
      return;
    }

    const nextAnchor = anchor || this.tooltipState.anchor || { type: "focus" };
    this.tooltipState.anchor = nextAnchor;

    let screenX;
    let screenY;

    if (
      nextAnchor.type === "pointer" &&
      Number.isFinite(nextAnchor.clientX) &&
      Number.isFinite(nextAnchor.clientY)
    ) {
      screenX = nextAnchor.clientX + TOOLTIP_POINTER_OFFSET;
      screenY = nextAnchor.clientY + TOOLTIP_POINTER_OFFSET;
    } else {
      const targetRect = activeTarget.getBoundingClientRect();
      screenX = targetRect.left + targetRect.width / 2;
      screenY = targetRect.top - TOOLTIP_POINTER_OFFSET;
    }

    const tooltipRect = this.tooltipEl.getBoundingClientRect();
    const maxLeft = window.innerWidth - tooltipRect.width - TOOLTIP_VIEWPORT_PADDING;
    const maxTop = window.innerHeight - tooltipRect.height - TOOLTIP_VIEWPORT_PADDING;
    const clampedLeft = Math.max(TOOLTIP_VIEWPORT_PADDING, Math.min(screenX, maxLeft));
    const clampedTop = Math.max(TOOLTIP_VIEWPORT_PADDING, Math.min(screenY, maxTop));
    const containerRect = container.getBoundingClientRect();

    this.tooltipEl.style.left = `${clampedLeft - containerRect.left}px`;
    this.tooltipEl.style.top = `${clampedTop - containerRect.top}px`;
  },

  repositionTooltipIfVisible() {
    if (!this.tooltipState.visible || !this.tooltipState.activeTarget) {
      return;
    }

    if (
      !this.tooltipState.activeTarget.isConnected ||
      (this.overlay && !this.overlay.contains(this.tooltipState.activeTarget))
    ) {
      this.hideTooltip();
      return;
    }

    this.positionTooltip(this.tooltipState.anchor);
  },

  setupOverlayObserver() {
    // Use MutationObserver to detect when LiveView resets the overlay viewBox
    const svg = this.el;
    const container = svg.parentElement;
    
    this.overlayObserver = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.type === "attributes" && mutation.attributeName === "viewBox") {
          const overlay = container.querySelector("#diagram-overlay");
          if (overlay && mutation.target === overlay) {
            const expectedViewBox =
              `${this.viewBox.x} ${this.viewBox.y} ${this.viewBox.w} ${this.viewBox.h}`;

            if (overlay.getAttribute("viewBox") === expectedViewBox) {
              continue;
            }

            // LiveView reset the viewBox, re-apply our current state
            this.syncOverlayViewBox();
            this.scaleOverlayElements();
            this.repositionTooltipIfVisible();
          }
        }
        // Also watch for child changes (stream updates)
        if (mutation.type === "childList") {
          this.refreshTooltipElements();
          this.setupTooltipListeners();
          this.setupOverlayPanZoom();
          this.syncOverlayViewBox();
          this.scaleOverlayElements();
          this.repositionTooltipIfVisible();
        }
      }
    });

    // Observe the container for changes to the overlay
    this.overlayObserver.observe(container, {
      attributes: true,
      attributeFilter: ["viewBox"],
      childList: true,
      subtree: true
    });
  },

  clampViewBox() {
    // Constrain panning to prevent drifting too far from image bounds
    // Allow up to 50% of the viewBox dimensions outside the image
    const margin = 0.5;
    const minX = -this.viewBox.w * margin;
    const maxX = this.baseW - this.viewBox.w * (1 - margin);
    const minY = -this.viewBox.h * margin;
    const maxY = this.baseH - this.viewBox.h * (1 - margin);

    this.viewBox.x = Math.max(minX, Math.min(maxX, this.viewBox.x));
    this.viewBox.y = Math.max(minY, Math.min(maxY, this.viewBox.y));
  },

  syncOverlayViewBox() {
    const svg = this.el;
    const overlay = svg.parentElement.querySelector("#diagram-overlay");
    if (overlay && this.viewBox) {
      const viewBoxStr = `${this.viewBox.x} ${this.viewBox.y} ${this.viewBox.w} ${this.viewBox.h}`;
      if (overlay.getAttribute("viewBox") !== viewBoxStr) {
        overlay.setAttribute("viewBox", viewBoxStr);
      }
    }
  },

  // Places each point name at the first spot that clears every placed name and
  // every other point's marker: its default corner, then right, left, above and
  // below the marker. A name with no free spot hides (its point still shows the
  // name on hover). Priority: the selected point, then platforms (0), entrances
  // (2), boarding areas (4), other nodes; ties keep document order, so a rerun
  // gives the same result.
  // Ceiling: every name is tested against every other, O(n^2); a station has
  // tens of points. Index the placed rects by grid cell before going to
  // thousands.
  placeStopLabels(overlay, entries, px, mk) {
    const markers = [];

    overlay.querySelectorAll("[data-stop-marker]").forEach((marker) => {
      const rect = markerRect(marker);

      if (rect) {
        markers.push({
          rect,
          cx: parseFloat(marker.getAttribute("data-center-x")),
          cy: parseFloat(marker.getAttribute("data-center-y")),
        });
      }
    });

    const clearance = px(OVERLAY_BASE.stopLabelClearance);
    const gap = px(OVERLAY_BASE.stopLabelMarkerGap);
    const placed = [];

    const ranked = entries
      .map((entry) => ({ entry, rank: stopLabelRank(entry.label) }))
      .sort((a, b) => a.rank - b.rank);

    ranked.forEach(({ entry }) => {
      const { label, labelBox, box, cx, cy } = entry;

      if (!labelBox) {
        entry.spot = { x: cx + mk(entry.offsetX), y: cy + mk(entry.offsetY) };
        return;
      }

      // Text size in overlay units: measured when the browser can, else the
      // server's per-character estimate (box size less its padding).
      const size = measureLabel(label) ?? {
        width: px(box.width - 2 * box.paddingX),
        height: px(box.height - 2 * box.paddingY),
      };

      const own = markers.find((marker) => marker.cx === cx && marker.cy === cy)?.rect ?? {
        x: cx,
        y: cy,
        width: 0,
        height: 0,
      };
      const middleY = own.y + own.height / 2 - size.height / 2;
      const centerX = own.x + own.width / 2 - size.width / 2;
      const candidates = [
        { x: cx + mk(entry.offsetX), y: cy + mk(entry.offsetY) },
        { x: own.x + own.width + gap, y: middleY },
        { x: own.x - gap - size.width, y: middleY },
        { x: centerX, y: own.y - gap - size.height },
        { x: centerX, y: own.y + own.height + gap },
      ];

      entry.spot = candidates.find((spot) => {
        const rect = {
          x: spot.x - clearance,
          y: spot.y - clearance,
          width: size.width + 2 * clearance,
          height: size.height + 2 * clearance,
        };

        return (
          !placed.some((other) => rectsOverlap(rect, other)) &&
          !markers.some((marker) => marker.rect !== own && rectsOverlap(rect, marker.rect))
        );
      });

      if (entry.spot) {
        placed.push({
          x: entry.spot.x - clearance,
          y: entry.spot.y - clearance,
          width: size.width + 2 * clearance,
          height: size.height + 2 * clearance,
        });
      }

      entry.size = size;
    });

    entries.forEach((entry) => {
      const { label, labelBox, box, spot, size } = entry;

      if (!spot) {
        label.setAttribute("display", "none");
        labelBox?.setAttribute("display", "none");
        return;
      }

      label.setAttribute("x", `${spot.x}`);
      label.setAttribute("y", `${spot.y}`);
      label.querySelectorAll("tspan").forEach((tspan) => {
        tspan.setAttribute("x", `${spot.x}`);
      });

      if (!labelBox) {
        return;
      }

      labelBox.setAttribute("x", `${spot.x - px(box.paddingX)}`);
      labelBox.setAttribute("y", `${spot.y - px(box.paddingY)}`);
      labelBox.setAttribute("width", `${size.width + 2 * px(box.paddingX)}`);
      labelBox.setAttribute("height", `${size.height + 2 * px(box.paddingY)}`);
      labelBox.setAttribute("stroke-width", `${px(box.stroke)}`);
    });
  },

  scaleOverlayElements() {
    const overlay = this.el.parentElement.querySelector("#diagram-overlay");

    if (!overlay) {
      return;
    }

    // Not laid out yet (or hidden): a resize or the next update reruns this.
    const unitsPerPx = this.unitsPerPx(overlay);

    if (!unitsPerPx) {
      return;
    }

    const scale = this.scale || 1;
    // CSS px to viewBox units. `px` is for text, hit targets and other sizes
    // that hold at every zoom; `mk` also shrinks with markers below 100% zoom.
    const px = (value) => value * unitsPerPx;
    const shrink = this.markerShrink(scale);
    const mk = (value) => value * unitsPerPx * shrink;

    // Hand the conversion to CSS so stroke widths there stay in screen px too.
    overlay.style.setProperty("--diagram-px", `${unitsPerPx}px`);

    overlay.querySelectorAll("[data-stop-hit-target]").forEach((hitTarget) => {
      const cx = parseFloat(hitTarget.getAttribute("data-center-x"));
      const cy = parseFloat(hitTarget.getAttribute("data-center-y"));
      const locationType = hitTarget.getAttribute("data-location-type");

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      // Center the target on the marker body, not on the stop coordinate.
      let markerCenterY = cy;

      if (locationType === "0" || locationType === "2") {
        const markerH = mk(OVERLAY_BASE.rectUprightH);
        markerCenterY = cy - markerH * OVERLAY_BASE.rectBottomAnchorRatio + markerH / 2;
      } else if (locationType === "4") {
        const markerSize = mk(OVERLAY_BASE.rectSquareSize);
        markerCenterY = cy - markerSize * OVERLAY_BASE.rectBottomAnchorRatio + markerSize / 2;
      }

      const size = px(OVERLAY_BASE.hitTargetSize);

      hitTarget.setAttribute("x", `${cx - size / 2}`);
      hitTarget.setAttribute("y", `${markerCenterY - size / 2}`);
      hitTarget.setAttribute("width", `${size}`);
      hitTarget.setAttribute("height", `${size}`);
    });

    overlay.querySelectorAll("[data-stop-marker]").forEach((marker) => {
      const cx = parseFloat(marker.getAttribute("data-center-x"));
      const cy = parseFloat(marker.getAttribute("data-center-y"));
      const locationType = marker.getAttribute("data-location-type");

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      if (locationType === "0" || locationType === "2") {
        const width = mk(OVERLAY_BASE.rectUprightW);
        const height = mk(OVERLAY_BASE.rectUprightH);
        marker.setAttribute("x", `${cx - width / 2}`);
        marker.setAttribute("y", `${cy - height * OVERLAY_BASE.rectBottomAnchorRatio}`);
        marker.setAttribute("width", `${width}`);
        marker.setAttribute("height", `${height}`);
        marker.setAttribute("rx", `${mk(OVERLAY_BASE.rectRx)}`);
        const strokeWidth =
          locationType === "2" ? OVERLAY_BASE.entranceStroke : OVERLAY_BASE.markerRingStroke;
        marker.setAttribute("stroke-width", `${mk(strokeWidth)}`);
        return;
      }

      if (locationType === "4") {
        const size = mk(OVERLAY_BASE.rectSquareSize);
        marker.setAttribute("x", `${cx - size / 2}`);
        marker.setAttribute("y", `${cy - size * OVERLAY_BASE.rectBottomAnchorRatio}`);
        marker.setAttribute("width", `${size}`);
        marker.setAttribute("height", `${size}`);
        marker.setAttribute("rx", `${mk(OVERLAY_BASE.rectRx)}`);
        marker.setAttribute("stroke-width", `${mk(OVERLAY_BASE.markerRingStroke)}`);
        return;
      }

      marker.setAttribute("cx", `${cx}`);
      marker.setAttribute("cy", `${cy}`);
      marker.setAttribute("r", `${mk(OVERLAY_BASE.circleR)}`);
      marker.setAttribute("stroke-width", `${mk(OVERLAY_BASE.markerRingStroke)}`);
    });

    overlay.querySelectorAll("[data-journal-pin]").forEach((pin) => {
      const cx = parseFloat(pin.getAttribute("data-center-x"));
      const cy = parseFloat(pin.getAttribute("data-center-y"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      // The pin path is drawn in its own units; this is how many px each covers.
      pin.setAttribute(
        "transform",
        `translate(${cx}, ${cy}) scale(${mk(OVERLAY_BASE.journalPinPxPerUnit)})`
      );
    });

    overlay.querySelectorAll("[data-journal-dot]").forEach((dot) => {
      const cx = parseFloat(dot.getAttribute("data-center-x"));
      const cy = parseFloat(dot.getAttribute("data-center-y"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      dot.setAttribute("cx", `${cx}`);
      dot.setAttribute("cy", `${cy}`);
      dot.setAttribute("r", `${mk(OVERLAY_BASE.circleR)}`);
      dot.setAttribute("stroke-width", `${mk(OVERLAY_BASE.journalStroke)}`);
    });

    overlay.querySelectorAll("[data-journal-ring]").forEach((ring) => {
      const cx = parseFloat(ring.getAttribute("data-center-x"));
      const cy = parseFloat(ring.getAttribute("data-center-y"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      ring.setAttribute("cx", `${cx}`);
      ring.setAttribute("cy", `${cy}`);
      ring.setAttribute("r", `${mk(OVERLAY_BASE.journalRingR)}`);
      ring.setAttribute("stroke-width", `${mk(OVERLAY_BASE.journalStroke)}`);
      ring.setAttribute(
        "stroke-dasharray",
        `${mk(OVERLAY_BASE.journalRingDash)} ${mk(OVERLAY_BASE.journalRingGap)}`
      );
    });

    overlay.querySelectorAll("[data-journal-hit-target]").forEach((hitTarget) => {
      const cx = parseFloat(hitTarget.getAttribute("data-center-x"));
      const cy = parseFloat(hitTarget.getAttribute("data-center-y"));
      const kind = hitTarget.getAttribute("data-journal-kind");

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      const size = px(OVERLAY_BASE.hitTargetSize);

      // A pin's body sits above its tip, which is the coordinate.
      hitTarget.setAttribute("x", `${cx - size / 2}`);
      hitTarget.setAttribute(
        "y",
        `${kind === "pin" ? cy - px(OVERLAY_BASE.journalPinHitTop) : cy - size / 2}`
      );
      hitTarget.setAttribute("width", `${size}`);
      hitTarget.setAttribute("height", `${size}`);
    });

    // Point names are how a mapper identifies a point, so they show from 85%
    // zoom. Crowded names move beside their point or hide (placeStopLabels).
    const labelEntries = [];

    overlay.querySelectorAll("[data-stop-label]").forEach((label) => {
      const cx = parseFloat(label.getAttribute("data-center-x"));
      const cy = parseFloat(label.getAttribute("data-center-y"));
      const offsetX = parseFloat(label.getAttribute("data-label-offset-x"));
      const offsetY = parseFloat(label.getAttribute("data-label-offset-y"));
      const baseFontSize = parseFloat(
        label.getAttribute("data-base-font-size") ?? `${OVERLAY_BASE.stopLabelFontSize}`
      );
      const baseStroke = parseFloat(
        label.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.stopLabelStrokeWidth}`
      );
      const baseLineHeight = parseFloat(
        label.getAttribute("data-base-line-height") ?? `${OVERLAY_BASE.stopLabelLineHeight}`
      );
      const labelBox = label.parentElement?.querySelector("[data-stop-label-box]");

      if (
        !Number.isFinite(cx) ||
        !Number.isFinite(cy) ||
        !Number.isFinite(offsetX) ||
        !Number.isFinite(offsetY) ||
        !Number.isFinite(baseFontSize) ||
        !Number.isFinite(baseStroke) ||
        !Number.isFinite(baseLineHeight)
      ) {
        return;
      }

      if (scale < OVERLAY_BASE.stopLabelMinScale) {
        label.setAttribute("display", "none");
        if (labelBox) {
          labelBox.setAttribute("display", "none");
        }
        return;
      }

      // Shown for now so it can be measured; placeStopLabels may hide it again.
      label.removeAttribute("display");
      if (labelBox) {
        labelBox.removeAttribute("display");
      }

      label.setAttribute("font-size", `${px(baseFontSize)}`);
      label.setAttribute("stroke-width", `${px(baseStroke)}`);

      label.querySelectorAll("tspan").forEach((tspan, index) => {
        tspan.setAttribute("dy", `${index === 0 ? 0 : px(baseLineHeight)}`);
      });

      const box = {
        width: parseFloat(labelBox?.getAttribute("data-base-width")),
        height: parseFloat(labelBox?.getAttribute("data-base-height")),
        paddingX: parseFloat(labelBox?.getAttribute("data-base-padding-x")),
        paddingY: parseFloat(labelBox?.getAttribute("data-base-padding-y")),
        stroke: parseFloat(labelBox?.getAttribute("data-base-stroke")),
      };

      labelEntries.push({
        label,
        labelBox: Object.values(box).every(Number.isFinite) ? labelBox : null,
        box,
        cx,
        cy,
        offsetX,
        offsetY,
      });
    });

    this.placeStopLabels(overlay, labelEntries, px, mk);

    overlay.querySelectorAll("[data-cross-level-badge-stairs]").forEach((stairsPath) => {
      const cx = parseFloat(stairsPath.getAttribute("data-center-x"));
      const cy = parseFloat(stairsPath.getAttribute("data-center-y"));
      const offsetX = parseFloat(stairsPath.getAttribute("data-badge-offset-x"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(offsetX)) {
        return;
      }

      const s = mk(OVERLAY_BASE.crossLevelStairsStep);
      const size = mk(OVERLAY_BASE.crossLevelStairsSize);
      const x0 = cx + mk(offsetX) - size / 2;
      const y0 = cy - size / 2;

      stairsPath.setAttribute(
        "d",
        `M ${x0} ${y0 + size} L ${x0} ${y0 + size - s} L ${x0 + s} ${y0 + size - s} L ${x0 + s} ${y0 + s} L ${x0 + size - s} ${y0 + s} L ${x0 + size - s} ${y0} L ${x0 + size} ${y0} L ${x0 + size} ${y0 + size} Z`
      );
    });

    overlay.querySelectorAll("[data-cross-level-badge-elevator]").forEach((elevPath) => {
      const cx = parseFloat(elevPath.getAttribute("data-center-x"));
      const cy = parseFloat(elevPath.getAttribute("data-center-y"));
      const offsetX = parseFloat(elevPath.getAttribute("data-badge-offset-x"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(offsetX)) {
        return;
      }

      const iconCx = cx + mk(offsetX);
      const halfH = mk(OVERLAY_BASE.crossLevelElevatorHalfHeight);
      const halfW = mk(OVERLAY_BASE.crossLevelElevatorHalfWidth);
      const gap = mk(OVERLAY_BASE.crossLevelElevatorGap);

      elevPath.setAttribute(
        "d",
        `M ${iconCx} ${cy - halfH} L ${iconCx + halfW} ${cy - gap} L ${iconCx - halfW} ${cy - gap} Z M ${iconCx} ${cy + halfH} L ${iconCx + halfW} ${cy + gap} L ${iconCx - halfW} ${cy + gap} Z`
      );
    });

    overlay.querySelectorAll("[data-cross-level-badge-hit]").forEach((hitTarget) => {
      const cx = parseFloat(hitTarget.getAttribute("data-center-x"));
      const cy = parseFloat(hitTarget.getAttribute("data-center-y"));
      const offsetX = parseFloat(hitTarget.getAttribute("data-badge-offset-x"));
      const base = parseFloat(
        hitTarget.getAttribute("data-base-size") ?? `${OVERLAY_BASE.crossLevelBadgeHitSize}`
      );

      if (![cx, cy, offsetX, base].every(Number.isFinite)) {
        return;
      }

      const iconCx = cx + mk(offsetX);
      const size = px(base);

      hitTarget.setAttribute("x", `${iconCx - size / 2}`);
      hitTarget.setAttribute("y", `${cy - size / 2}`);
      hitTarget.setAttribute("width", `${size}`);
      hitTarget.setAttribute("height", `${size}`);
    });

    overlay.querySelectorAll("#pathways-svg [data-pathway-hit]").forEach((hitTarget) => {
      const baseStroke = parseFloat(
        hitTarget.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.pathwayHitStroke}`
      );

      if (!Number.isFinite(baseStroke)) {
        return;
      }

      hitTarget.setAttribute("stroke-width", `${px(baseStroke)}`);
    });

    overlay.querySelectorAll("#pathways-svg [data-pathway-tooltip-hit]").forEach((hitTarget) => {
      const baseStroke = parseFloat(
        hitTarget.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.pathwayTooltipHitStroke}`
      );

      if (!Number.isFinite(baseStroke)) {
        return;
      }

      hitTarget.setAttribute("stroke-width", `${px(baseStroke)}`);
    });

    overlay.querySelectorAll("#pathways-svg [data-base-stroke]").forEach((element) => {
      if (
        element.hasAttribute("data-pathway-hit") ||
        element.hasAttribute("data-pathway-tooltip-hit")
      ) {
        return;
      }

      const baseStroke = parseFloat(element.getAttribute("data-base-stroke"));

      if (!Number.isFinite(baseStroke)) {
        return;
      }

      element.setAttribute("stroke-width", `${mk(baseStroke)}`);
    });

    overlay.querySelectorAll("#pathways-svg [data-base-dash]").forEach((element) => {
      const baseDash = element.getAttribute("data-base-dash");

      if (!baseDash) {
        return;
      }

      const scaled = baseDash
        .split(",")
        .map((part) => parseFloat(part.trim()))
        .filter((value) => Number.isFinite(value))
        .map((value) => mk(value));

      if (scaled.length === 0) {
        return;
      }

      element.setAttribute("stroke-dasharray", scaled.join(" "));
    });

    const pathwayMarker = overlay.querySelector("#pathway-arrow");
    if (pathwayMarker) {
      pathwayMarker.setAttribute("markerWidth", `${mk(OVERLAY_BASE.pathwayMarkerSize)}`);
      pathwayMarker.setAttribute("markerHeight", `${mk(OVERLAY_BASE.pathwayMarkerSize)}`);
    }

    overlay
      .querySelectorAll(
        "#pathways-svg [data-pathway-end-trim], #pathways-svg [data-pathway-end-trim-start], #pathways-svg [data-pathway-end-trim-end]"
      )
      .forEach((element) => {
        if (!element.hasAttribute("data-base-x1")) {
          element.setAttribute("data-base-x1", element.getAttribute("x1") ?? "");
          element.setAttribute("data-base-y1", element.getAttribute("y1") ?? "");
          element.setAttribute("data-base-x2", element.getAttribute("x2") ?? "");
          element.setAttribute("data-base-y2", element.getAttribute("y2") ?? "");
        }

        const baseX1 = parseFloat(element.getAttribute("data-base-x1"));
        const baseY1 = parseFloat(element.getAttribute("data-base-y1"));
        const baseX2 = parseFloat(element.getAttribute("data-base-x2"));
        const baseY2 = parseFloat(element.getAttribute("data-base-y2"));

        if (
          !Number.isFinite(baseX1) ||
          !Number.isFinite(baseY1) ||
          !Number.isFinite(baseX2) ||
          !Number.isFinite(baseY2)
        ) {
          return;
        }

        const defaultTrim = parseFloat(element.getAttribute("data-pathway-end-trim"));
        const startTrimBase = Number.isFinite(defaultTrim)
          ? defaultTrim
          : parseFloat(element.getAttribute("data-pathway-end-trim-start")) || 0;
        const endTrimBase = Number.isFinite(defaultTrim)
          ? defaultTrim
          : parseFloat(element.getAttribute("data-pathway-end-trim-end")) || 0;
        const trimmed = trimSegmentEnds(
          baseX1,
          baseY1,
          baseX2,
          baseY2,
          mk(startTrimBase),
          mk(endTrimBase)
        );

        element.setAttribute("x1", `${trimmed.x1}`);
        element.setAttribute("y1", `${trimmed.y1}`);
        element.setAttribute("x2", `${trimmed.x2}`);
        element.setAttribute("y2", `${trimmed.y2}`);
      });

    // Mode glyphs (stairs bar, escalator bars, moving-walkway cross) are strokes
    // laid out along the pathway in px from its midpoint.
    overlay.querySelectorAll("#pathways-svg [data-glyph-mid-x]").forEach((stroke) => {
      const midX = parseFloat(stroke.getAttribute("data-glyph-mid-x"));
      const midY = parseFloat(stroke.getAttribute("data-glyph-mid-y"));
      const dirX = parseFloat(stroke.getAttribute("data-glyph-dir-x"));
      const dirY = parseFloat(stroke.getAttribute("data-glyph-dir-y"));
      const along = parseFloat(stroke.getAttribute("data-glyph-along"));
      const halfAlong = parseFloat(stroke.getAttribute("data-glyph-half-along"));
      const halfPerp = parseFloat(stroke.getAttribute("data-glyph-half-perp"));

      if (![midX, midY, dirX, dirY, along, halfAlong, halfPerp].every(Number.isFinite)) {
        return;
      }

      // Perpendicular to the direction, matching the server's label side.
      const perpX = -dirY;
      const perpY = dirX;
      const centerX = midX + dirX * mk(along);
      const centerY = midY + dirY * mk(along);
      const halfX = dirX * mk(halfAlong) + perpX * mk(halfPerp);
      const halfY = dirY * mk(halfAlong) + perpY * mk(halfPerp);

      stroke.setAttribute("x1", `${centerX - halfX}`);
      stroke.setAttribute("y1", `${centerY - halfY}`);
      stroke.setAttribute("x2", `${centerX + halfX}`);
      stroke.setAttribute("y2", `${centerY + halfY}`);
    });

    overlay.querySelectorAll("#pathways-svg [data-pathway-arrow-guide]").forEach((guide) => {
      const x1 = parseFloat(guide.getAttribute("x1"));
      const y1 = parseFloat(guide.getAttribute("y1"));
      const x2 = parseFloat(guide.getAttribute("x2"));
      const y2 = parseFloat(guide.getAttribute("y2"));

      if (!Number.isFinite(x1) || !Number.isFinite(y1) || !Number.isFinite(x2) || !Number.isFinite(y2)) {
        return;
      }

      const pathwayGroup = guide.closest("g");
      if (!pathwayGroup) {
        return;
      }

      pathwayGroup.querySelectorAll("[data-rail-base-offset]").forEach((rail) => {
        const baseOffset = parseFloat(rail.getAttribute("data-rail-base-offset"));

        if (!Number.isFinite(baseOffset)) {
          return;
        }

        const adjusted = parallelOffsetFromSegment(x1, y1, x2, y2, mk(baseOffset));

        rail.setAttribute("x1", `${adjusted.x1}`);
        rail.setAttribute("y1", `${adjusted.y1}`);
        rail.setAttribute("x2", `${adjusted.x2}`);
        rail.setAttribute("y2", `${adjusted.y2}`);
      });
    });

    overlay.querySelectorAll("#pathways-svg [data-pathway-elevator-box]").forEach((box) => {
      const cx = parseFloat(box.getAttribute("data-center-x"));
      const cy = parseFloat(box.getAttribute("data-center-y"));
      const baseWidth = parseFloat(
        box.getAttribute("data-base-width") ?? `${OVERLAY_BASE.pathwayElevatorBoxSize}`
      );
      const baseHeight = parseFloat(
        box.getAttribute("data-base-height") ?? `${OVERLAY_BASE.pathwayElevatorBoxSize}`
      );
      const baseStroke = parseFloat(
        box.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.pathwayElevatorBoxStroke}`
      );

      if (
        !Number.isFinite(cx) ||
        !Number.isFinite(cy) ||
        !Number.isFinite(baseWidth) ||
        !Number.isFinite(baseHeight) ||
        !Number.isFinite(baseStroke)
      ) {
        return;
      }

      // The box holds 11px text, so it does not shrink with the markers.
      const width = px(baseWidth);
      const height = px(baseHeight);
      box.setAttribute("x", `${cx - width / 2}`);
      box.setAttribute("y", `${cy - height / 2}`);
      box.setAttribute("width", `${width}`);
      box.setAttribute("height", `${height}`);
      box.setAttribute("stroke-width", `${px(baseStroke)}`);
    });

    overlay.querySelectorAll("#pathways-svg [data-pathway-elevator-text]").forEach((label) => {
      const cx = parseFloat(label.getAttribute("data-center-x"));
      const cy = parseFloat(label.getAttribute("data-center-y"));
      const baseFontSize = parseFloat(
        label.getAttribute("data-base-font-size") ?? `${OVERLAY_BASE.pathwayElevatorTextSize}`
      );

      if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(baseFontSize)) {
        return;
      }

      label.setAttribute("x", `${cx}`);
      label.setAttribute("y", `${cy}`);
      label.setAttribute("font-size", `${px(baseFontSize)}`);
    });

    overlay.querySelectorAll("#pathways-svg [data-pathway-label]").forEach((label) => {
      const midpointX = parseFloat(label.getAttribute("data-midpoint-x"));
      const midpointY = parseFloat(label.getAttribute("data-midpoint-y"));
      const offsetX = parseFloat(label.getAttribute("data-offset-x"));
      const offsetY = parseFloat(label.getAttribute("data-offset-y"));
      const rotation = parseFloat(label.getAttribute("data-rotation"));
      const baseFontSize = parseFloat(
        label.getAttribute("data-base-font-size") ?? `${OVERLAY_BASE.pathwayLabelFontSize}`
      );
      const baseStroke = parseFloat(
        label.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.pathwayLabelStrokeWidth}`
      );

      if (
        !Number.isFinite(midpointX) ||
        !Number.isFinite(midpointY) ||
        !Number.isFinite(offsetX) ||
        !Number.isFinite(offsetY) ||
        !Number.isFinite(rotation) ||
        !Number.isFinite(baseFontSize) ||
        !Number.isFinite(baseStroke)
      ) {
        return;
      }

      if (scale < OVERLAY_BASE.pathwayLabelMinScale) {
        label.setAttribute("display", "none");
        return;
      }

      label.removeAttribute("display");
      const x = midpointX + px(offsetX);
      const y = midpointY + px(offsetY);

      label.setAttribute("x", `${x}`);
      label.setAttribute("y", `${y}`);
      label.setAttribute("font-size", `${px(baseFontSize)}`);
      label.setAttribute("stroke-width", `${px(baseStroke)}`);
      label.setAttribute("transform", `rotate(${rotation}, ${x}, ${y})`);
    });

    overlay.querySelectorAll("[data-ruler-hit-area]").forEach((hitArea) => {
      const baseStroke = parseFloat(
        hitArea.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.rulerHitStroke}`
      );

      if (Number.isFinite(baseStroke)) {
        hitArea.setAttribute("stroke-width", `${px(baseStroke)}`);
      }
    });

    overlay.querySelectorAll("[data-ruler-line]").forEach((line) => {
      const baseStroke = parseFloat(
        line.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.rulerLineStroke}`
      );

      if (!Number.isFinite(baseStroke)) {
        return;
      }

      line.setAttribute("stroke-width", `${px(baseStroke)}`);

      const baseDash = line.getAttribute("data-base-dash");
      if (baseDash) {
        const scaled = baseDash
          .split(",")
          .map((part) => parseFloat(part.trim()))
          .filter((value) => Number.isFinite(value))
          .map((value) => px(value));

        if (scaled.length > 0) {
          line.setAttribute("stroke-dasharray", scaled.join(" "));
        }
      }
    });

    overlay.querySelectorAll("[data-ruler-endpoint]").forEach((endpoint) => {
      const cx = parseFloat(endpoint.getAttribute("data-center-x"));
      const cy = parseFloat(endpoint.getAttribute("data-center-y"));
      const baseRadius = parseFloat(
        endpoint.getAttribute("data-base-radius") ?? `${OVERLAY_BASE.rulerEndpointRadius}`
      );
      const baseStroke = parseFloat(
        endpoint.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.rulerEndpointStroke}`
      );

      if (
        !Number.isFinite(cx) ||
        !Number.isFinite(cy) ||
        !Number.isFinite(baseRadius) ||
        !Number.isFinite(baseStroke)
      ) {
        return;
      }

      if (
        scale >= OVERLAY_BASE.rulerEndpointHideNearOneMinScale &&
        scale <= OVERLAY_BASE.rulerEndpointHideNearOneMaxScale
      ) {
        endpoint.setAttribute("display", "none");
        return;
      }

      endpoint.removeAttribute("display");
      endpoint.setAttribute("cx", `${cx}`);
      endpoint.setAttribute("cy", `${cy}`);
      endpoint.setAttribute("r", `${px(baseRadius)}`);
      endpoint.setAttribute("stroke-width", `${px(baseStroke)}`);
    });

    overlay.querySelectorAll("[data-ruler-label]").forEach((label) => {
      const midpointX = parseFloat(label.getAttribute("data-midpoint-x"));
      const midpointY = parseFloat(label.getAttribute("data-midpoint-y"));
      const anchorX = parseFloat(label.getAttribute("data-label-anchor-x"));
      const anchorY = parseFloat(label.getAttribute("data-label-anchor-y"));
      const offsetX = parseFloat(label.getAttribute("data-label-offset-x") ?? "0");
      const offsetY = parseFloat(label.getAttribute("data-label-offset-y"));
      const baseFontSize = parseFloat(
        label.getAttribute("data-base-font-size") ?? `${OVERLAY_BASE.rulerLabelFontSize}`
      );
      const baseStroke = parseFloat(
        label.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.rulerLabelStroke}`
      );
      const hasSavedAnchor = Number.isFinite(anchorX) && Number.isFinite(anchorY);
      const labelMinScale = hasSavedAnchor
        ? OVERLAY_BASE.savedRulerLabelMinScale
        : OVERLAY_BASE.rulerLabelMinScale;

      if (
        !hasSavedAnchor &&
          (!Number.isFinite(midpointX) || !Number.isFinite(midpointY)) ||
        !Number.isFinite(offsetX) ||
        !Number.isFinite(offsetY) ||
        !Number.isFinite(baseFontSize) ||
        !Number.isFinite(baseStroke)
      ) {
        return;
      }

      if (scale < labelMinScale) {
        label.setAttribute("display", "none");
        return;
      }

      label.removeAttribute("display");
      const labelX = hasSavedAnchor ? anchorX + px(offsetX) : midpointX;
      const labelY = hasSavedAnchor ? anchorY + px(offsetY) : midpointY + px(offsetY);

      label.setAttribute("x", `${labelX}`);
      label.setAttribute("y", `${labelY}`);
      label.setAttribute("font-size", `${px(baseFontSize)}`);
      label.setAttribute("stroke-width", `${px(baseStroke)}`);
    });

    const pending = overlay.querySelector("polygon[data-cx][data-cy]");

    if (!pending) {
      return;
    }

    const cx = parseFloat(pending.dataset.cx);
    const cy = parseFloat(pending.dataset.cy);

    if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
      return;
    }

    const offX = mk(OVERLAY_BASE.pendingHalfWidth);
    const offY = mk(OVERLAY_BASE.pendingHeightAbove);
    const bottomOffsetY = mk(OVERLAY_BASE.pendingHeightBelow);

    pending.setAttribute(
      "points",
      `${cx},${cy - offY} ${cx - offX},${cy + bottomOffsetY} ${cx + offX},${cy + bottomOffsetY}`
    );
    pending.setAttribute("stroke-width", `${mk(OVERLAY_BASE.pendingStroke)}`);
  },

  updateViewBox() {
    const svg = this.el;
    const viewBoxStr = `${this.viewBox.x} ${this.viewBox.y} ${this.viewBox.w} ${this.viewBox.h}`;
    svg.setAttribute("viewBox", viewBoxStr);
    this.syncOverlayViewBox();
    this.scaleOverlayElements();
    this.repositionTooltipIfVisible();
    this.updateZoomLabel();
  },

  centerOnPoint(x, y) {
    this.viewBox.x = x - this.viewBox.w / 2;
    this.viewBox.y = y - this.viewBox.h / 2;
    this.clampViewBox();
    this.updateViewBox();
  },

  applyPendingCenter({consume = true} = {}) {
    if (!this._pendingCenter) return;

    if (!this.hasFiniteCenterPoint(this._pendingCenter)) {
      this._pendingCenter = null;
      return;
    }

    const {x, y} = this._pendingCenter;

    if (consume) {
      this._pendingCenter = null;
    }

    this.centerOnPoint(x, y);
  },

  applyImageDimensions() {
    const imageEl = this.el.querySelector("image");

    if (!imageEl || !this.baseW || !this.baseH) {
      return;
    }

    imageEl.setAttribute("width", this.baseW);
    imageEl.setAttribute("height", this.baseH);
  },

  updated() {
    this.refreshTooltipElements();
    this.setupTooltipListeners();
    this.setupOverlayPanZoom();
    const newKey = this.el.getAttribute("data-canvas-key");

    if (newKey !== this._canvasKey) {
      this._canvasKey = newKey;
      this.baseW = 100;
      this.baseH = 100;
      this.viewBox = { x: 0, y: 0, w: 100, h: 100 };
      this.scale = 1;
      this.currentImageHref = null;
      this.updateViewBox();
      this.syncImageDimensions(true);
    } else {
      this.applyImageDimensions();
      // LiveView patching can reset the SVG attribute to the static template viewBox.
      // Re-apply the current interactive viewBox on every update to avoid jumps.
      this.updateViewBox();
      this.syncImageDimensions(false);
    }

    this.repositionTooltipIfVisible();
    this.reconcilePendingDropAfterPatch();
  },

  syncImageDimensions(forceReset) {
    const svg = this.el;
    const imageEl = svg.querySelector("image");

    if (!imageEl) {
      this._activeImageLoadToken += 1;
      this._imageLoadInProgress = false;
      this.currentImageHref = null;
      return;
    }

    const href = imageEl.getAttribute("href");

    if (!href) {
      this._activeImageLoadToken += 1;
      this._imageLoadInProgress = false;
      this.currentImageHref = null;
      return;
    }

    if (!forceReset && href === this.currentImageHref) {
      this.applyImageDimensions();
      return;
    }

    this.currentImageHref = href;
    const loadToken = this._activeImageLoadToken + 1;
    this._activeImageLoadToken = loadToken;
    this._imageLoadInProgress = true;
    const img = new Image();

    img.onload = () => {
      if (loadToken !== this._activeImageLoadToken) {
        return;
      }

      const naturalW = img.naturalWidth || 1;
      const naturalH = img.naturalHeight || 1;

      this.baseW = 100;
      this.baseH = (naturalH / naturalW) * 100;

      this.scale = 1;
      this.viewBox = { x: 0, y: 0, w: this.baseW, h: this.baseH };
      svg.setAttribute("viewBox", `0 0 ${this.baseW} ${this.baseH}`);

      imageEl.setAttribute("width", this.baseW);
      imageEl.setAttribute("height", this.baseH);

      this.syncOverlayViewBox();
      // The plan's aspect ratio sets how the overlay fits, hence the px scale.
      this.scaleOverlayElements();
      this._imageLoadInProgress = false;
      this.applyPendingCenter();
    };

    img.onerror = () => {
      if (loadToken !== this._activeImageLoadToken) {
        return;
      }
      this._imageLoadInProgress = false;
    };

    img.src = href;
  },

  destroyed() {
    // Clean up observer
    if (this.overlayObserver) {
      this.overlayObserver.disconnect();
    }

    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }

    // Clean up pan/zoom button listener
    if (this._handlePanZoomButtonClick && this.el.parentElement) {
      this.el.parentElement.removeEventListener("click", this._handlePanZoomButtonClick);
    }

    // Clean up pan/zoom listeners
    this.el.removeEventListener("wheel", this._handleWheel);
    this.el.removeEventListener("mousedown", this._handleMouseDown);
    this.el.removeEventListener("click", this._handleCapturedClick, true);
    this.el.removeEventListener("click", this._handleCanvasClick);
    this.el.removeEventListener("gesturestart", this._handleGesture);
    this.el.removeEventListener("gesturechange", this._handleGesture);
    document.removeEventListener("mousemove", this._handleMouseMove);
    document.removeEventListener("mouseup", this._handleMouseUp);
    document.removeEventListener("keydown", this._handleDocumentKeyDown);
    this.removeOverlayPanZoom();
    this.cancelDragHold();
    this.dragging = null;
    this.pendingDrop = null;

    this.removeTooltipListeners();
    this.hideTooltip();
  }
};

export default DiagramCanvasHook;
