/**
 * MapAlignmentHook
 *
 * Owns the Map tab's alignment workspace: a Leaflet map rendered over the
 * station floorplan, wrapped in a CSS-transformable overlay the operator can
 * translate, rotate, and scale. State is purely client-side; no persistence.
 *
 * Required data-* attrs on the hook root element:
 *   data-floorplan-url       URL of the level's floorplan image
 *   data-initial-lat         decimal latitude for the initial Leaflet view
 *   data-initial-lon         decimal longitude for the initial Leaflet view
 *   data-initial-zoom        integer zoom level for the initial Leaflet view
 *
 * DOM IDs the hook interacts with (all children of the hook root):
 *   #map-alignment-leaflet       Leaflet map container
 *   #map-alignment-overlay       transformable wrapper (parent of the Leaflet container)
 *   #map-alignment-rotate-handle rotation grab target
 *   #map-alignment-scale-handle  scale grab target
 *   #map-alignment-lat-input     lat input for setView
 *   #map-alignment-lon-input     lon input for setView
 *   #map-alignment-apply-center  button that reads lat/lon inputs and calls map.setView
 *   #map-alignment-reset         button that resets the transform to identity
 */

const SCALE_MIN = 0.25;
const SCALE_MAX = 4;
const IDENTITY_TRANSFORM = Object.freeze({tx: 0, ty: 0, rotation: 0, scale: 1});

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function overlayCenter(overlay) {
  const rect = overlay.getBoundingClientRect();
  return {
    x: rect.left + rect.width / 2,
    y: rect.top + rect.height / 2
  };
}

const MapAlignmentHook = {
  mounted() {
    const L = window.L;
    if (!L) {
      console.error("MapAlignmentHook: window.L (Leaflet) is not available");
      return;
    }

    const root = this.el;
    const floorplanUrl = root.dataset.floorplanUrl;
    const initialLat = parseFloat(root.dataset.initialLat);
    const initialLon = parseFloat(root.dataset.initialLon);
    const initialZoom = parseInt(root.dataset.initialZoom, 10);

    this.floorplanUrl = floorplanUrl;

    const overlay = root.querySelector("#map-alignment-overlay");
    const leafletEl = root.querySelector("#map-alignment-leaflet");
    const rotateHandle = root.querySelector("#map-alignment-rotate-handle");
    const scaleHandle = root.querySelector("#map-alignment-scale-handle");
    const latInput = root.querySelector("#map-alignment-lat-input");
    const lonInput = root.querySelector("#map-alignment-lon-input");
    const applyCenterBtn = root.querySelector("#map-alignment-apply-center");
    const resetBtn = root.querySelector("#map-alignment-reset");

    this.overlay = overlay;
    this.rotateHandle = rotateHandle;
    this.scaleHandle = scaleHandle;
    this.latInput = latInput;
    this.lonInput = lonInput;
    this.applyCenterBtn = applyCenterBtn;
    this.resetBtn = resetBtn;

    this.transform = {...IDENTITY_TRANSFORM};

    const map = L.map(leafletEl, {
      center: [initialLat, initialLon],
      zoom: initialZoom,
      attributionControl: true,
      zoomControl: true
    });

    L.tileLayer("/map/tiles/osm-bright/{z}/{x}/{y}", {
      opacity: 0.75,
      keepBuffer: 8,
      attribution: "© OpenStreetMap contributors, © Geoapify"
    }).addTo(map);

    map.dragging.disable();

    this.leafletMap = map;

    this._rafId = requestAnimationFrame(() => {
      this._rafId = null;
      map.invalidateSize();
    });

    if (typeof ResizeObserver !== "undefined") {
      this._resizeObserver = new ResizeObserver(() => map.invalidateSize());
      this._resizeObserver.observe(leafletEl);
    }

    this._applyTransform();

    // --- Translate: pan Leaflet by pointer delta. Leaflet always loads tiles
    //     around its current center, so translation never leaves empty tiles. ---
    this._translateState = null;
    this._onOverlayPointerDown = (e) => {
      if (e.button !== undefined && e.button !== 0) return;
      if (e.target.closest(".leaflet-control-container")) return;

      this._translateState = {
        lastX: e.clientX,
        lastY: e.clientY,
        pointerId: e.pointerId
      };
      if (overlay.setPointerCapture && e.pointerId !== undefined) {
        try { overlay.setPointerCapture(e.pointerId); } catch (_) { /* ignore */ }
      }
      e.preventDefault();
      e.stopPropagation();
    };
    this._onOverlayPointerMove = (e) => {
      if (!this._translateState) return;
      const dx = e.clientX - this._translateState.lastX;
      const dy = e.clientY - this._translateState.lastY;
      this._translateState.lastX = e.clientX;
      this._translateState.lastY = e.clientY;

      const r = this.transform.rotation * Math.PI / 180;
      const s = this.transform.scale || 1;
      const cos = Math.cos(r);
      const sin = Math.sin(r);
      // Inverse-rotate viewport delta into map-pixel space, then divide by scale.
      const mapDx = (dx * cos + dy * sin) / s;
      const mapDy = (-dx * sin + dy * cos) / s;
      this.leafletMap.panBy([-mapDx, -mapDy], { animate: false });
    };
    this._onOverlayPointerUp = (e) => {
      if (!this._translateState) return;
      if (overlay.releasePointerCapture && this._translateState.pointerId !== undefined) {
        try { overlay.releasePointerCapture(this._translateState.pointerId); } catch (_) { /* ignore */ }
      }
      this._translateState = null;
    };

    overlay.addEventListener("pointerdown", this._onOverlayPointerDown, true);
    overlay.addEventListener("pointermove", this._onOverlayPointerMove);
    overlay.addEventListener("pointerup", this._onOverlayPointerUp);
    overlay.addEventListener("pointercancel", this._onOverlayPointerUp);

    // --- Rotate handle ---
    this._rotateState = null;
    this._onRotatePointerDown = (e) => {
      if (e.button !== undefined && e.button !== 0) return;
      const center = overlayCenter(overlay);
      const startAngle = Math.atan2(e.clientY - center.y, e.clientX - center.x);
      this._rotateState = {
        centerX: center.x,
        centerY: center.y,
        startAngle: startAngle,
        baseRotation: this.transform.rotation,
        pointerId: e.pointerId
      };
      if (rotateHandle.setPointerCapture && e.pointerId !== undefined) {
        try { rotateHandle.setPointerCapture(e.pointerId); } catch (_) { /* ignore */ }
      }
      e.preventDefault();
      e.stopPropagation();
    };
    this._onRotatePointerMove = (e) => {
      if (!this._rotateState) return;
      const {centerX, centerY, startAngle, baseRotation} = this._rotateState;
      const angle = Math.atan2(e.clientY - centerY, e.clientX - centerX);
      const deltaDeg = (angle - startAngle) * (180 / Math.PI);
      this.transform.rotation = baseRotation + deltaDeg;
      this._applyTransform();
    };
    this._onRotatePointerUp = (e) => {
      if (!this._rotateState) return;
      if (rotateHandle.releasePointerCapture && this._rotateState.pointerId !== undefined) {
        try { rotateHandle.releasePointerCapture(this._rotateState.pointerId); } catch (_) { /* ignore */ }
      }
      this._rotateState = null;
    };

    rotateHandle.addEventListener("pointerdown", this._onRotatePointerDown);
    rotateHandle.addEventListener("pointermove", this._onRotatePointerMove);
    rotateHandle.addEventListener("pointerup", this._onRotatePointerUp);
    rotateHandle.addEventListener("pointercancel", this._onRotatePointerUp);

    // --- Scale handle ---
    this._scaleState = null;
    this._onScalePointerDown = (e) => {
      if (e.button !== undefined && e.button !== 0) return;
      const center = overlayCenter(overlay);
      const dx = e.clientX - center.x;
      const dy = e.clientY - center.y;
      const initialDistance = Math.sqrt(dx * dx + dy * dy);
      if (!(initialDistance > 0)) return;
      this._scaleState = {
        centerX: center.x,
        centerY: center.y,
        initialDistance: initialDistance,
        baseScale: this.transform.scale,
        pointerId: e.pointerId
      };
      if (scaleHandle.setPointerCapture && e.pointerId !== undefined) {
        try { scaleHandle.setPointerCapture(e.pointerId); } catch (_) { /* ignore */ }
      }
      e.preventDefault();
      e.stopPropagation();
    };
    this._onScalePointerMove = (e) => {
      if (!this._scaleState) return;
      const {centerX, centerY, initialDistance, baseScale} = this._scaleState;
      const dx = e.clientX - centerX;
      const dy = e.clientY - centerY;
      const distance = Math.sqrt(dx * dx + dy * dy);
      const ratio = distance / initialDistance;
      this.transform.scale = clamp(baseScale * ratio, SCALE_MIN, SCALE_MAX);
      this._applyTransform();
    };
    this._onScalePointerUp = (e) => {
      if (!this._scaleState) return;
      if (scaleHandle.releasePointerCapture && this._scaleState.pointerId !== undefined) {
        try { scaleHandle.releasePointerCapture(this._scaleState.pointerId); } catch (_) { /* ignore */ }
      }
      this._scaleState = null;
    };

    scaleHandle.addEventListener("pointerdown", this._onScalePointerDown);
    scaleHandle.addEventListener("pointermove", this._onScalePointerMove);
    scaleHandle.addEventListener("pointerup", this._onScalePointerUp);
    scaleHandle.addEventListener("pointercancel", this._onScalePointerUp);

    // --- Apply center ---
    this._onApplyCenter = () => {
      const lat = parseFloat(latInput.value);
      const lon = parseFloat(lonInput.value);
      if (Number.isNaN(lat) || Number.isNaN(lon)) return;
      this.leafletMap.setView([lat, lon]);
    };
    applyCenterBtn.addEventListener("click", this._onApplyCenter);

    // --- Reset ---
    this._onReset = () => {
      this.transform = {...IDENTITY_TRANSFORM};
      this._applyTransform();
    };
    resetBtn.addEventListener("click", this._onReset);
  },

  destroyed() {
    if (this._rafId !== null && this._rafId !== undefined) {
      cancelAnimationFrame(this._rafId);
      this._rafId = null;
    }

    if (this.overlay) {
      this.overlay.removeEventListener("pointerdown", this._onOverlayPointerDown, true);
      this.overlay.removeEventListener("pointermove", this._onOverlayPointerMove);
      this.overlay.removeEventListener("pointerup", this._onOverlayPointerUp);
      this.overlay.removeEventListener("pointercancel", this._onOverlayPointerUp);
    }

    if (this.rotateHandle) {
      this.rotateHandle.removeEventListener("pointerdown", this._onRotatePointerDown);
      this.rotateHandle.removeEventListener("pointermove", this._onRotatePointerMove);
      this.rotateHandle.removeEventListener("pointerup", this._onRotatePointerUp);
      this.rotateHandle.removeEventListener("pointercancel", this._onRotatePointerUp);
    }

    if (this.scaleHandle) {
      this.scaleHandle.removeEventListener("pointerdown", this._onScalePointerDown);
      this.scaleHandle.removeEventListener("pointermove", this._onScalePointerMove);
      this.scaleHandle.removeEventListener("pointerup", this._onScalePointerUp);
      this.scaleHandle.removeEventListener("pointercancel", this._onScalePointerUp);
    }

    if (this.applyCenterBtn && this._onApplyCenter) {
      this.applyCenterBtn.removeEventListener("click", this._onApplyCenter);
    }
    if (this.resetBtn && this._onReset) {
      this.resetBtn.removeEventListener("click", this._onReset);
    }

    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }

    if (this.leafletMap) {
      this.leafletMap.remove();
      this.leafletMap = null;
    }
  },

  _applyTransform() {
    if (!this.overlay) return;
    const {rotation, scale} = this.transform;
    this.overlay.style.transform = `rotate(${rotation}deg) scale(${scale})`;
  }
};

export default MapAlignmentHook;
