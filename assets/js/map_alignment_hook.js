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
 *   #map-other-overlays          container root for other-level floorplan overlays
 *   #map-other-pins              container root for other-level stop pins
 *   #map-other-overlays-opacity  range input controlling other-level opacity
 */

import { createOtherLevelsLayers } from "./map_overlay_layers";
import {
  normalizeDiagramPoint,
  previewPointForDiagramCoordinate,
} from "./floorplan_preview_points";
import {
  DIAGRAM_BASE_COLOR,
  appendStopBadges,
  symbolForLocationType,
  treatmentForLocationType,
} from "./stop_icon_symbols";

const SCALE_MIN = 0.25;
const SCALE_MAX = 4;
const IDENTITY_TRANSFORM = Object.freeze({tx: 0, ty: 0, rotation: 0, scale: 1});
const MAP_ALIGNMENT_HOOK_BUILD = "map-align-fix-v2";

// Deterministic degraded-state opacity for geo-mode fallback pins (stops
// positioned from stored geography rather than the floorplan image).
const FALLBACK_PIN_OPACITY = "0.6";
// Suffix appended to fallback pin text so the visible tooltip and the
// aria-label both name the stop as map-positioned, not floorplan-positioned.
const FALLBACK_POSITION_SUFFIX = " (map position)";

// Apply-button titles. The map root is phx-update="ignore", so the hook owns
// enablement after mount; a disabled control must still explain why (ux-states).
const APPLY_ENABLED_TITLE =
  "Set lat/lon for child stops from the floorplan's current position on the map";
const APPLY_DISABLED_TITLE = "Waiting for the floorplan image to load";

// Preview status copy (operator-facing, plain language). Shown before the
// floorplan image is ready or after the active marker layer is cleared.
const PREVIEW_STATUS_NOT_READY = "Preview not ready";

// Ready-state status: front-load the two deterministic counts. Diagram-mode pins
// are anchored to the floorplan image; geo-mode pins fall back to map position.
function previewStatusText(diagramCount, geoCount) {
  return `${diagramCount} anchored to floorplan · ${geoCount} positioned from map`;
}

function shouldEnableMapAlignmentDiagnostics(root) {
  if (root?.dataset?.mapAlignmentDebugLogging === "true") return true;

  const nodeEnv =
    typeof process !== "undefined" && process?.env ? process.env.NODE_ENV : undefined;

  if (nodeEnv !== "production") return true;

  try {
    return window?.localStorage?.getItem("mapAlignmentDebug") === "1";
  } catch (_) {
    return false;
  }
}

function createMapAlignmentLogger(root) {
  const diagnosticsEnabled = shouldEnableMapAlignmentDiagnostics(root);

  return {
    warn(message, meta) {
      if (!diagnosticsEnabled) return;
      if (meta === undefined) {
        console.warn(message);
        return;
      }
      console.warn(message, meta);
    },

    error(message, meta) {
      if (meta === undefined) {
        console.error(message);
        return;
      }
      console.error(message, meta);
    }
  };
}
function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function parseAlignmentPayload(centerLatRaw, centerLonRaw, scaleMppRaw, rotationDegRaw) {
  const centerLat = parseFloat(centerLatRaw);
  const centerLon = parseFloat(centerLonRaw);
  const scaleMpp = parseFloat(scaleMppRaw);
  const rotationDeg = parseFloat(rotationDegRaw);

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

function readActiveAlignment(root) {
  return parseAlignmentPayload(
    root.dataset.alignCenterLat,
    root.dataset.alignCenterLon,
    root.dataset.alignScaleMpp,
    root.dataset.alignRotationDeg
  );
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
    const root = this.el;
    this._logger = createMapAlignmentLogger(root);

    const L = window.L;
    if (!L) {
      this._logger.error("MapAlignmentHook: window.L (Leaflet) is not available");
      return;
    }

    const initialLat = parseFloat(root.dataset.initialLat);
    const initialLon = parseFloat(root.dataset.initialLon);
    const initialZoom = parseInt(root.dataset.initialZoom, 10);

    // Optional saved alignment. All four attrs must be present and parse to
    // finite numbers; otherwise treat as absent and fall back to identity.
    const activeAlignment = readActiveAlignment(root);

    const overlay = root.querySelector("#map-alignment-overlay[data-editable-overlay='true']");
    const leafletEl = root.querySelector("#map-alignment-leaflet");
    const rotateHandle = root.querySelector(
      "#map-alignment-rotate-handle[data-edit-target-overlay='active']"
    );
    const scaleHandle = root.querySelector(
      "#map-alignment-scale-handle[data-edit-target-overlay='active']"
    );
    const latInput = document.getElementById("map-alignment-lat-input");
    const lonInput = document.getElementById("map-alignment-lon-input");
    const applyCenterBtn = document.getElementById("map-alignment-apply-center");
    const opacitySlider = document.getElementById("map-alignment-opacity");
    const zoomSlider = document.getElementById("map-alignment-zoom");
    const saveBtn = document.getElementById("map-alignment-save");
    const applyBtn = document.getElementById("map-alignment-apply");

    if (!overlay || !leafletEl || !rotateHandle || !scaleHandle) {
      this._logger.error("MapAlignmentHook: required active overlay edit elements are missing");
      return;
    }

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
    this._previewStatusEl = document.getElementById("map-alignment-preview-status");
    this._overlayRestoreDisposers = [];

    overlay.style.opacity = opacitySlider ? opacitySlider.value : "0.7";

    this.transform = {...IDENTITY_TRANSFORM};
    this._userAdjustedTransform = false;

    const mapCenterLat = activeAlignment ? activeAlignment.centerLat : initialLat;
    const mapCenterLon = activeAlignment ? activeAlignment.centerLon : initialLon;

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

    this._activePinsRoot = root.querySelector("#map-alignment-pins-active");
    this._activeChildStops = [];

    const otherOverlaysRoot = root.querySelector("#map-other-overlays");
    const otherPinsRoot = root.querySelector("#map-other-pins");
    if (otherOverlaysRoot && otherPinsRoot) {
      this._otherLevels = createOtherLevelsLayers({
        overlaysRoot: otherOverlaysRoot,
        pinsRoot: otherPinsRoot,
        applyOverlayTransform: (el, alignment) => this._applyOtherLevelOverlayTransform(el, alignment),
        projectLatLng: (lat, lon) => {
          const pt = this.leafletMap.latLngToContainerPoint([lat, lon]);
          return pt ? {x: pt.x, y: pt.y} : null;
        },
        symbolFor: symbolForLocationType
      });
      this._otherLevels.setOpacity(0.7);
    } else {
      this._otherLevels = null;
    }

    this._viewFrame = null;
    this._onMapViewChanged = () => {
      if (this._viewFrame) return;
      this._viewFrame = requestAnimationFrame(() => {
        this._viewFrame = null;
        this._positionPins();
        if (this._otherLevels) this._otherLevels.reposition();
      });
    };
    map.on("move", this._onMapViewChanged);
    map.on("zoom", this._onMapViewChanged);
    map.on("viewreset", this._onMapViewChanged);
    map.on("resize", this._onMapViewChanged);
    this.handleEvent("set_active_child_stops", (payload) => this._renderActiveChildStops(payload));
    this.handleEvent("set_other_levels", (payload) => {
      if (this._otherLevels) this._otherLevels.update(payload);
    });
    this.pushEvent("map_ready", {});

    if (zoomSlider) {
      zoomSlider.min = String(map.getMinZoom());
      zoomSlider.max = String(map.getMaxZoom());
      zoomSlider.value = String(map.getZoom());

      this._onZoomSliderInput = (e) => this._handleZoomSliderInput(e);
      zoomSlider.addEventListener("input", this._onZoomSliderInput);

      this._onZoomEnd = () => {
        zoomSlider.value = String(map.getZoom());
      };
      map.on("zoomend", this._onZoomEnd);
    }

    this._fetchBuildings(mapCenterLat, mapCenterLon);

    if (activeAlignment) {
      this._scheduleOverlayAlignmentRestore(overlay, activeAlignment, "active");
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

      this._markUserAdjusted();
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

      this._markUserAdjusted();
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

      const canvasRect = this._leafletRect();
      if (!canvasRect) return;
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

    this._syncOtherOverlaysOpacitySlider();

    // --- Save: compute canonical alignment and push to server ---
    if (saveBtn) {
      this._onSave = () => {
        this._pushAlignmentEventIfValid("save_alignment");
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
      this._positionPins();
      this._syncApplyButtonState();
      this._syncPreviewStatus();
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
        if (applyBtn.disabled) return;
        this._pushAlignmentEventIfValid("save_and_apply_alignment");
      };
      applyBtn.addEventListener("click", this._onApply);
    }

    // Own apply enablement after mount. The static markup disables the button
    // until image dims are known, but the ignored map root never receives a
    // server patch — so set the starting state here and re-sync on image load.
    this._syncApplyButtonState();
  },

  updated() {
    this._syncOtherOverlaysOpacitySlider();
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
    if (this._viewFrame) {
      cancelAnimationFrame(this._viewFrame);
      this._viewFrame = null;
    }
    if (Array.isArray(this._overlayRestoreDisposers)) {
      this._overlayRestoreDisposers.forEach((dispose) => {
        try {
          dispose();
        } catch (_) {
          // noop
        }
      });
      this._overlayRestoreDisposers = [];
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
    if (this.otherOpacitySlider && this._onOtherOpacityInput) {
      this.otherOpacitySlider.removeEventListener("input", this._onOtherOpacityInput);
      this.otherOpacitySlider = null;
      this._onOtherOpacityInput = null;
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
    this._clearPinLayers();

    if (this._otherLevels) {
      this._otherLevels.destroy();
      this._otherLevels = null;
    }

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
    const leafletEl = this.leafletEl;
    if (!overlay || !map || !leafletEl) return null;

    const img = overlay.querySelector("img");
    if (!img || !img.complete || !img.naturalWidth || !img.naturalHeight) {
      this._logger.warn("MapAlignmentHook: floorplan image not loaded; skipping save");
      return null;
    }

    // Use Leaflet container bounds for containerPoint conversions. The map
    // API expects points relative to #map-alignment-leaflet, not the hook root.
    const canvasRect = leafletEl.getBoundingClientRect();
    const canvasW = canvasRect.width;
    const canvasH = canvasRect.height;
    if (
      !Number.isFinite(canvasW) ||
      !Number.isFinite(canvasH) ||
      !(canvasW > 0) ||
      !(canvasH > 0)
    ) {
      this._logger.warn("MapAlignmentHook: invalid map geometry; skipping alignment compute", {
        canvasW,
        canvasH
      });
      return null;
    }

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

    return {
      center_lat: centerLatLng.lat,
      center_lon: centerLatLng.lng,
      scale_mpp: scaleMpp,
      rotation_deg: this.transform.rotation
    };
  },

  _scheduleOverlayAlignmentRestore(overlayEl, alignment, label) {
    if (!overlayEl || !alignment) return;

    const img = overlayEl.querySelector("img");
    if (!img) return;

    const STABLE_MS = 250;
    let settleTimer = null;
    let restoreObserver = null;
    let onRestoreImgLoad = null;
    let disposed = false;

    const cleanup = () => {
      if (disposed) return;
      disposed = true;

      if (settleTimer) {
        clearTimeout(settleTimer);
        settleTimer = null;
      }

      if (restoreObserver) {
        restoreObserver.disconnect();
        restoreObserver = null;
      }

      if (onRestoreImgLoad) {
        img.removeEventListener("load", onRestoreImgLoad);
        onRestoreImgLoad = null;
      }
    };

    if (!Array.isArray(this._overlayRestoreDisposers)) {
      this._overlayRestoreDisposers = [];
    }
    this._overlayRestoreDisposers.push(cleanup);

    // Run restore once canvas size has been stable for STABLE_MS.
    // During the immersive CSS transition the canvas grows over ~300ms; running
    // mid-animation produces a scale tuned to a smaller canvas.
    const scheduleRestore = () => {
      if (this._userAdjustedTransform) {
        cleanup();
        return;
      }

      const rect = this._leafletRect();
      const imgReady = img.complete && img.naturalWidth > 0;
      if (!imgReady || !rect || !(rect.width > 0) || !(rect.height > 0)) return;

      if (settleTimer) clearTimeout(settleTimer);
      settleTimer = setTimeout(() => {
        settleTimer = null;
        this._restoreOverlayAlignment(overlayEl, alignment, img, label);
        cleanup();
      }, STABLE_MS);
    };

    // Try immediately.
    scheduleRestore();

    // Re-try (resetting the settle timer) on every canvas resize and on image
    // load, so the final "stable" measurement wins.
    onRestoreImgLoad = scheduleRestore;
    img.addEventListener("load", onRestoreImgLoad);

    if (typeof ResizeObserver !== "undefined") {
      restoreObserver = new ResizeObserver(scheduleRestore);
      restoreObserver.observe(this.leafletEl);
    }
  },

  _restoreOverlayAlignment(overlayEl, alignment, img, label) {
    if (this._userAdjustedTransform) return;

    const map = this.leafletMap;
    if (!map || !overlayEl || !img || !img.naturalWidth || !img.naturalHeight) {
      this._logger.warn("MapAlignment: restore skipped, map or image not ready");
      return;
    }

    const canvasRect = this._leafletRect();
    if (!canvasRect) {
      this._logger.warn("MapAlignment: restore skipped, leaflet container not ready", {label});
      return;
    }
    const canvasW = canvasRect.width;
    const canvasH = canvasRect.height;
    if (!(canvasW > 0) || !(canvasH > 0)) {
      this._logger.warn("MapAlignment: restore skipped, canvas has zero size", {canvasW, canvasH});
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
    const renderedPxPerImagePxNeeded = alignment.scaleMpp / metersPerCanvasPx;
    const scale = renderedPxPerImagePxNeeded / (containWidth / img.naturalWidth);

    const alignedCenterPoint = map.latLngToContainerPoint([alignment.centerLat, alignment.centerLon]);

    const restoredTransform = {
      tx: alignedCenterPoint.x - canvasW / 2,
      ty: alignedCenterPoint.y - canvasH / 2,
      rotation: alignment.rotationDeg,
      scale: scale
    };

    this.transform = restoredTransform;
    this._applyTransform();
  },

  // Compute the CSS transform that places an alignment-described floorplan at
  // the current map view and apply it to `el`. Mirrors _restoreOverlayAlignment
  // but takes the server payload's snake_case alignment and targets the given
  // element (used by the other-levels overlay manager via injected callback).
  _applyOtherLevelOverlayTransform(el, alignment) {
    const map = this.leafletMap;
    if (!map || !el || !alignment) return;

    const img = el.tagName === "IMG" ? el : el.querySelector("img");
    if (!img || !img.naturalWidth || !img.naturalHeight) return;

    const canvasRect = this._leafletRect();
    if (!canvasRect) return;
    const canvasW = canvasRect.width;
    const canvasH = canvasRect.height;
    if (!(canvasW > 0) || !(canvasH > 0)) return;

    const cx = canvasW / 2;
    const cy = canvasH / 2;
    const p0 = map.containerPointToLatLng([cx, cy]);
    const p1 = map.containerPointToLatLng([cx + 1, cy]);
    const metersPerCanvasPx = map.distance(p0, p1);

    const imgAspect = img.naturalWidth / img.naturalHeight;
    const canvasAspect = canvasW / canvasH;
    const containWidth = canvasAspect > imgAspect ? canvasH * imgAspect : canvasW;
    if (!(containWidth > 0) || !(metersPerCanvasPx > 0)) return;

    const renderedPxPerImagePxNeeded = alignment.scale_mpp / metersPerCanvasPx;
    const scale = renderedPxPerImagePxNeeded / (containWidth / img.naturalWidth);

    const alignedCenterPoint = map.latLngToContainerPoint([
      alignment.center_lat,
      alignment.center_lon
    ]);

    this._applyOverlayTransform(el, {
      tx: alignedCenterPoint.x - canvasW / 2,
      ty: alignedCenterPoint.y - canvasH / 2,
      rotation: alignment.rotation_deg,
      scale: scale
    });
  },

  _applyOverlayTransform(overlayEl, transform) {
    if (!overlayEl || !transform) return;

    if (
      transform.tx === 0 &&
      transform.ty === 0 &&
      transform.rotation === 0 &&
      transform.scale === 1
    ) {
      overlayEl.style.transform = "none";
      return;
    }

    overlayEl.style.transform =
      `translate(${transform.tx}px, ${transform.ty}px) ` +
      `rotate(${transform.rotation}deg) scale(${transform.scale})`;
  },

  _syncOtherOverlaysOpacitySlider() {
    const nextSlider = document.getElementById("map-other-overlays-opacity");

    if (this.otherOpacitySlider && this._onOtherOpacityInput) {
      this.otherOpacitySlider.removeEventListener("input", this._onOtherOpacityInput);
      this._onOtherOpacityInput = null;
    }

    this.otherOpacitySlider = nextSlider;

    if (!this.otherOpacitySlider || !this._otherLevels) return;

    this._onOtherOpacityInput = (e) => {
      this._otherLevels.setOpacity(parseFloat(e.target.value));
    };

    this.otherOpacitySlider.addEventListener("input", this._onOtherOpacityInput);
    this._otherLevels.setOpacity(parseFloat(this.otherOpacitySlider.value) || 0.7);
  },

  // Mark that the operator has taken manual control of the overlay transform.
  // Idempotent. On the first call it also tears down any pending saved-alignment
  // restore (settle timer, ResizeObserver, image-load listener) via the existing
  // disposer array so a late restore cannot clobber the live view.
  _markUserAdjusted() {
    if (this._userAdjustedTransform) return;
    this._userAdjustedTransform = true;
    if (Array.isArray(this._overlayRestoreDisposers)) {
      this._overlayRestoreDisposers.forEach((dispose) => {
        try { dispose(); } catch (_) { /* noop */ }
      });
      this._overlayRestoreDisposers = [];
    }
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
    // Active markers live outside the transformed overlay; recompute their
    // anchors so they track the floorplan as it translates/rotates/scales.
    // Other-level overlays are intentionally NOT repositioned here — that
    // fires only on the map move/zoom/view paths.
    this._positionPins();
  },

  _leafletRect() {
    if (!this.leafletEl) return null;
    return this.leafletEl.getBoundingClientRect();
  },

  _isValidAlignmentPayload(payload) {
    if (!payload) return false;

    const {center_lat, center_lon, scale_mpp, rotation_deg} = payload;

    return (
      Number.isFinite(center_lat) &&
      Number.isFinite(center_lon) &&
      Number.isFinite(scale_mpp) &&
      Number.isFinite(rotation_deg) &&
      center_lat >= -90 &&
      center_lat <= 90 &&
      center_lon >= -180 &&
      center_lon <= 180 &&
      scale_mpp > 0
    );
  },

  _syncApplyButtonState() {
    const applyBtn = this.applyBtn;
    if (!applyBtn) return;

    const img = this._naturalSizeImg;
    const ready = !!(img && img.naturalWidth > 0 && img.naturalHeight > 0);

    applyBtn.disabled = !ready;
    applyBtn.setAttribute("aria-disabled", ready ? "false" : "true");
    applyBtn.title = ready ? APPLY_ENABLED_TITLE : APPLY_DISABLED_TITLE;
  },

  // Keep #map-alignment-preview-status accurate after active markers render and
  // after image readiness changes. Reports deterministic diagram-mode and
  // geo-mode pin counts in plain copy. Before the image is ready or after the
  // marker layer is cleared, falls back to the not-ready state.
  _syncPreviewStatus() {
    const statusEl = this._previewStatusEl;
    if (!statusEl) return;

    const img = this._naturalSizeImg;
    const ready = !!(img && img.naturalWidth > 0 && img.naturalHeight > 0);
    const records = this._activeChildStops;

    if (!ready || !Array.isArray(records)) {
      statusEl.textContent = PREVIEW_STATUS_NOT_READY;
      return;
    }

    const diagramCount = records.filter((s) => s.positionMode === "diagram").length;
    const geoCount = records.filter((s) => s.positionMode === "geo").length;
    statusEl.textContent = previewStatusText(diagramCount, geoCount);
  },

  _pushAlignmentEventIfValid(eventName) {
    const payload = this._computeAlignment();
    if (!payload) return;
    if (!this._isValidAlignmentPayload(payload)) {
      this._logger.warn("MapAlignmentHook: invalid alignment payload; skipping pushEvent", {
        eventName,
        payload
      });
      return;
    }

    this.pushEvent(eventName, payload);
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

  _handleZoomSliderInput(e) {
    const map = this.leafletMap;
    if (!map) return;

    const target = parseFloat(e?.target?.value);
    if (!Number.isFinite(target)) return;
    const current = map.getZoom();
    if (target === current) return;

    // Pin the floorplan to the map through the zoom: keep its center at
    // the same world lat/lon, and scale by 2^Δzoom so it tracks the tiles.
    const canvasRect = this._leafletRect();
    if (!canvasRect) return;
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
    if (this._otherLevels) this._otherLevels.reposition();
  },

  _renderActiveChildStops(payload = {}) {
    const { stops, level_id: levelId } = payload;
    const received = (stops || []).length;
    if (!this._activePinsRoot) {
      this._logger.warn("MapAlignment: set_active_child_stops received but no #map-alignment-pins-active root", {received});
      return;
    }

    const activeLevelId = this.el?.dataset?.activeLevelId || null;
    if (activeLevelId && levelId && String(activeLevelId) !== String(levelId)) {
      return;
    }

    this._activeChildStops = (stops || [])
      .map((s) => {
        const lat = typeof s?.lat === "number" ? s.lat : parseFloat(s?.lat);
        const lon = typeof s?.lon === "number" ? s.lon : parseFloat(s?.lon);
        const hasGeo = Number.isFinite(lat) && Number.isFinite(lon);
        const diagramPoint = normalizeDiagramPoint(s?.diagram_coordinate);

        let positionMode;
        if (diagramPoint) {
          positionMode = "diagram";
        } else if (hasGeo) {
          positionMode = "geo";
        } else {
          return null;
        }

        return {
          ...s,
          lat: hasGeo ? lat : null,
          lon: hasGeo ? lon : null,
          diagramPoint,
          positionMode,
        };
      })
      .filter(Boolean);

    this._activePinsRoot.innerHTML = "";
    this._activeChildStops.forEach((s) => {
      const treatment = treatmentForLocationType(s.location_type, DIAGRAM_BASE_COLOR);
      const pin = document.createElement("div");
      pin.className =
        "map-pin absolute -translate-x-1/2 -translate-y-1/2 group pointer-events-auto";
      pin.dataset.positionMode = s.positionMode;
      pin.style.width = treatment.width;
      pin.style.height = treatment.height;

      const dot = document.createElement("div");
      dot.className = "w-full h-full border";
      dot.style.backgroundColor = treatment.fill;
      dot.style.borderColor = treatment.stroke;
      dot.style.borderRadius = treatment.borderRadius;

      pin.appendChild(dot);

      const tip = document.createElement("div");
      tip.className =
        "absolute left-1/2 bottom-full mb-1 -translate-x-1/2 whitespace-nowrap rounded bg-black/80 text-white text-xs px-1.5 py-0.5 opacity-0 group-hover:opacity-100 pointer-events-none";
      tip.textContent = stopTooltipLabel(s, "A");
      pin.appendChild(tip);

      // Geo-mode fallback pins are positioned from stored lat/lon (no valid
      // diagram coordinate), so they are NOT anchored to the floorplan image.
      // Mark them as a degraded/fallback state per ux-states: reduced opacity +
      // dashed border (deterministic), plus text that names the position source
      // (color is never the sole signal). Diagram-mode pins are left exactly as
      // PR #648 renders them.
      if (s.positionMode === "geo") {
        const fallbackLabel = fallbackTooltipLabel(s, "A");
        pin.classList.add("map-pin-fallback");
        pin.dataset.positionFallback = "geo";
        pin.style.opacity = FALLBACK_PIN_OPACITY;
        pin.setAttribute("aria-label", fallbackLabel);
        dot.style.borderStyle = "dashed";
        tip.textContent = fallbackLabel;
      }

      appendStopBadges(pin, s.badges, DIAGRAM_BASE_COLOR);

      this._activePinsRoot.appendChild(pin);
      s._el = pin;
    });

    this._positionPins();
    this._syncPreviewStatus();
  },

  _positionPins() {
    if (!this.leafletMap) return;

    // Read layout once per call; reuse across every marker (avoid per-marker
    // layout thrash). Diagram-mode pins need canvas + natural image metrics.
    const canvasRect = this._leafletRect();
    const img = this.overlay ? this.overlay.querySelector("img") : null;
    const metrics = {
      transform: this.transform,
      canvasWidth: canvasRect ? canvasRect.width : null,
      canvasHeight: canvasRect ? canvasRect.height : null,
      imageNaturalWidth: img ? img.naturalWidth : null,
      imageNaturalHeight: img ? img.naturalHeight : null,
    };

    (this._activeChildStops || []).forEach((s) => {
      if (!s._el) return;

      let pt = null;
      if (s.positionMode === "diagram") {
        pt = previewPointForDiagramCoordinate({
          coordinate: s.diagramPoint,
          transform: metrics.transform,
          canvasWidth: metrics.canvasWidth,
          canvasHeight: metrics.canvasHeight,
          imageNaturalWidth: metrics.imageNaturalWidth,
          imageNaturalHeight: metrics.imageNaturalHeight,
        });
      } else if (Number.isFinite(s.lat) && Number.isFinite(s.lon)) {
        pt = this.leafletMap.latLngToContainerPoint([s.lat, s.lon]);
      }

      if (!pt) return;
      s._el.style.left = `${pt.x}px`;
      s._el.style.top = `${pt.y}px`;
    });
  },

  _clearPinLayers() {
    if (this._activePinsRoot) this._activePinsRoot.innerHTML = "";
    this._activePinsRoot = null;
    this._activeChildStops = null;
    this._syncPreviewStatus();
  }
};

function stopTooltipLabel(s, roleTag = "") {
  const name = s.stop_name || s.stop_id || "";
  const platform = s.platform_code ? ` · Plat ${s.platform_code}` : "";
  const rolePrefix = roleTag ? `${roleTag}: ` : "";
  return `${rolePrefix}${name}${platform}`;
}

// Label for geo-mode fallback pins: the standard active label plus an explicit
// "map position" suffix so visible tooltip and aria-label agree on the source.
function fallbackTooltipLabel(s, roleTag = "") {
  return `${stopTooltipLabel(s, roleTag)}${FALLBACK_POSITION_SUFFIX}`;
}

export {
  parseAlignmentPayload,
  readActiveAlignment,
};
export default MapAlignmentHook;
