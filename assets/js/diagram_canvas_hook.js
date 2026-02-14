/**
 * DiagramCanvas Hook
 * Provides pan and zoom functionality for the station diagram SVG canvas.
 */
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

    // Set up MutationObserver to detect when overlay viewBox gets reset
    this.setupOverlayObserver();

    this.syncImageDimensions(true);

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
            // LiveView reset the viewBox, re-apply our current state
            this.syncOverlayViewBox();
          }
        }
        // Also watch for child changes (stream updates)
        if (mutation.type === "childList") {
          this.syncOverlayViewBox();
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

  updateViewBox() {
    const svg = this.el;
    const viewBoxStr = `${this.viewBox.x} ${this.viewBox.y} ${this.viewBox.w} ${this.viewBox.h}`;
    svg.setAttribute("viewBox", viewBoxStr);
    this.syncOverlayViewBox();
  },

  updated() {
    this.syncImageDimensions(false);
    this.syncOverlayViewBox();
  },

  syncImageDimensions(forceReset) {
    const svg = this.el;
    const imageEl = svg.querySelector("image");

    if (!imageEl) {
      return;
    }

    const href = imageEl.getAttribute("href");

    if (!href || (!forceReset && href === this.currentImageHref)) {
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
