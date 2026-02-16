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
  pathwayVisualThinFactor: 1.4,
  iconVisualThinFactor: 1.2,
  pendingOffsetY: 1,
  pendingOffsetX: 0.75,
  pendingOffsetBottomY: 0.5,
  pendingStroke: 0.15
};

const DiagramCanvasHook = {
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

    // Set up MutationObserver to detect when overlay viewBox gets reset
    this.setupOverlayObserver();

    this.syncImageDimensions(true);
    this.scaleOverlayElements();

    svg.addEventListener("wheel", (e) => {
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
    }, { passive: false });

    svg.addEventListener("mousedown", (e) => {
      if (e.button === 1 || (e.button === 0 && e.shiftKey)) {
        this.isPanning = true;
        this.panStart = { x: e.clientX, y: e.clientY };
        svg.style.cursor = "grabbing";
        e.preventDefault();
      }
    });

    svg.addEventListener("mousemove", (e) => {
      if (this.isPanning) {
        const rect = svg.getBoundingClientRect();
        const dx = (e.clientX - this.panStart.x) / rect.width * this.viewBox.w;
        const dy = (e.clientY - this.panStart.y) / rect.height * this.viewBox.h;
        this.viewBox.x -= dx;
        this.viewBox.y -= dy;
        this.panStart = { x: e.clientX, y: e.clientY };
        this.clampViewBox();
        this.updateViewBox();
      }
    });

    svg.addEventListener("mouseup", () => {
      this.isPanning = false;
      svg.style.cursor = "crosshair";
    });

    svg.addEventListener("mouseleave", () => {
      this.isPanning = false;
      svg.style.cursor = "crosshair";
    });

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

    svg.addEventListener("gesturestart", (e) => e.preventDefault());
    svg.addEventListener("gesturechange", (e) => e.preventDefault());
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
          }
        }
        // Also watch for child changes (stream updates)
        if (mutation.type === "childList") {
          this.syncOverlayViewBox();
          this.scaleOverlayElements();
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

    overlay.querySelectorAll("#pathways-svg [data-pathway-hit]").forEach((hitTarget) => {
      const baseStroke = parseFloat(
        hitTarget.getAttribute("data-base-stroke") ?? `${OVERLAY_BASE.pathwayHitStroke}`
      );

      if (!Number.isFinite(baseStroke)) {
        return;
      }

      hitTarget.setAttribute("stroke-width", `${baseStroke / scale}`);
    });

    overlay.querySelectorAll("#pathways-svg [data-base-stroke]").forEach((element) => {
      if (element.hasAttribute("data-pathway-hit")) {
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
        !Number.isFinite(baseFontSize) ||
        !Number.isFinite(baseStroke)
      ) {
        return;
      }

      label.setAttribute("x", `${midpointX + offsetX / scale}`);
      label.setAttribute("y", `${midpointY + offsetY / scale}`);
      label.setAttribute("font-size", `${baseFontSize / scale}`);
      label.setAttribute("stroke-width", `${baseStroke / pathwayScale}`);
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
  }
};

export default DiagramCanvasHook;
