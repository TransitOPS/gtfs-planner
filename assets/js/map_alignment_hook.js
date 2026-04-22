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
    // Control strip lives outside #map-canvas (siblings in the component root),
    // so resolve them from the document rather than the hook root.
    const latInput = document.getElementById("map-alignment-lat-input");
    const lonInput = document.getElementById("map-alignment-lon-input");
    const applyCenterBtn = document.getElementById("map-alignment-apply-center");
    const resetBtn = document.getElementById("map-alignment-reset");
    const opacitySlider = document.getElementById("map-alignment-opacity");

    this.overlay = overlay;
    this.leafletEl = leafletEl;
    this.rotateHandle = rotateHandle;
    this.scaleHandle = scaleHandle;
    this.latInput = latInput;
    this.lonInput = lonInput;
    this.applyCenterBtn = applyCenterBtn;
    this.resetBtn = resetBtn;
    this.opacitySlider = opacitySlider;

    leafletEl.style.opacity = opacitySlider ? opacitySlider.value : "0.6";

    this.transform = {...IDENTITY_TRANSFORM};

    const map = L.map(leafletEl, {
      center: [initialLat, initialLon],
      zoom: initialZoom,
      attributionControl: true,
      zoomControl: true
    });

    // Esri World Imagery serves free aerial tiles with no API key and
     // standard z/y/x layout (note: y before x). Goes direct from the browser
     // since there's no credential to hide server-side.
    L.tileLayer(
      "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
      {
        keepBuffer: 8,
        maxZoom: 19,
        updateWhenIdle: false,
        updateWhenZooming: true,
        attribution: "Imagery © Esri, Maxar, Earthstar Geographics"
      }
    ).addTo(map);

    map.dragging.disable();

    this.leafletMap = map;

    this._fetchBuildings(initialLat, initialLon);

    this._rafId = requestAnimationFrame(() => {
      this._rafId = null;
      map.invalidateSize();
    });
    // The immersive CSS transition runs for ~300ms after mount; invalidate
    // once more after it settles so Leaflet's tile grid matches the final size.
    this._postTransitionTimer = setTimeout(() => {
      this._postTransitionTimer = null;
      map.invalidateSize();
    }, 400);

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

    // --- Opacity slider ---
    if (opacitySlider) {
      this._onOpacityInput = (e) => {
        this.leafletEl.style.opacity = e.target.value;
      };
      opacitySlider.addEventListener("input", this._onOpacityInput);
    }
  },

  destroyed() {
    if (this._rafId !== null && this._rafId !== undefined) {
      cancelAnimationFrame(this._rafId);
      this._rafId = null;
    }
    if (this._postTransitionTimer) {
      clearTimeout(this._postTransitionTimer);
      this._postTransitionTimer = null;
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
    if (this.opacitySlider && this._onOpacityInput) {
      this.opacitySlider.removeEventListener("input", this._onOpacityInput);
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
    if (rotation === 0 && scale === 1) {
      this.overlay.style.transform = "none";
    } else {
      this.overlay.style.transform = `rotate(${rotation}deg) scale(${scale})`;
    }
  },

  _fetchBuildings(lat, lon) {
    const url = `/map/buildings?lat=${lat}&lon=${lon}&radius=500`;
    fetch(url, {credentials: "same-origin"})
      .then((res) => (res.ok ? res.json() : null))
      .then((geojson) => {
        if (!geojson || !this.leafletMap) return;
        this._buildingsLayer = L.geoJSON(geojson, {
          style: {color: "#2563eb", weight: 2, fill: false, interactive: false}
        }).addTo(this.leafletMap);
      })
      .catch(() => { /* silent: buildings overlay is optional */ });
  }
};

export default MapAlignmentHook;
