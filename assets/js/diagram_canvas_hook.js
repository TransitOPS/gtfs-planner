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
  crossLevelStairsSize: 0.9,
  crossLevelStairsStepUnit: 0.3,
  crossLevelElevatorHalfHeight: 0.45,
  crossLevelElevatorHalfWidth: 0.35,
  crossLevelElevatorGap: 0.05,
  pathwayStroke: 0.35,
  pathwayHitStroke: 2,
  pathwayTickStroke: 0.3,
  pathwayBarStroke: 0.5,
  pathwayConnectorStroke: 0.3,
  pathwayLabelFontSize: 0.9,
  pathwayLabelStrokeWidth: 0.2,
  pathwayMarkerSize: 1.5,
  pathwayElevatorBoxWidth: 2,
  pathwayElevatorBoxHeight: 2,
  pathwayElevatorBoxStroke: 0.4,
  pathwayElevatorTextSize: 1.2,
  rulerLineStroke: 0.25,
  rulerEndpointRadius: 0.35,
  rulerEndpointStroke: 0.13,
  rulerLabelFontSize: 0.72,
  rulerLabelStroke: 0.16,
  rulerLabelMinScale: 0.85,
  savedRulerLabelMinScale: 2,
  rulerEndpointHideNearOneMinScale: 0.9,
  rulerEndpointHideNearOneMaxScale: 1.1,
  pathwayVisualThinFactor: 1.4,
  iconVisualThinFactor: 1.2,
  pendingOffsetY: 1,
  pendingOffsetX: 0.75,
  pendingOffsetBottomY: 0.5,
  pendingStroke: 0.15
};

const TOOLTIP_POINTER_OFFSET = 12;
const TOOLTIP_VIEWPORT_PADDING = 8;

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
    const zoomAdjusted =
      safeScale < 1
        ? 1 - (1 - safeScale) * 0.3
        : safeScale;

    // Keep pathway visuals slimmer at baseline and while zoomed out.
    return zoomAdjusted * OVERLAY_BASE.pathwayVisualThinFactor;
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
    if (e.button === 1 || (e.button === 0 && e.shiftKey)) {
      this.isPanning = true;
      this.panStart = { x: e.clientX, y: e.clientY };
      this.el.style.cursor = "grabbing";
      e.preventDefault();
    }
  },

  handleMouseMove(e) {
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

  handleMouseUp() {
    if (this.isPanning) {
      this.isPanning = false;
      this.el.style.cursor = "";
    }
  },

  handleGesture(e) {
    e.preventDefault();
  },

  setupOverlayPanZoom() {
    if (!this.overlay || this._overlayPanZoomBound === this.overlay) {
      return;
    }

    this.removeOverlayPanZoom();
    this.overlay.addEventListener("wheel", this._handleWheel, { passive: false });
    this.overlay.addEventListener("mousedown", this._handleMouseDown);
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
    this.maxScale = 5;
    this.isPanning = false;
    this.panStart = { x: 0, y: 0 };
    this._canvasKey = svg.getAttribute("data-canvas-key");
    this.currentImageHref = null;
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

    // Create bound references for proper add/remove
    this._handleWheel = this.handleWheel.bind(this);
    this._handleMouseDown = this.handleMouseDown.bind(this);
    this._handleMouseMove = this.handleMouseMove.bind(this);
    this._handleMouseUp = this.handleMouseUp.bind(this);
    this._handleGesture = this.handleGesture.bind(this);

    this.refreshTooltipElements();
    this.setupTooltipListeners();
    this.setupOverlayPanZoom();

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

    svg.addEventListener("click", (e) => {
      if (e.shiftKey) return;
      const pt = svg.createSVGPoint();
      pt.x = e.clientX;
      pt.y = e.clientY;
      const svgPt = pt.matrixTransform(svg.getScreenCTM().inverse());
      const x = Math.round(svgPt.x * 100) / 100;
      const y = Math.round(svgPt.y * 100) / 100;
      this.pushEvent("canvas_click", { x, y });
    });

    svg.addEventListener("gesturestart", this._handleGesture);
    svg.addEventListener("gesturechange", this._handleGesture);
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

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      const size = OVERLAY_BASE.hitTargetSize / scale;
      hitTarget.setAttribute("x", `${cx - size / 2}`);
      hitTarget.setAttribute("y", `${cy - size / 2}`);
      hitTarget.setAttribute("width", `${size}`);
      hitTarget.setAttribute("height", `${size}`);
    });

    overlay.querySelectorAll("[data-stop-tooltip-hit]").forEach((hitTarget) => {
      const cx = parseFloat(hitTarget.getAttribute("data-center-x"));
      const cy = parseFloat(hitTarget.getAttribute("data-center-y"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      const size = 1.8 / scale;
      hitTarget.setAttribute("x", `${cx - size / 2}`);
      hitTarget.setAttribute("y", `${cy - size / 2}`);
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

      if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(offsetX) || !Number.isFinite(offsetY)) {
        return;
      }

      if (scale < OVERLAY_BASE.stopLabelMinScale) {
        label.setAttribute("display", "none");
        return;
      }

      label.removeAttribute("display");
      const newLabelX = cx + offsetX / iconScale;
      const newLabelY = cy + offsetY / iconScale;

      label.setAttribute("x", `${newLabelX}`);
      label.setAttribute("y", `${newLabelY}`);
      label.setAttribute("font-size", `${OVERLAY_BASE.stopLabelFontSize / iconScale}`);
      label.setAttribute("stroke-width", `${OVERLAY_BASE.stopLabelStrokeWidth / iconScale}`);

      label.querySelectorAll("tspan").forEach((tspan) => {
        tspan.setAttribute("x", `${newLabelX}`);
      });
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

    overlay.querySelectorAll("[data-cross-level-badge-tooltip-hit]").forEach((hitTarget) => {
      const cx = parseFloat(hitTarget.getAttribute("data-center-x"));
      const cy = parseFloat(hitTarget.getAttribute("data-center-y"));
      const offsetX = parseFloat(hitTarget.getAttribute("data-badge-offset-x"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(offsetX)) {
        return;
      }

      const iconCx = cx + offsetX / iconScale;
      const size = 0.9 / iconScale;

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

      const width = baseWidth / scale;
      const height = baseHeight / scale;
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
      label.setAttribute("font-size", `${baseFontSize / scale}`);
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

      const x = midpointX + offsetX / scale;
      const y = midpointY + offsetY / scale;

      label.setAttribute("x", `${x}`);
      label.setAttribute("y", `${y}`);
      label.setAttribute("font-size", `${baseFontSize / scale}`);
      label.setAttribute("stroke-width", `${baseStroke / pathwayScale}`);
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
  },

  syncImageDimensions(forceReset) {
    const svg = this.el;
    const imageEl = svg.querySelector("image");

    if (!imageEl) {
      return;
    }

    const href = imageEl.getAttribute("href");

    if (!href || (!forceReset && href === this.currentImageHref)) {
      this.applyImageDimensions();
      return;
    }

    this.currentImageHref = href;
    const img = new Image();

    img.onload = () => {
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
    };

    img.src = href;
  },

  destroyed() {
    // Clean up observer
    if (this.overlayObserver) {
      this.overlayObserver.disconnect();
    }

    // Clean up pan/zoom listeners
    this.el.removeEventListener("wheel", this._handleWheel);
    this.el.removeEventListener("mousedown", this._handleMouseDown);
    this.el.removeEventListener("gesturestart", this._handleGesture);
    this.el.removeEventListener("gesturechange", this._handleGesture);
    document.removeEventListener("mousemove", this._handleMouseMove);
    document.removeEventListener("mouseup", this._handleMouseUp);
    this.removeOverlayPanZoom();

    this.removeTooltipListeners();
    this.hideTooltip();
  }
};

export default DiagramCanvasHook;
