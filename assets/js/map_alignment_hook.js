/**
 * MapAlignmentHook
 *
 * Owns the Map tab's alignment workspace. The map is the fixed reference
 * frame (north-up, no zoom/pan/rotate by the user). The floorplan sits on
 * top inside a CSS-transformable wrapper that the operator can translate,
 * rotate, and scale to match real-world building geometry below.
 * State is purely client-side; no persistence.
 *
 * Required data-* attrs on the hook root element:
 *   data-floorplan-url       URL of the level's floorplan image
 *   data-initial-lat         decimal latitude for the initial map view
 *   data-initial-lon         decimal longitude for the initial map view
 *   data-initial-zoom        integer zoom level for the initial map view
 *
 * DOM IDs the hook interacts with:
 *   #map-alignment-leaflet       Leaflet map container (base layer, fixed)
 *   #map-alignment-overlay       transformable wrapper containing the floorplan
 *   #map-alignment-rotate-handle rotation grab target
 *   #map-alignment-scale-handle  scale grab target
 *   #map-alignment-lat-input     lat input for map.setView
 *   #map-alignment-lon-input     lon input for map.setView
 *   #map-alignment-apply-center  button that recenters the map on lat/lon
 *   #map-alignment-opacity       range input controlling floorplan opacity
 */

const SCALE_MIN = 0.25;
const SCALE_MAX = 4;
const IDENTITY_TRANSFORM = Object.freeze({tx: 0, ty: 0, rotation: 0, scale: 1});

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function readSavedAlignment(root) {
  const centerLat = parseFloat(root.dataset.alignCenterLat);
  const centerLon = parseFloat(root.dataset.alignCenterLon);
  const scaleMpp = parseFloat(root.dataset.alignScaleMpp);
  const rotationDeg = parseFloat(root.dataset.alignRotationDeg);
  if (
    !Number.isFinite(centerLat) ||
    !Number.isFinite(centerLon) ||
    !Number.isFinite(scaleMpp) ||
    !Number.isFinite(rotationDeg) ||
    scaleMpp <= 0
  ) {
    return null;
  }
  return {centerLat, centerLon, scaleMpp, rotationDeg};
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
    const initialLat = parseFloat(root.dataset.initialLat);
    const initialLon = parseFloat(root.dataset.initialLon);
    const initialZoom = parseInt(root.dataset.initialZoom, 10);

    // Optional saved alignment. All four attrs must be present and parse to
    // finite numbers; otherwise treat as absent and fall back to identity.
    const savedAlignment = readSavedAlignment(root);
    console.info(
      savedAlignment
        ? "MapAlignment: mounted with saved alignment"
        : "MapAlignment: mounted with no saved alignment",
      savedAlignment || {}
    );

    const overlay = root.querySelector("#map-alignment-overlay");
    const leafletEl = root.querySelector("#map-alignment-leaflet");
    const rotateHandle = root.querySelector("#map-alignment-rotate-handle");
    const scaleHandle = root.querySelector("#map-alignment-scale-handle");
    const latInput = document.getElementById("map-alignment-lat-input");
    const lonInput = document.getElementById("map-alignment-lon-input");
    const applyCenterBtn = document.getElementById("map-alignment-apply-center");
    const opacitySlider = document.getElementById("map-alignment-opacity");
    const zoomSlider = document.getElementById("map-alignment-zoom");
    const saveBtn = document.getElementById("map-alignment-save");
    const applyBtn = document.getElementById("map-alignment-apply");

    this.overlay = overlay;
    this.leafletEl = leafletEl;
    this.rotateHandle = rotateHandle;
    this.scaleHandle = scaleHandle;
    this.latInput = latInput;
    this.lonInput = lonInput;
    this.applyCenterBtn = applyCenterBtn;
    this.opacitySlider = opacitySlider;
    this.zoomSlider = zoomSlider;
    this.saveBtn = saveBtn;
    this.applyBtn = applyBtn;

    overlay.style.opacity = opacitySlider ? opacitySlider.value : "0.6";

    this.transform = {...IDENTITY_TRANSFORM};

    const mapCenterLat = savedAlignment ? savedAlignment.centerLat : initialLat;
    const mapCenterLon = savedAlignment ? savedAlignment.centerLon : initialLon;

    // If LiveView reused a container that already had Leaflet initialized
    // (e.g., the previous hook's destroyed() did not run before re-mount),
    // Leaflet will throw "Map container is already initialized." Reset the
    // internal flag and clear any child DOM before creating a new map.
    if (leafletEl._leaflet_id) {
      leafletEl._leaflet_id = undefined;
      leafletEl.innerHTML = "";
    }

    const map = L.map(leafletEl, {
      center: [mapCenterLat, mapCenterLon],
      zoom: initialZoom,
      minZoom: initialZoom,
      attributionControl: true,
      zoomControl: false,
      scrollWheelZoom: false,
      doubleClickZoom: false,
      touchZoom: false,
      keyboard: false,
      dragging: false,
      boxZoom: false,
      zoomAnimation: false,
      zoomSnap: 0.5
    });

    // Esri World Imagery: free aerial tiles, no API key. URL uses z/y/x
    // (note: y before x). Goes direct from the browser — no credential to hide.
    L.tileLayer(
      "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
      {
        keepBuffer: 8,
        maxNativeZoom: 19,
        maxZoom: 22,
        updateWhenIdle: false,
        updateWhenZooming: true,
        attribution: "Imagery © Esri, Maxar, Earthstar Geographics"
      }
    ).addTo(map);

    // Transparent reference layer with roads and road names tuned to overlay
    // on World_Imagery.
    L.tileLayer(
      "https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}",
      {
        keepBuffer: 8,
        maxNativeZoom: 19,
        maxZoom: 22,
        updateWhenIdle: false,
        updateWhenZooming: true,
        attribution: "Roads © Esri"
      }
    ).addTo(map);

    this.leafletMap = map;

    this._pinsRoot = root.querySelector("#map-alignment-pins");
    this._childStops = [];
    this._onMapViewChanged = () => this._positionPins();
    map.on("move", this._onMapViewChanged);
    map.on("zoom", this._onMapViewChanged);
    map.on("viewreset", this._onMapViewChanged);
    map.on("resize", this._onMapViewChanged);
    this.handleEvent("set_child_stops", (payload) => this._renderChildStops(payload));
    this.pushEvent("map_ready", {});

    if (zoomSlider) {
      zoomSlider.min = String(map.getMinZoom());
      zoomSlider.max = String(map.getMaxZoom());
      zoomSlider.value = String(map.getZoom());

      this._onZoomSliderInput = (e) => {
        const target = parseFloat(e.target.value);
        if (!Number.isFinite(target)) return;
        const current = map.getZoom();
        if (target === current) return;

        // Pin the floorplan to the map through the zoom: keep its center at
        // the same world lat/lon, and scale by 2^Δzoom so it tracks the tiles.
        const canvasRect = this.el.getBoundingClientRect();
        const canvasW = canvasRect.width;
        const canvasH = canvasRect.height;
        const oldCx = canvasW / 2 + this.transform.tx;
        const oldCy = canvasH / 2 + this.transform.ty;
        const worldCenter = map.containerPointToLatLng([oldCx, oldCy]);
        const scaleFactor = Math.pow(2, target - current);

        map.setZoom(target, {animate: false});

        const newCenterPt = map.latLngToContainerPoint(worldCenter);
        this.transform.tx = newCenterPt.x - canvasW / 2;
        this.transform.ty = newCenterPt.y - canvasH / 2;
        this.transform.scale = this.transform.scale * scaleFactor;
        this._applyTransform();
      };
      zoomSlider.addEventListener("input", this._onZoomSliderInput);

      this._onZoomEnd = () => {
        zoomSlider.value = String(map.getZoom());
      };
      map.on("zoomend", this._onZoomEnd);
    }

    this._fetchBuildings(mapCenterLat, mapCenterLon);

    if (savedAlignment) {
      this._scheduleAlignmentRestore(savedAlignment);
    }

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

    // --- Translate: drag the floorplan overlay. CSS translate is safe here
    //     because the overlay is a single <img>, not a Leaflet tile grid. ---
    this._translateState = null;
    this._onOverlayPointerDown = (e) => {
      if (e.button !== undefined && e.button !== 0) return;

      this._translateState = {
        startX: e.clientX,
        startY: e.clientY,
        baseTx: this.transform.tx,
        baseTy: this.transform.ty,
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
      const dx = e.clientX - this._translateState.startX;
      const dy = e.clientY - this._translateState.startY;
      this.transform.tx = this._translateState.baseTx + dx;
      this.transform.ty = this._translateState.baseTy + dy;
      this._applyTransform();
    };
    this._onOverlayPointerUp = (e) => {
      if (!this._translateState) return;
      if (overlay.releasePointerCapture && this._translateState.pointerId !== undefined) {
        try { overlay.releasePointerCapture(this._translateState.pointerId); } catch (_) { /* ignore */ }
      }
      this._translateState = null;
    };

    overlay.addEventListener("pointerdown", this._onOverlayPointerDown);
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

    // --- Apply center: recenter the base map on the typed lat/lon ---
    this._onApplyCenter = () => {
      const lat = parseFloat(latInput.value);
      const lon = parseFloat(lonInput.value);
      if (Number.isNaN(lat) || Number.isNaN(lon)) return;

      const canvasRect = this.el.getBoundingClientRect();
      const cxBefore = canvasRect.width / 2 + this.transform.tx;
      const cyBefore = canvasRect.height / 2 + this.transform.ty;
      const worldCenter = this.leafletMap.containerPointToLatLng([cxBefore, cyBefore]);

      this.leafletMap.setView([lat, lon], this.leafletMap.getZoom(), { animate: false });

      const newPt = this.leafletMap.latLngToContainerPoint(worldCenter);
      this.transform.tx = newPt.x - canvasRect.width / 2;
      this.transform.ty = newPt.y - canvasRect.height / 2;
      this._applyTransform();

      this._fetchBuildings(lat, lon);
    };
    applyCenterBtn.addEventListener("click", this._onApplyCenter);

    // --- Opacity slider: controls floorplan overlay opacity ---
    if (opacitySlider) {
      this._onOpacityInput = (e) => {
        this.overlay.style.opacity = e.target.value;
      };
      opacitySlider.addEventListener("input", this._onOpacityInput);
    }

    // --- Save: compute canonical alignment and push to server ---
    if (saveBtn) {
      this._onSave = () => {
        const payload = this._computeAlignment();
        if (!payload) return;
        this.pushEvent("save_alignment", payload);
      };
      saveBtn.addEventListener("click", this._onSave);
    }

    // --- Apply: push image natural size once, and forward apply clicks ---
    this._sentNaturalSize = false;
    const img = overlay ? overlay.querySelector("img") : null;
    this._naturalSizeImg = img;
    const pushNaturalSize = () => {
      if (this._sentNaturalSize) return;
      if (!img || !img.naturalWidth || !img.naturalHeight) return;
      this._sentNaturalSize = true;
      this.pushEvent("set_image_natural_size", {
        w: img.naturalWidth,
        h: img.naturalHeight
      });
    };
    if (img) {
      if (img.complete && img.naturalWidth > 0) {
        pushNaturalSize();
      } else {
        this._onImgNaturalLoad = pushNaturalSize;
        img.addEventListener("load", this._onImgNaturalLoad);
      }
    }

    if (applyBtn) {
      this._onApply = () => {
        const payload = this._computeAlignment();
        if (!payload) return;
        this.pushEvent("save_and_apply_alignment", payload);
      };
      applyBtn.addEventListener("click", this._onApply);
    }
  },

  destroyed() {
    console.info("MapAlignment: destroyed", {id: this.el && this.el.id});
    if (this._rafId !== null && this._rafId !== undefined) {
      cancelAnimationFrame(this._rafId);
      this._rafId = null;
    }
    if (this._postTransitionTimer) {
      clearTimeout(this._postTransitionTimer);
      this._postTransitionTimer = null;
    }
    if (this._onRestoreImgLoad && this.overlay) {
      const img = this.overlay.querySelector("img");
      if (img) img.removeEventListener("load", this._onRestoreImgLoad);
      this._onRestoreImgLoad = null;
    }
    if (this._restoreObserver) {
      this._restoreObserver.disconnect();
      this._restoreObserver = null;
    }

    if (this.overlay) {
      this.overlay.removeEventListener("pointerdown", this._onOverlayPointerDown);
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
    if (this.opacitySlider && this._onOpacityInput) {
      this.opacitySlider.removeEventListener("input", this._onOpacityInput);
    }
    if (this.saveBtn && this._onSave) {
      this.saveBtn.removeEventListener("click", this._onSave);
    }
    if (this.applyBtn && this._onApply) {
      this.applyBtn.removeEventListener("click", this._onApply);
    }
    if (this._naturalSizeImg && this._onImgNaturalLoad) {
      this._naturalSizeImg.removeEventListener("load", this._onImgNaturalLoad);
      this._onImgNaturalLoad = null;
      this._naturalSizeImg = null;
    }

    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }

    if (this.zoomSlider && this._onZoomSliderInput) {
      this.zoomSlider.removeEventListener("input", this._onZoomSliderInput);
      this._onZoomSliderInput = null;
    }

    if (this.leafletMap && this._onZoomEnd) {
      try { this.leafletMap.off("zoomend", this._onZoomEnd); } catch (_) {}
    }
    this._onZoomEnd = null;

    if (this.leafletMap && this._onMapViewChanged) {
      try {
        this.leafletMap.off("move", this._onMapViewChanged);
        this.leafletMap.off("zoom", this._onMapViewChanged);
        this.leafletMap.off("viewreset", this._onMapViewChanged);
        this.leafletMap.off("resize", this._onMapViewChanged);
      } catch (_) {}
    }
    this._onMapViewChanged = null;
    if (this._pinsRoot) this._pinsRoot.innerHTML = "";
    this._pinsRoot = null;
    this._childStops = null;

    if (this.leafletMap) {
      // If LiveView has already re-mounted another hook on the same container,
      // Leaflet's `remove()` will throw because the container's _leaflet_id
      // now belongs to the new instance. Swallow — there's nothing to tear
      // down that the new instance doesn't already own.
      try {
        this.leafletMap.remove();
      } catch (_) { /* container reused by newer instance */ }
      this.leafletMap = null;
    }
  },

  _computeAlignment() {
    const overlay = this.overlay;
    const map = this.leafletMap;
    if (!overlay || !map) return null;

    const img = overlay.querySelector("img");
    if (!img || !img.complete || !img.naturalWidth || !img.naturalHeight) {
      console.warn("MapAlignmentHook: floorplan image not loaded; skipping save");
      return null;
    }

    // #map-canvas bounds are the same as the Leaflet container's; overlay is
    // inset-0, so the overlay's untransformed center coincides with the
    // canvas center in container coords.
    const canvasRect = this.el.getBoundingClientRect();
    const canvasW = canvasRect.width;
    const canvasH = canvasRect.height;

    const {tx, ty, scale} = this.transform;
    // translate(tx, ty) rotate(r) scale(s) around transform-origin: center
    // Rotation and scale are pinned to the overlay center, so they leave the
    // center fixed. Only translate moves it.
    const cx = canvasW / 2 + tx;
    const cy = canvasH / 2 + ty;

    const centerLatLng = map.containerPointToLatLng([cx, cy]);

    // Meters per canvas pixel at the overlay center.
    const p0 = map.containerPointToLatLng([cx, cy]);
    const p1 = map.containerPointToLatLng([cx + 1, cy]);
    const metersPerCanvasPx = map.distance(p0, p1);

    // object-contain rendered width of the image inside the overlay.
    const imgAspect = img.naturalWidth / img.naturalHeight;
    const canvasAspect = canvasW / canvasH;
    const containWidth =
      canvasAspect > imgAspect ? canvasH * imgAspect : canvasW;
    const renderedPxPerImagePx = (containWidth / img.naturalWidth) * scale;
    // scale_mpp = meters per natural image pixel.
    //   (m / canvas_px) × (canvas_px / natural_px) = m / natural_px
    const scaleMpp = metersPerCanvasPx * renderedPxPerImagePx;

    console.info("MapAlignment: computed save payload", {
      canvasW,
      canvasH,
      tx,
      ty,
      userScale: scale,
      metersPerCanvasPx,
      containWidth,
      imageNaturalWidth: img.naturalWidth,
      renderedPxPerImagePx,
      scaleMpp,
      mapZoom: map.getZoom(),
      mapCenter: map.getCenter()
    });

    return {
      center_lat: centerLatLng.lat,
      center_lon: centerLatLng.lng,
      scale_mpp: scaleMpp,
      rotation_deg: this.transform.rotation
    };
  },

  _scheduleAlignmentRestore(savedAlignment) {
    const overlay = this.overlay;
    if (!overlay) return;
    const img = overlay.querySelector("img");
    if (!img) return;

    const STABLE_MS = 250;
    let settleTimer = null;

    const cleanup = () => {
      if (settleTimer) {
        clearTimeout(settleTimer);
        settleTimer = null;
      }
      if (this._restoreObserver) {
        this._restoreObserver.disconnect();
        this._restoreObserver = null;
      }
      if (this._onRestoreImgLoad) {
        img.removeEventListener("load", this._onRestoreImgLoad);
        this._onRestoreImgLoad = null;
      }
    };

    // Run restore once canvas size has been stable for STABLE_MS.
    // During the immersive CSS transition the canvas grows over ~300ms; running
    // mid-animation produces a scale tuned to a smaller canvas.
    const scheduleRestore = () => {
      const rect = this.el.getBoundingClientRect();
      const imgReady = img.complete && img.naturalWidth > 0;
      if (!imgReady || !(rect.width > 0) || !(rect.height > 0)) return;

      if (settleTimer) clearTimeout(settleTimer);
      settleTimer = setTimeout(() => {
        settleTimer = null;
        this._restoreAlignment(savedAlignment, img);
        cleanup();
      }, STABLE_MS);
    };

    // Try immediately.
    scheduleRestore();

    // Re-try (resetting the settle timer) on every canvas resize and on image
    // load, so the final "stable" measurement wins.
    this._onRestoreImgLoad = scheduleRestore;
    img.addEventListener("load", this._onRestoreImgLoad);

    if (typeof ResizeObserver !== "undefined") {
      this._restoreObserver = new ResizeObserver(scheduleRestore);
      this._restoreObserver.observe(this.el);
    }
  },

  _restoreAlignment(savedAlignment, img) {
    const map = this.leafletMap;
    if (!map || !img || !img.naturalWidth || !img.naturalHeight) {
      console.warn("MapAlignment: restore skipped, map or image not ready");
      return;
    }

    const canvasRect = this.el.getBoundingClientRect();
    const canvasW = canvasRect.width;
    const canvasH = canvasRect.height;
    if (!(canvasW > 0) || !(canvasH > 0)) {
      console.warn("MapAlignment: restore skipped, canvas has zero size", {canvasW, canvasH});
      return;
    }

    const cx = canvasW / 2;
    const cy = canvasH / 2;
    const p0 = map.containerPointToLatLng([cx, cy]);
    const p1 = map.containerPointToLatLng([cx + 1, cy]);
    const metersPerCanvasPx = map.distance(p0, p1);

    const imgAspect = img.naturalWidth / img.naturalHeight;
    const canvasAspect = canvasW / canvasH;
    const containWidth =
      canvasAspect > imgAspect ? canvasH * imgAspect : canvasW;
    if (!(containWidth > 0)) return;

    // Inverse of _computeAlignment: R = s_nat / (m / canvas_px).
    const renderedPxPerImagePxNeeded = savedAlignment.scaleMpp / metersPerCanvasPx;
    const scale = renderedPxPerImagePxNeeded / (containWidth / img.naturalWidth);

    console.info("MapAlignment: restored", {
      savedAlignment,
      canvasW,
      canvasH,
      metersPerCanvasPx,
      containWidth,
      imageNaturalWidth: img.naturalWidth,
      computedScale: scale
    });

    this.transform = {
      tx: 0,
      ty: 0,
      rotation: savedAlignment.rotationDeg,
      scale: scale
    };
    this._applyTransform();
  },

  _applyTransform() {
    if (!this.overlay) return;
    const {tx, ty, rotation, scale} = this.transform;
    if (tx === 0 && ty === 0 && rotation === 0 && scale === 1) {
      this.overlay.style.transform = "none";
    } else {
      this.overlay.style.transform =
        `translate(${tx}px, ${ty}px) rotate(${rotation}deg) scale(${scale})`;
    }
  },

  _fetchBuildings(lat, lon) {
    const L = window.L;
    if (!L) return;

    if (this._buildingsLayer && this.leafletMap) {
      this.leafletMap.removeLayer(this._buildingsLayer);
      this._buildingsLayer = null;
    }

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
  },

  _renderChildStops({stops}) {
    const received = (stops || []).length;
    if (!this._pinsRoot) {
      console.warn("MapAlignment: set_child_stops received but no #map-alignment-pins root", {received});
      return;
    }

    this._childStops = (stops || []).filter(
      (s) => Number.isFinite(s.lat) && Number.isFinite(s.lon)
    );

    console.info("MapAlignment: rendering child-stop pins", {
      received,
      rendered: this._childStops.length,
      sample: this._childStops[0] || null
    });

    this._pinsRoot.innerHTML = "";
    this._childStops.forEach((s) => {
      const pin = document.createElement("div");
      pin.className =
        "map-pin absolute -translate-x-1/2 -translate-y-1/2 group pointer-events-auto";
      pin.style.width = "10px";
      pin.style.height = "10px";

      const dot = document.createElement("div");
      dot.className = "w-full h-full rounded-full bg-white border border-black";
      pin.appendChild(dot);

      const tip = document.createElement("div");
      tip.className =
        "absolute left-1/2 bottom-full mb-1 -translate-x-1/2 whitespace-nowrap rounded bg-black/80 text-white text-xs px-1.5 py-0.5 opacity-0 group-hover:opacity-100 pointer-events-none";
      tip.textContent = stopTooltipLabel(s);
      pin.appendChild(tip);

      this._pinsRoot.appendChild(pin);
      s._el = pin;
    });

    this._positionPins();
  },

  _positionPins() {
    if (!this._pinsRoot || !this.leafletMap || !this._childStops) return;
    this._childStops.forEach((s) => {
      if (!s._el) return;
      const pt = this.leafletMap.latLngToContainerPoint([s.lat, s.lon]);
      s._el.style.left = `${pt.x}px`;
      s._el.style.top = `${pt.y}px`;
    });
  }
};

function stopTooltipLabel(s) {
  const name = s.stop_name || s.stop_id || "";
  const platform = s.platform_code ? ` · Plat ${s.platform_code}` : "";
  return escapeHtml(name + platform);
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export default MapAlignmentHook;
