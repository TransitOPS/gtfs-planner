/**
 * DiagramCanvas Hook
 * Provides pan and zoom functionality for the station diagram SVG canvas.
 */
const OVERLAY_BASE = {
  circleR: 0.6,
  hitTargetSize: 3.5,
  rectUprightW: 1.0,
  rectUprightH: 2.0,
  rectSquareSize: 1.2,
  rectBottomAnchorRatio: 0.8,
  rectStroke: 0.12,
  entranceStroke: 0.16,
  rectRx: 0.2,
  stopLabelFontSize: 0.72,
  stopLabelStrokeWidth: 0.17,
  stopLabelMinScale: 1.1,
  pathwayLabelMinScale: 1.1,
  crossLevelStairsSize: 0.9,
  crossLevelStairsStepUnit: 0.3,
  crossLevelElevatorHalfHeight: 0.45,
  crossLevelElevatorHalfWidth: 0.35,
  crossLevelElevatorGap: 0.05,
  pathwayStroke: 0.30,
  pathwayHitStroke: 2,
  pathwayTickStroke: 0.26,
  pathwayBarStroke: 0.5,
  pathwayConnectorStroke: 0.26,
  pathwayLabelFontSize: 0.78,
  pathwayLabelStrokeWidth: 0.2,
  pathwayMarkerSize: 1.5,
  pathwayElevatorBoxWidth: 1,
  pathwayElevatorBoxHeight: 1,
  pathwayElevatorBoxStroke: 0.30,
  pathwayElevatorTextSize: 0.275,
  rulerLineStroke: 0.25,
  rulerEndpointRadius: 0.35,
  rulerEndpointStroke: 0.13,
  rulerLabelFontSize: 0.72,
  rulerLabelStroke: 0.16,
  rulerLabelMinScale: 0.85,
  savedRulerLabelMinScale: 2,
  rulerEndpointHideNearOneMinScale: 0.9,
  rulerEndpointHideNearOneMaxScale: 1.1,
  pathwayVisualThinFactor: 1.8,
  iconVisualThinFactor: 1.2,
  pendingOffsetY: 1,
  pendingOffsetX: 0.75,
  pendingOffsetBottomY: 0.5,
  pendingStroke: 0.15
};

const TOOLTIP_POINTER_OFFSET = 12;
const TOOLTIP_VIEWPORT_PADDING = 8;
const DRAG_HOLD_MS = 200;
const DRAG_THRESHOLD_UNITS = 2;
const PAN_FRACTION = 0.25;
const ZOOM_FACTOR = 1.5;

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

const DiagramCanvasHook = {
  rulerEndpointVisualScale(scale) {
    const safeScale = Number.isFinite(scale) && scale > 0 ? scale : 1;

    if (safeScale >= 1) {
      // Slightly slim endpoints when zoomed in, especially around ~2x.
      const zoomInBoost = Math.min(safeScale - 1, 1) * 0.4;
      return safeScale + zoomInBoost;
    }

    // Keep scale endpoints smaller when zoomed out, with extra slimming in
    // the mid-zoom range where markers otherwise appear visually heavy.
    const baseShrink = 1 + (1 - safeScale) * 0.8;
    const midZoomBoost = safeScale >= 0.65 ? (1 - safeScale) * 0.6 : 0;

    return baseShrink + midZoomBoost;
  },

  iconVisualScale(scale) {
    const safeScale = Number.isFinite(scale) && scale > 0 ? scale : 1;

    if (safeScale >= 1) {
      return safeScale;
    }

    const zoomAdjusted = 1 - (1 - safeScale) * 0.3;

    // Keep icons from becoming visually chunky when zoomed out.
    return zoomAdjusted * OVERLAY_BASE.iconVisualThinFactor;
  },

  pathwayVisualScale(scale) {
    const safeScale = Number.isFinite(scale) && scale > 0 ? scale : 1;

    // Keep pathway stroke rendering fixed on-screen instead of varying with zoom.
    // Apply a constant thin factor so lines are consistently lighter.
    return safeScale * OVERLAY_BASE.pathwayVisualThinFactor;
  },

  pathwayLabelVisualScale(scale) {
    const safeScale = Number.isFinite(scale) && scale > 0 ? scale : 1;

    if (safeScale >= 1) {
      return safeScale;
    }

    // When zoomed out, keep labels a bit tighter and smaller than strict 1/scale.
    return safeScale + (1 - safeScale) * 0.4;
  },

  pathwayLabelOffsetScale(scale) {
    const safeScale = Number.isFinite(scale) && scale > 0 ? scale : 1;

    if (safeScale >= 1) {
      return safeScale;
    }

    // Keep label offsets tighter to pathway lines when zoomed out.
    return safeScale + (1 - safeScale) * 0.7;
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

  clampSvg(value) {
    return Math.max(0, Math.min(100, value));
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

    const hitTarget = e.target.closest("[data-stop-hit-target]");
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

  handleOverlayClick(e) {
    const savedRulerGroup = e.target.closest('[data-ruler-type="saved"]');
    if (savedRulerGroup) {
      this.pushEvent("scale_line_click", {});
    }
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
      const offsetX = this.clampSvg(this.dragging.centerX + dx) - this.dragging.centerX;
      const offsetY = this.clampSvg(this.dragging.centerY + dy) - this.dragging.centerY;

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
    this.minScale = 0.5;
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

    this.tooltipEl.textContent = tooltipText.trim();
    const tooltipColor = target.getAttribute("data-tooltip-color");

    if (tooltipColor && tooltipColor.trim() !== "") {
      this.tooltipEl.style.backgroundColor = tooltipColor.trim();
      this.tooltipEl.style.borderColor = tooltipColor.trim();
    } else {
      this.tooltipEl.style.backgroundColor = "";
      this.tooltipEl.style.borderColor = "";
    }

    this.tooltipEl.style.color = "#FFFFFF";
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

  scaleOverlayElements() {
    const overlay = this.el.parentElement.querySelector("#diagram-overlay");

    if (!overlay) {
      return;
    }

    const scale = this.scale || 1;
    const iconScale = this.iconVisualScale(scale);
    const pathwayScale = this.pathwayVisualScale(scale);
    const rulerEndpointScale = this.rulerEndpointVisualScale(scale);

    overlay.querySelectorAll("[data-stop-hit-target]").forEach((hitTarget) => {
      const cx = parseFloat(hitTarget.getAttribute("data-center-x"));
      const cy = parseFloat(hitTarget.getAttribute("data-center-y"));
      const locationType = hitTarget.getAttribute("data-location-type");

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      // Compute the marker's visual center so the hit target is aligned with the dot.
      let markerCenterY = cy;

      if (locationType === "0" || locationType === "2") {
        const markerH = OVERLAY_BASE.rectUprightH / iconScale;
        markerCenterY = cy - markerH * OVERLAY_BASE.rectBottomAnchorRatio + markerH / 2;
      } else if (locationType === "4") {
        const markerSize = OVERLAY_BASE.rectSquareSize / iconScale;
        markerCenterY = cy - markerSize * OVERLAY_BASE.rectBottomAnchorRatio + markerSize / 2;
      }

      // Compute the marker's bounding box so we can clamp the hit target inside it.
      let markerTop, markerBottom, markerLeft, markerRight;

      if (locationType === "0" || locationType === "2") {
        const mw = OVERLAY_BASE.rectUprightW / iconScale;
        const mh = OVERLAY_BASE.rectUprightH / iconScale;
        markerLeft = cx - mw / 2;
        markerRight = cx + mw / 2;
        markerTop = cy - mh * OVERLAY_BASE.rectBottomAnchorRatio;
        markerBottom = markerTop + mh;
      } else if (locationType === "4") {
        const ms = OVERLAY_BASE.rectSquareSize / iconScale;
        markerLeft = cx - ms / 2;
        markerRight = cx + ms / 2;
        markerTop = cy - ms * OVERLAY_BASE.rectBottomAnchorRatio;
        markerBottom = markerTop + ms;
      } else {
        const mr = OVERLAY_BASE.circleR / iconScale;
        markerLeft = cx - mr;
        markerRight = cx + mr;
        markerTop = cy - mr;
        markerBottom = cy + mr;
      }

      // Start from hitTargetSize centered on the marker, then clamp to marker bounds.
      const rawSize = OVERLAY_BASE.hitTargetSize / scale;
      const halfRaw = rawSize / 2;

      const clampedLeft = Math.max(markerLeft, cx - halfRaw);
      const clampedRight = Math.min(markerRight, cx + halfRaw);
      const clampedTop = Math.max(markerTop, markerCenterY - halfRaw);
      const clampedBottom = Math.min(markerBottom, markerCenterY + halfRaw);

      hitTarget.setAttribute("x", `${clampedLeft}`);
      hitTarget.setAttribute("y", `${clampedTop}`);
      hitTarget.setAttribute("width", `${clampedRight - clampedLeft}`);
      hitTarget.setAttribute("height", `${clampedBottom - clampedTop}`);
    });

    overlay.querySelectorAll("[data-stop-marker]").forEach((marker) => {
      const cx = parseFloat(marker.getAttribute("data-center-x"));
      const cy = parseFloat(marker.getAttribute("data-center-y"));
      const locationType = marker.getAttribute("data-location-type");

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      if (locationType === "0" || locationType === "2") {
        const width = OVERLAY_BASE.rectUprightW / iconScale;
        const height = OVERLAY_BASE.rectUprightH / iconScale;
        marker.setAttribute("x", `${cx - width / 2}`);
        marker.setAttribute("y", `${cy - height * OVERLAY_BASE.rectBottomAnchorRatio}`);
        marker.setAttribute("width", `${width}`);
        marker.setAttribute("height", `${height}`);
        marker.setAttribute("rx", `${OVERLAY_BASE.rectRx / iconScale}`);
        const strokeWidth =
          locationType === "2" ? OVERLAY_BASE.entranceStroke : OVERLAY_BASE.rectStroke;
        marker.setAttribute("stroke-width", `${strokeWidth / iconScale}`);
        return;
      }

      if (locationType === "4") {
        const size = OVERLAY_BASE.rectSquareSize / iconScale;
        marker.setAttribute("x", `${cx - size / 2}`);
        marker.setAttribute("y", `${cy - size * OVERLAY_BASE.rectBottomAnchorRatio}`);
        marker.setAttribute("width", `${size}`);
        marker.setAttribute("height", `${size}`);
        marker.setAttribute("rx", `${OVERLAY_BASE.rectRx / iconScale}`);
        marker.setAttribute("stroke-width", `${OVERLAY_BASE.rectStroke / iconScale}`);
        return;
      }

      marker.setAttribute("cx", `${cx}`);
      marker.setAttribute("cy", `${cy}`);
      marker.setAttribute("r", `${OVERLAY_BASE.circleR / iconScale}`);
      marker.setAttribute("stroke-width", `${OVERLAY_BASE.rectStroke / iconScale}`);
    });

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
        label.getAttribute("data-base-line-height") ?? `${OVERLAY_BASE.stopLabelFontSize * 1.16}`
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

      label.removeAttribute("display");
      if (labelBox) {
        labelBox.removeAttribute("display");
      }
      const newLabelX = cx + offsetX / iconScale;
      const newLabelY = cy + offsetY / iconScale;

      label.setAttribute("x", `${newLabelX}`);
      label.setAttribute("y", `${newLabelY}`);
      label.setAttribute("font-size", `${baseFontSize / iconScale}`);
      label.setAttribute("stroke-width", `${baseStroke / iconScale}`);

      label.querySelectorAll("tspan").forEach((tspan, index) => {
        tspan.setAttribute("x", `${newLabelX}`);
        tspan.setAttribute("dy", `${index === 0 ? 0 : baseLineHeight / iconScale}`);
      });

      if (!labelBox) {
        return;
      }

      const baseWidth = parseFloat(labelBox.getAttribute("data-base-width"));
      const baseHeight = parseFloat(labelBox.getAttribute("data-base-height"));
      const basePaddingX = parseFloat(labelBox.getAttribute("data-base-padding-x"));
      const basePaddingY = parseFloat(labelBox.getAttribute("data-base-padding-y"));
      const baseBoxStroke = parseFloat(labelBox.getAttribute("data-base-stroke"));

      if (
        !Number.isFinite(baseWidth) ||
        !Number.isFinite(baseHeight) ||
        !Number.isFinite(basePaddingX) ||
        !Number.isFinite(basePaddingY) ||
        !Number.isFinite(baseBoxStroke)
      ) {
        return;
      }

      const scaledWidth = baseWidth / iconScale;
      const scaledHeight = baseHeight / iconScale;
      const scaledPaddingX = basePaddingX / iconScale;
      const scaledPaddingY = basePaddingY / iconScale;

      labelBox.setAttribute("x", `${newLabelX - scaledPaddingX}`);
      labelBox.setAttribute("y", `${newLabelY - scaledPaddingY}`);
      labelBox.setAttribute("width", `${scaledWidth}`);
      labelBox.setAttribute("height", `${scaledHeight}`);
      labelBox.setAttribute("stroke-width", `${baseBoxStroke / iconScale}`);
    });

    overlay.querySelectorAll("[data-cross-level-badge-stairs]").forEach((stairsPath) => {
      const cx = parseFloat(stairsPath.getAttribute("data-center-x"));
      const cy = parseFloat(stairsPath.getAttribute("data-center-y"));
      const offsetX = parseFloat(stairsPath.getAttribute("data-badge-offset-x"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(offsetX)) {
        return;
      }

      const s = OVERLAY_BASE.crossLevelStairsStepUnit / iconScale;
      const size = OVERLAY_BASE.crossLevelStairsSize / iconScale;
      const x0 = cx + offsetX / iconScale - size / 2;
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

      const iconCx = cx + offsetX / iconScale;
      const halfH = OVERLAY_BASE.crossLevelElevatorHalfHeight / iconScale;
      const halfW = OVERLAY_BASE.crossLevelElevatorHalfWidth / iconScale;
      const gap = OVERLAY_BASE.crossLevelElevatorGap / iconScale;

      elevPath.setAttribute(
        "d",
        `M ${iconCx} ${cy - halfH} L ${iconCx + halfW} ${cy - gap} L ${iconCx - halfW} ${cy - gap} Z M ${iconCx} ${cy + halfH} L ${iconCx + halfW} ${cy + gap} L ${iconCx - halfW} ${cy + gap} Z`
      );
    });

    overlay.querySelectorAll("[data-cross-level-badge-hit]").forEach((hitTarget) => {
      const cx = parseFloat(hitTarget.getAttribute("data-center-x"));
      const cy = parseFloat(hitTarget.getAttribute("data-center-y"));
      const offsetX = parseFloat(hitTarget.getAttribute("data-badge-offset-x"));
      const base = parseFloat(hitTarget.getAttribute("data-base-size") ?? "0.9");

      if (![cx, cy, offsetX, base].every(Number.isFinite)) {
        return;
      }

      const iconCx = cx + offsetX / iconScale;
      const size = base / iconScale;

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

      hitTarget.setAttribute("stroke-width", `${baseStroke / scale}`);
    });

    overlay.querySelectorAll("#pathways-svg [data-pathway-tooltip-hit]").forEach((hitTarget) => {
      const baseStroke = parseFloat(hitTarget.getAttribute("data-base-stroke") ?? "0.8");

      if (!Number.isFinite(baseStroke)) {
        return;
      }

      hitTarget.setAttribute("stroke-width", `${baseStroke / scale}`);
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

      element.setAttribute("stroke-width", `${baseStroke / pathwayScale}`);
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
        .map((value) => value / pathwayScale);

      if (scaled.length === 0) {
        return;
      }

      element.setAttribute("stroke-dasharray", scaled.join(" "));
    });

    const pathwayMarker = overlay.querySelector("#pathway-arrow");
    if (pathwayMarker) {
      pathwayMarker.setAttribute("markerWidth", `${OVERLAY_BASE.pathwayMarkerSize / pathwayScale}`);
      pathwayMarker.setAttribute("markerHeight", `${OVERLAY_BASE.pathwayMarkerSize / pathwayScale}`);
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
        const startTrim = startTrimBase / pathwayScale;
        const endTrim = endTrimBase / pathwayScale;
        const trimmed = trimSegmentEnds(baseX1, baseY1, baseX2, baseY2, startTrim, endTrim);

        element.setAttribute("x1", `${trimmed.x1}`);
        element.setAttribute("y1", `${trimmed.y1}`);
        element.setAttribute("x2", `${trimmed.x2}`);
        element.setAttribute("y2", `${trimmed.y2}`);
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

      pathwayGroup.querySelectorAll("[data-pathway-rail][data-rail-base-offset]").forEach((rail) => {
        const baseOffset = parseFloat(rail.getAttribute("data-rail-base-offset"));
        const baseStroke = parseFloat(rail.getAttribute("data-rail-base-stroke") ?? "0.35");

        if (!Number.isFinite(baseOffset) || !Number.isFinite(baseStroke)) {
          return;
        }

        const minCenterOffset = (baseStroke * 0.6) / pathwayScale;
        const scaledOffset = Math.abs(baseOffset) / pathwayScale;
        const dynamicOffset = Math.sign(baseOffset) * Math.max(scaledOffset, minCenterOffset);
        const adjusted = parallelOffsetFromSegment(x1, y1, x2, y2, dynamicOffset);

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
        box.getAttribute("data-base-width") ?? `${OVERLAY_BASE.pathwayElevatorBoxWidth}`
      );
      const baseHeight = parseFloat(
        box.getAttribute("data-base-height") ?? `${OVERLAY_BASE.pathwayElevatorBoxHeight}`
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

      const width = baseWidth;
      const height = baseHeight;
      box.setAttribute("x", `${cx - width / 2}`);
      box.setAttribute("y", `${cy - height / 2}`);
      box.setAttribute("width", `${width}`);
      box.setAttribute("height", `${height}`);
      box.setAttribute("stroke-width", `${baseStroke / pathwayScale}`);
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
      label.setAttribute("font-size", `${baseFontSize}`);
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
      const x = midpointX + offsetX / iconScale;
      const y = midpointY + offsetY / iconScale;

      label.setAttribute("x", `${x}`);
      label.setAttribute("y", `${y}`);
      label.setAttribute("font-size", `${baseFontSize / iconScale}`);
      label.setAttribute("stroke-width", `${baseStroke / iconScale}`);
      label.setAttribute("transform", `rotate(${rotation}, ${x}, ${y})`);
    });

    overlay.querySelectorAll("[data-ruler-line]").forEach((line) => {
      const baseStroke = parseFloat(
        line.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.rulerLineStroke}`
      );

      if (!Number.isFinite(baseStroke)) {
        return;
      }

      line.setAttribute("stroke-width", `${baseStroke / scale}`);

      const baseDash = line.getAttribute("data-base-dash");
      if (baseDash) {
        const scaled = baseDash
          .split(",")
          .map((part) => parseFloat(part.trim()))
          .filter((value) => Number.isFinite(value))
          .map((value) => value / scale);

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
      endpoint.setAttribute("r", `${baseRadius / rulerEndpointScale}`);
      endpoint.setAttribute("stroke-width", `${baseStroke / rulerEndpointScale}`);
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
      const labelX = hasSavedAnchor ? anchorX + offsetX / scale : midpointX;
      const labelY = hasSavedAnchor ? anchorY + offsetY / scale : midpointY + offsetY / scale;

      label.setAttribute("x", `${labelX}`);
      label.setAttribute("y", `${labelY}`);
      label.setAttribute("font-size", `${baseFontSize / scale}`);
      label.setAttribute("stroke-width", `${baseStroke / scale}`);
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

    const offX = OVERLAY_BASE.pendingOffsetX / scale;
    const offY = OVERLAY_BASE.pendingOffsetY / scale;
    const bottomOffsetY = OVERLAY_BASE.pendingOffsetBottomY / scale;

    pending.setAttribute(
      "points",
      `${cx},${cy - offY} ${cx - offX},${cy + bottomOffsetY} ${cx + offX},${cy + bottomOffsetY}`
    );
    pending.setAttribute("stroke-width", `${OVERLAY_BASE.pendingStroke / scale}`);
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
