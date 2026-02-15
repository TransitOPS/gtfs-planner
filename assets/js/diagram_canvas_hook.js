/**
 * DiagramCanvas Hook
 * Provides pan and zoom functionality for the station diagram SVG canvas.
 */
const OVERLAY_BASE = {
  circleR: 0.6,
  hitTargetSize: 3.5,
  rectUprightW: 1.2,
  rectUprightH: 2.4,
  rectHorizW: 2.4,
  rectHorizH: 1.2,
  rectStroke: 0.12,
  entranceStroke: 0.16,
  rectRx: 0.2,
  fontSize: 1.1,
  textStrokeWidth: 0.24,
  badgeFontSize: 0.65,
  badgeStrokeWidth: 0.16,
  pathwayStroke: 0.5,
  pathwayHitStroke: 2,
  pendingOffsetY: 1,
  pendingOffsetX: 0.75,
  pendingOffsetBottomY: 0.5,
  pendingStroke: 0.15
};

const DiagramCanvasHook = {
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
        const width = OVERLAY_BASE.rectUprightW / scale;
        const height = OVERLAY_BASE.rectUprightH / scale;
        marker.setAttribute("x", `${cx - width / 2}`);
        marker.setAttribute("y", `${cy - height / 2}`);
        marker.setAttribute("width", `${width}`);
        marker.setAttribute("height", `${height}`);
        marker.setAttribute("rx", `${OVERLAY_BASE.rectRx / scale}`);
        const strokeWidth =
          locationType === "2" ? OVERLAY_BASE.entranceStroke : OVERLAY_BASE.rectStroke;
        marker.setAttribute("stroke-width", `${strokeWidth / scale}`);
        return;
      }

      if (locationType === "4") {
        const width = OVERLAY_BASE.rectHorizW / scale;
        const height = OVERLAY_BASE.rectHorizH / scale;
        marker.setAttribute("x", `${cx - width / 2}`);
        marker.setAttribute("y", `${cy - height / 2}`);
        marker.setAttribute("width", `${width}`);
        marker.setAttribute("height", `${height}`);
        marker.setAttribute("rx", `${OVERLAY_BASE.rectRx / scale}`);
        marker.setAttribute("stroke-width", `${OVERLAY_BASE.rectStroke / scale}`);
        return;
      }

      marker.setAttribute("cx", `${cx}`);
      marker.setAttribute("cy", `${cy}`);
      marker.setAttribute("r", `${OVERLAY_BASE.circleR / scale}`);
      marker.setAttribute("stroke-width", `${OVERLAY_BASE.rectStroke / scale}`);
    });

    overlay.querySelectorAll("[data-stop-label]").forEach((label) => {
      const cx = parseFloat(label.getAttribute("data-center-x"));
      const cy = parseFloat(label.getAttribute("data-center-y"));
      const offsetX = parseFloat(label.getAttribute("data-label-offset-x"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(offsetX)) {
        return;
      }

      label.setAttribute("x", `${cx + offsetX / scale}`);
      label.setAttribute("y", `${cy}`);
      label.setAttribute("font-size", `${OVERLAY_BASE.fontSize / scale}`);
      label.setAttribute("stroke-width", `${OVERLAY_BASE.textStrokeWidth / scale}`);
    });

    overlay.querySelectorAll("[data-stop-badge]").forEach((badge) => {
      const cx = parseFloat(badge.getAttribute("data-center-x"));
      const cy = parseFloat(badge.getAttribute("data-center-y"));

      if (!Number.isFinite(cx) || !Number.isFinite(cy)) {
        return;
      }

      badge.setAttribute("x", `${cx + 0.5 / scale}`);
      badge.setAttribute("y", `${cy - 0.5 / scale}`);
      badge.setAttribute("font-size", `${OVERLAY_BASE.badgeFontSize / scale}`);
      badge.setAttribute("stroke-width", `${OVERLAY_BASE.badgeStrokeWidth / scale}`);
    });

    overlay.querySelectorAll("#pathways-svg g").forEach((group) => {
      const lines = group.querySelectorAll("line");

      if (lines[0]) {
        lines[0].setAttribute("stroke-width", `${OVERLAY_BASE.pathwayHitStroke / scale}`);
      }

      if (lines[1]) {
        lines[1].setAttribute("stroke-width", `${OVERLAY_BASE.pathwayStroke / scale}`);
      }
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
