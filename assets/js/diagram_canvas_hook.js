/**
 * DiagramCanvas Hook
 * Provides pan and zoom functionality for the station diagram SVG canvas.
 */
const DiagramCanvasHook = {
  mounted() {
    const svg = this.el;
    const imageEl = svg.querySelector("image");
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

    // Load image to get natural dimensions and set viewBox accordingly
    if (imageEl) {
      const img = new Image();
      img.onload = () => {
        const naturalW = img.naturalWidth;
        const naturalH = img.naturalHeight;
        // Normalize to width 100, height proportional
        this.baseW = 100;
        this.baseH = (naturalH / naturalW) * 100;
        this.viewBox = { x: 0, y: 0, w: this.baseW, h: this.baseH };
        svg.setAttribute("viewBox", `0 0 ${this.baseW} ${this.baseH}`);
        // Update the image element dimensions to match
        imageEl.setAttribute("width", this.baseW);
        imageEl.setAttribute("height", this.baseH);
        // Update the overlay SVG if it exists
        this.syncOverlayViewBox();
      };
      img.src = imageEl.getAttribute("href");
    }

    svg.addEventListener("wheel", (e) => {
      e.preventDefault();
      if (e.ctrlKey || e.metaKey) {
        const delta = e.deltaY > 0 ? 1.1 : 0.9;
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
        const panSpeed = 0.5;
        this.viewBox.x += e.deltaX * panSpeed / this.scale;
        this.viewBox.y += e.deltaY * panSpeed / this.scale;
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
    // Re-apply viewBox to overlay after LiveView updates
    this.syncOverlayViewBox();
  },

  destroyed() {
    // Clean up observer
    if (this.overlayObserver) {
      this.overlayObserver.disconnect();
    }
  }
};

export default DiagramCanvasHook;