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
 *   #map-alignment-workspace     binding root for keyboard nudging and
 *                                hold-to-hide; wraps the ignored canvas and
 *                                every floating panel rendered beside it
 *   #map-alignment-tools         floating controls panel (collapsed view-only)
 *   #map-alignment-tools-toggle  collapses/expands that panel
 *   #map-alignment-residual      fit readout; the hook writes only its
 *                                data-fit-state="measuring" in-flight state
 *   #map-alignment-residual-value  text of that readout
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
  paletteColor,
  symbolForLocationType,
  treatmentForLocationType,
} from "./stop_icon_symbols";

const SCALE_MIN = 0.25;
const SCALE_MAX = 4;
const IDENTITY_TRANSFORM = Object.freeze({
  tx: 0,
  ty: 0,
  rotation: 0,
  scale: 1,
});
const MAP_ALIGNMENT_HOOK_BUILD = "map-align-fix-v2";

// Advisory transform-invalidation debounce. Bursts of pointer/button/zoom
// mutations coalesce into one generation-tagged `alignment_transform_changed`
// push per window. The server uses it only to close visible review state; the
// Package 06 fingerprint recheck remains the sole stale-write fence (INV-4).
const TRANSFORM_INVALIDATION_DEBOUNCE_MS = 400;

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
const PREVIEW_STATUS_NOT_READY = "Coordinate-change preview not ready";
const MAP_STATES = new Set([
  "initializing",
  "ready",
  "imagery_unavailable",
  "buildings_degraded",
  "offline",
  "reconnecting",
  "fatal",
]);

// Overlay opacity used before the slider is reachable, and restored to when a
// hold-to-hide release finds no slider. Matches the slider's rendered default.
const DEFAULT_OVERLAY_OPACITY = "0.7";

// Keyboard nudging (CRIT-004, INV-10E-3). Bound on #map-alignment-workspace,
// never on the hook root: the root is the ignored canvas and the tools panel is
// a *sibling* of it, so a key pressed while focus sits on a tools-panel button
// would never reach a root listener.
//
// Both faces of each printable key resolve the same action. Shift is the coarse
// modifier (INV-09D-4), and on most layouts it also changes the character the
// key reports — without the shifted face, Shift+[ and Shift+- would silently do
// nothing at exactly the moment the operator asked for the coarse step.
const KEY_TRANSFORM_ACTIONS = new Map([
  ["ArrowLeft", "left"],
  ["ArrowRight", "right"],
  ["ArrowUp", "up"],
  ["ArrowDown", "down"],
  ["[", "rotate-left"],
  ["{", "rotate-left"],
  ["]", "rotate-right"],
  ["}", "rotate-right"],
  ["-", "scale-down"],
  ["_", "scale-down"],
  ["=", "scale-up"],
  ["+", "scale-up"],
]);

// Held to blank the floorplan for registration checking. Mnemonic, and guarded
// against every editable target so it never eats a typed character.
const HOLD_TO_HIDE_KEY = "h";

// Typing targets that must keep every keystroke: the lat/lon and zoom inputs
// live in popovers over this same workspace.
const EDITABLE_TARGET_SELECTOR = "input, textarea, select, [contenteditable]";

// The collapse toggle names the action it will perform, not the current state.
const TOOLS_HIDE_LABEL = "Hide tools";
const TOOLS_SHOW_LABEL = "Show tools";
const FLOORPLAN_OPACITY_LABEL = "Floorplan opacity";
const OTHER_OPACITY_LABEL = "Other-levels opacity";

// In-flight fit readout. The hook knows a transform changed one debounce window
// before the server does, so it owns the measuring state; the server owns every
// resolved one.
const RESIDUAL_MEASURING_STATE = "measuring";
const RESIDUAL_MEASURING_TEXT = "Measuring…";

// How long the measuring state waits for the server's answer to land in the
// DOM. It exists for the case where the answer produces no DOM diff at all —
// re-scoring an unchanged verdict, such as a level that stays below three
// anchors — because then no patch ever arrives to replace "Measuring…".
const MEASURING_RESOLVE_GRACE_MS = 1500;

// Ready-state status: front-load the two deterministic counts. Diagram-mode pins
// are anchored to the floorplan image; geo-mode pins fall back to map position.
function previewStatusText(diagramCount, geoCount) {
  return `${diagramCount} anchored to floorplan · ${geoCount} positioned from map`;
}

function shouldEnableMapAlignmentDiagnostics(root) {
  if (root?.dataset?.mapAlignmentDebugLogging === "true") return true;

  const nodeEnv =
    typeof process !== "undefined" && process?.env
      ? process.env.NODE_ENV
      : undefined;

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
    },
  };
}
function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function clampScaleInDirection(current, candidate) {
  if (candidate === current) return current;
  if (candidate < current && current <= SCALE_MIN) return current;
  if (candidate > current && current >= SCALE_MAX) return current;

  return clamp(candidate, SCALE_MIN, SCALE_MAX);
}

function parseAlignmentPayload(
  centerLatRaw,
  centerLonRaw,
  scaleMppRaw,
  rotationDegRaw,
) {
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

  return { centerLat, centerLon, scaleMpp, rotationDeg };
}

function readActiveAlignment(root) {
  return parseAlignmentPayload(
    root.dataset.alignCenterLat,
    root.dataset.alignCenterLon,
    root.dataset.alignScaleMpp,
    root.dataset.alignRotationDeg,
  );
}

function overlayCenter(overlay) {
  const rect = overlay.getBoundingClientRect();
  return {
    x: rect.left + rect.width / 2,
    y: rect.top + rect.height / 2,
  };
}

const MapAlignmentHook = {
  mounted() {
    const root = this.el;
    this._logger = createMapAlignmentLogger(root);
    this.generation = root.dataset.mapGeneration || "test-generation";
    this._legacyTestMode = !root.dataset.mapGeneration;
    this._destroyed = false;

    const L = window.L;
    if (!L) {
      this._logger.error(
        "MapAlignmentHook: window.L (Leaflet) is not available",
      );
      this._emitMapState("fatal");
      return;
    }

    const initialLat = parseFloat(root.dataset.initialLat);
    const initialLon = parseFloat(root.dataset.initialLon);
    const initialZoom = parseInt(root.dataset.initialZoom, 10);

    const activeAlignment = readActiveAlignment(root);
    this.savedAlignment = activeAlignment
      ? {
          center_lat: activeAlignment.centerLat,
          center_lon: activeAlignment.centerLon,
          scale_mpp: activeAlignment.scaleMpp,
          rotation_deg: activeAlignment.rotationDeg,
        }
      : null;
    this._previewActive = false;

    const overlay = root.querySelector(
      "#map-alignment-overlay[data-editable-overlay='true']",
    );
    const leafletEl = root.querySelector("#map-alignment-leaflet");
    const rotateHandle = root.querySelector(
      "#map-alignment-rotate-handle[data-edit-target-overlay='active']",
    );
    const scaleHandle = root.querySelector(
      "#map-alignment-scale-handle[data-edit-target-overlay='active']",
    );
    const latInput = document.getElementById("map-alignment-lat-input");
    const lonInput = document.getElementById("map-alignment-lon-input");
    const applyCenterBtn = document.getElementById(
      "map-alignment-apply-center",
    );
    const opacitySlider = document.getElementById("map-alignment-opacity");
    const zoomSlider = document.getElementById("map-alignment-zoom");
    const saveBtn = document.getElementById("map-alignment-save");
    const applyBtn = document.getElementById("map-alignment-apply");

    if (!overlay || !leafletEl || !rotateHandle || !scaleHandle) {
      this._logger.error(
        "MapAlignmentHook: required active overlay edit elements are missing",
      );
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
    this._previewStatusEl = document.getElementById(
      "map-alignment-preview-status",
    );
    this._overlayRestoreDisposers = [];

    overlay.style.opacity = opacitySlider
      ? opacitySlider.value
      : DEFAULT_OVERLAY_OPACITY;

    this.transform = { ...IDENTITY_TRANSFORM };
    this._userAdjustedTransform = false;

    const mapCenterLat = activeAlignment
      ? activeAlignment.centerLat
      : initialLat;
    const mapCenterLon = activeAlignment
      ? activeAlignment.centerLon
      : initialLon;

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
      zoomSnap: 0.5,
    });

    // Esri World Imagery: free aerial tiles, no API key. URL uses z/y/x
    // (note: y before x). Goes direct from the browser — no credential to hide.
    const imageryLayer = L.tileLayer(
      "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
      {
        keepBuffer: 8,
        maxNativeZoom: 19,
        maxZoom: 22,
        updateWhenIdle: false,
        updateWhenZooming: true,
        attribution: "Imagery © Esri, Maxar, Earthstar Geographics",
      },
    ).addTo(map);

    // Transparent reference layer with roads and road names tuned to overlay
    // on World_Imagery.
    const roadsLayer = L.tileLayer(
      "https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}",
      {
        keepBuffer: 8,
        maxNativeZoom: 19,
        maxZoom: 22,
        updateWhenIdle: false,
        updateWhenZooming: true,
        attribution: "Roads © Esri",
      },
    ).addTo(map);

    this.leafletMap = map;
    this._tileLayers = [imageryLayer, roadsLayer];
    this._emitMapState("initializing");
    this._bindRuntimeStateEvents();

    this._activePinsRoot = root.querySelector("#map-alignment-pins-active");
    this._activeChildStops = [];

    const otherOverlaysRoot = root.querySelector("#map-other-overlays");
    const otherPinsRoot = root.querySelector("#map-other-pins");
    if (otherOverlaysRoot && otherPinsRoot) {
      this._otherLevels = createOtherLevelsLayers({
        overlaysRoot: otherOverlaysRoot,
        pinsRoot: otherPinsRoot,
        applyOverlayTransform: (el, alignment) =>
          this._applyOtherLevelOverlayTransform(el, alignment),
        projectLatLng: (lat, lon) => {
          const pt = this.leafletMap.latLngToContainerPoint([lat, lon]);
          return pt ? { x: pt.x, y: pt.y } : null;
        },
        symbolFor: symbolForLocationType,
        paletteRoot: root.closest("#diagram-page"),
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
    this.handleEvent("set_active_child_stops", (payload) =>
      this._renderActiveChildStops(payload),
    );
    this.handleEvent("set_other_levels", (payload) => {
      if (this._otherLevels) this._otherLevels.update(payload);
    });
    this.handleEvent("apply_preview_transform", (payload) =>
      this._handleApplyPreviewTransform(payload),
    );
    this.handleEvent("restore_saved_transform", (payload) =>
      this._handleRestoreSavedTransform(payload),
    );
    this.handleEvent("alignment_saved", (payload) =>
      this._handleAlignmentSaved(payload),
    );
    this.pushEvent(
      "map_ready",
      this._legacyTestMode ? {} : { generation: this.generation },
    );

    if (zoomSlider) {
      zoomSlider.min = String(map.getMinZoom());
      zoomSlider.max = String(map.getMaxZoom());
      zoomSlider.value = String(map.getZoom());

      this._onZoomSliderInput = (e) => this._handleZoomSliderInput(e);
      zoomSlider.addEventListener("input", this._onZoomSliderInput);

      this._onZoomEnd = () => {
        zoomSlider.value = String(map.getZoom());
        // Zoom can change without slider input, so the readout follows the
        // slider here too.
        this._syncSliderReadouts();
      };
      map.on("zoomend", this._onZoomEnd);
    }

    this._fetchBuildings(mapCenterLat, mapCenterLon);

    if (this.savedAlignment) {
      this._scheduleOverlayAlignmentRestore(
        overlay,
        this.savedAlignment,
        "active",
      );
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
        pointerId: e.pointerId,
      };
      if (overlay.setPointerCapture && e.pointerId !== undefined) {
        try {
          overlay.setPointerCapture(e.pointerId);
        } catch (_) {
          /* ignore */
        }
      }
      e.preventDefault();
      e.stopPropagation();
      // preventDefault above suppresses the browser's own click-to-focus, so
      // after a drag — the most common gesture on this surface — focus would
      // stay wherever it was and every keyboard shortcut bound on the workspace
      // would be dead. Grabbing the floorplan is the operator saying "this is
      // what I am working on", so hand the workspace the focus explicitly.
      this._focusWorkspace();
    };
    this._onOverlayPointerMove = (e) => {
      if (!this._translateState) return;
      const dx = e.clientX - this._translateState.startX;
      const dy = e.clientY - this._translateState.startY;
      const nextTx = this._translateState.baseTx + dx;
      const nextTy = this._translateState.baseTy + dy;
      if (nextTx === this.transform.tx && nextTy === this.transform.ty) return;
      this.transform.tx = nextTx;
      this.transform.ty = nextTy;
      this._transformDidChange({ previewAdjusted: true });
    };
    this._onOverlayPointerUp = (e) => {
      if (!this._translateState) return;
      if (
        overlay.releasePointerCapture &&
        this._translateState.pointerId !== undefined
      ) {
        try {
          overlay.releasePointerCapture(this._translateState.pointerId);
        } catch (_) {
          /* ignore */
        }
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
        pointerId: e.pointerId,
      };
      if (rotateHandle.setPointerCapture && e.pointerId !== undefined) {
        try {
          rotateHandle.setPointerCapture(e.pointerId);
        } catch (_) {
          /* ignore */
        }
      }
      e.preventDefault();
      e.stopPropagation();
    };
    this._onRotatePointerMove = (e) => {
      if (!this._rotateState) return;
      const { centerX, centerY, startAngle, baseRotation } = this._rotateState;
      const angle = Math.atan2(e.clientY - centerY, e.clientX - centerX);
      const deltaDeg = (angle - startAngle) * (180 / Math.PI);
      const nextRotation = baseRotation + deltaDeg;
      if (nextRotation === this.transform.rotation) return;
      this.transform.rotation = nextRotation;
      this._transformDidChange({ previewAdjusted: true });
    };
    this._onRotatePointerUp = (e) => {
      if (!this._rotateState) return;
      if (
        rotateHandle.releasePointerCapture &&
        this._rotateState.pointerId !== undefined
      ) {
        try {
          rotateHandle.releasePointerCapture(this._rotateState.pointerId);
        } catch (_) {
          /* ignore */
        }
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

      this._markUserAdjusted();
      this._scaleState = {
        centerX: center.x,
        centerY: center.y,
        initialDistance: initialDistance,
        baseScale: this.transform.scale,
        pointerId: e.pointerId,
      };
      if (scaleHandle.setPointerCapture && e.pointerId !== undefined) {
        try {
          scaleHandle.setPointerCapture(e.pointerId);
        } catch (_) {
          /* ignore */
        }
      }
      e.preventDefault();
      e.stopPropagation();
    };
    this._onScalePointerMove = (e) => {
      if (!this._scaleState) return;
      const { centerX, centerY, initialDistance, baseScale } = this._scaleState;
      const dx = e.clientX - centerX;
      const dy = e.clientY - centerY;
      const distance = Math.sqrt(dx * dx + dy * dy);
      const ratio = distance / initialDistance;
      const nextScale = clampScaleInDirection(
        this.transform.scale,
        baseScale * ratio,
      );
      if (nextScale === this.transform.scale) return;
      this.transform.scale = nextScale;
      this._transformDidChange({ previewAdjusted: true });
    };
    this._onScalePointerUp = (e) => {
      if (!this._scaleState) return;
      if (
        scaleHandle.releasePointerCapture &&
        this._scaleState.pointerId !== undefined
      ) {
        try {
          scaleHandle.releasePointerCapture(this._scaleState.pointerId);
        } catch (_) {
          /* ignore */
        }
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

      this._markUserAdjusted();

      const cxBefore = canvasRect.width / 2 + this.transform.tx;
      const cyBefore = canvasRect.height / 2 + this.transform.ty;
      const worldCenter = this.leafletMap.containerPointToLatLng([
        cxBefore,
        cyBefore,
      ]);

      this.leafletMap.setView([lat, lon], this.leafletMap.getZoom(), {
        animate: false,
      });

      const newPt = this.leafletMap.latLngToContainerPoint(worldCenter);
      this.transform.tx = newPt.x - canvasRect.width / 2;
      this.transform.ty = newPt.y - canvasRect.height / 2;
      this._transformDidChange({ previewAdjusted: false });

      this._fetchBuildings(lat, lon);
    };
    applyCenterBtn.addEventListener("click", this._onApplyCenter);

    // --- Opacity slider: controls floorplan overlay opacity ---
    if (opacitySlider) {
      this._onOpacityInput = (e) => {
        // A hold in progress owns the overlay's opacity. Skipping the write
        // keeps the floorplan blank until release, and release then restores
        // this new value because it reads the slider live.
        if (!this._holdToHideActive) {
          this.overlay.style.opacity = e.target.value;
        }
        this._syncSliderReadouts();
      };
      opacitySlider.addEventListener("input", this._onOpacityInput);
    }

    this._syncOtherOverlaysOpacitySlider();
    // Sliders are captured and the zoom slider's min/max/value are set from the
    // map by this point, so the readouts start from the live values.
    this._syncSliderReadouts();

    // --- Save: compute canonical alignment and push to server ---
    if (saveBtn) {
      this._onSave = () => {
        this._pushAlignmentEventIfValid("save_alignment");
      };
      saveBtn.addEventListener("click", this._onSave);
    }

    this._transformControls = Array.from(
      document.querySelectorAll("[data-map-transform-action]"),
    );
    this._transformControls.forEach((control) => {
      const action = control.dataset.mapTransformAction;
      const coarse = control.dataset.mapTransformCoarse === "true";
      // Holding Shift resolves the coarse step, so opposing nudges stay
      // symmetric without duplicate coarse buttons (INV-09D-4). `coarse ||`
      // is retained so a data-map-transform-coarse="true" control still forces
      // the coarse step. A Shift-held Enter/Space on a focused button produces
      // a click with shiftKey === true, so the modifier needs no second binding.
      const handler = (event) =>
        this._adjustTransform(action, coarse || event?.shiftKey === true);
      control.addEventListener("click", handler);
      control._mapAlignmentHandler = handler;
    });

    // --- Apply: push image natural size once, and forward apply clicks ---
    this._sentNaturalSize = false;
    const img = overlay ? overlay.querySelector("img") : null;
    this._naturalSizeImg = img;
    const pushNaturalSize = () => {
      if (this._sentNaturalSize) return;
      if (!img || !img.naturalWidth || !img.naturalHeight) return;
      this._sentNaturalSize = true;
      this.pushEvent("set_image_natural_size", {
        ...(this._legacyTestMode ? {} : { generation: this.generation }),
        w: img.naturalWidth,
        h: img.naturalHeight,
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
        // The apply button always opens the evidence-first review. The hook
        // pushes the displayed transform; the server rebinds it to the review
        // fingerprint and rebuilds the persisted payload from the stored
        // review-time values, never from later client state (INV-3, DC-1).
        //
        // Consume an invalidation queued by the transform being reviewed. If it
        // were allowed to fire after the open event, it would immediately close
        // the fresh review. Any later transform mutation starts a new timer.
        this._pushAlignmentEventIfValid("open_coordinate_review", () => {
          this._clearTransformInvalidationTimer();
          // The consumed window is the only thing that was going to resolve the
          // measuring state, so put the last resolved reading back rather than
          // leaving "Measuring…" standing for a measurement that never comes.
          this._abandonMeasuringState();
        });
      };
      applyBtn.addEventListener("click", this._onApply);
    }

    this._bindWorkspaceKeyboard();
    this._bindToolsToggle();

    // Own apply enablement after mount. The static markup disables the button
    // until image dims are known, but the ignored map root never receives a
    // server patch — so set the starting state here and re-sync on image load.
    this._syncApplyButtonState();
    this.handleEvent("retry_map_alignment", () => this._retryMapRuntime());
  },

  updated() {
    this._syncOtherOverlaysOpacitySlider();

    const workspace = document.getElementById("map-alignment-workspace");
    if (workspace !== this._workspaceEl) {
      this._releaseHoldToHide();
      this._unbindWorkspaceKeyboard();
      this._bindWorkspaceKeyboard();
    }

    const toolsToggle = document.getElementById("map-alignment-tools-toggle");
    if (toolsToggle !== this._toolsToggle) {
      const toolsCollapsed = this._toolsCollapsed;
      this._unbindToolsToggle();
      this._bindToolsToggle();
      this._toolsCollapsed = toolsCollapsed;
    }

    // The tools panel is server-rendered, so a patch that re-renders it puts the
    // hidden children back on screen. Collapse is client-owned view state, so
    // the hook re-asserts it rather than the server storing it.
    if (this._toolsCollapsed) this._setToolsCollapsed(true);
    this._reassertMeasuringState();
  },

  destroyed() {
    this._destroyed = true;
    // Before anything is unbound: a hook torn down mid-hold must not leave the
    // floorplan invisible, and a torn-down measuring window will never resolve.
    this._releaseHoldToHide();
    this._abandonMeasuringState();
    if (this._toolsCollapsed) this._setToolsCollapsed(false);
    this._unbindWorkspaceKeyboard();
    this._unbindToolsToggle();
    if (this._rafId !== null && this._rafId !== undefined) {
      cancelAnimationFrame(this._rafId);
      this._rafId = null;
    }
    if (this._postTransitionTimer) {
      clearTimeout(this._postTransitionTimer);
      this._postTransitionTimer = null;
    }
    this._clearTransformInvalidationTimer();
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
      this.overlay.removeEventListener(
        "pointerdown",
        this._onOverlayPointerDown,
      );
      this.overlay.removeEventListener(
        "pointermove",
        this._onOverlayPointerMove,
      );
      this.overlay.removeEventListener("pointerup", this._onOverlayPointerUp);
      this.overlay.removeEventListener(
        "pointercancel",
        this._onOverlayPointerUp,
      );
    }

    if (this.rotateHandle) {
      this.rotateHandle.removeEventListener(
        "pointerdown",
        this._onRotatePointerDown,
      );
      this.rotateHandle.removeEventListener(
        "pointermove",
        this._onRotatePointerMove,
      );
      this.rotateHandle.removeEventListener(
        "pointerup",
        this._onRotatePointerUp,
      );
      this.rotateHandle.removeEventListener(
        "pointercancel",
        this._onRotatePointerUp,
      );
    }

    if (this.scaleHandle) {
      this.scaleHandle.removeEventListener(
        "pointerdown",
        this._onScalePointerDown,
      );
      this.scaleHandle.removeEventListener(
        "pointermove",
        this._onScalePointerMove,
      );
      this.scaleHandle.removeEventListener("pointerup", this._onScalePointerUp);
      this.scaleHandle.removeEventListener(
        "pointercancel",
        this._onScalePointerUp,
      );
    }

    if (this.applyCenterBtn && this._onApplyCenter) {
      this.applyCenterBtn.removeEventListener("click", this._onApplyCenter);
    }
    if (this.opacitySlider && this._onOpacityInput) {
      this.opacitySlider.removeEventListener("input", this._onOpacityInput);
    }
    if (this.otherOpacitySlider && this._onOtherOpacityInput) {
      this.otherOpacitySlider.removeEventListener(
        "input",
        this._onOtherOpacityInput,
      );
      this.otherOpacitySlider = null;
      this._onOtherOpacityInput = null;
    }
    if (this.saveBtn && this._onSave) {
      this.saveBtn.removeEventListener("click", this._onSave);
    }
    if (this.applyBtn && this._onApply) {
      this.applyBtn.removeEventListener("click", this._onApply);
    }
    if (Array.isArray(this._transformControls)) {
      this._transformControls.forEach((control) => {
        if (control._mapAlignmentHandler) {
          control.removeEventListener("click", control._mapAlignmentHandler);
          delete control._mapAlignmentHandler;
        }
      });
      this._transformControls = [];
    }
    if (this._onOnline) window.removeEventListener("online", this._onOnline);
    if (this._onOffline) window.removeEventListener("offline", this._onOffline);
    this._onOnline = null;
    this._onOffline = null;
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
      try {
        this.leafletMap.off("zoomend", this._onZoomEnd);
      } catch (_) {}
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
      } catch (_) {
        /* container reused by newer instance */
      }
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
      this._logger.warn(
        "MapAlignmentHook: floorplan image not loaded; skipping save",
      );
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
      this._logger.warn(
        "MapAlignmentHook: invalid map geometry; skipping alignment compute",
        {
          canvasW,
          canvasH,
        },
      );
      return null;
    }

    const { tx, ty, scale } = this.transform;
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
      rotation_deg: this.transform.rotation,
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

  _cssTransformForAlignment(alignment, image) {
    const map = this.leafletMap;
    if (
      !map ||
      !alignment ||
      !image ||
      !image.naturalWidth ||
      !image.naturalHeight
    )
      return null;

    const canvasRect = this._leafletRect();
    if (!canvasRect) return null;
    const canvasW = canvasRect.width;
    const canvasH = canvasRect.height;
    if (!(canvasW > 0) || !(canvasH > 0)) return null;

    const cx = canvasW / 2;
    const cy = canvasH / 2;
    const p0 = map.containerPointToLatLng([cx, cy]);
    const p1 = map.containerPointToLatLng([cx + 1, cy]);
    const metersPerCanvasPx = map.distance(p0, p1);
    if (!(metersPerCanvasPx > 0)) return null;

    const imgAspect = image.naturalWidth / image.naturalHeight;
    const canvasAspect = canvasW / canvasH;
    const containWidth =
      canvasAspect > imgAspect ? canvasH * imgAspect : canvasW;
    if (!(containWidth > 0)) return null;

    const renderedPxPerImagePxNeeded = alignment.scale_mpp / metersPerCanvasPx;
    const scale =
      renderedPxPerImagePxNeeded / (containWidth / image.naturalWidth);

    const alignedCenterPoint = map.latLngToContainerPoint([
      alignment.center_lat,
      alignment.center_lon,
    ]);

    return {
      tx: alignedCenterPoint.x - canvasW / 2,
      ty: alignedCenterPoint.y - canvasH / 2,
      rotation: alignment.rotation_deg,
      scale,
    };
  },

  _restoreOverlayAlignment(overlayEl, alignment, img, label) {
    if (this._userAdjustedTransform) return;

    const result = this._cssTransformForAlignment(alignment, img);
    if (!result) {
      this._logger.warn("MapAlignment: restore skipped, geometry not ready", {
        label,
      });
      return;
    }

    this.transform = result;
    this._applyTransform();
  },

  _applyOtherLevelOverlayTransform(el, alignment) {
    if (!el || !alignment) return;

    const img = el.tagName === "IMG" ? el : el.querySelector("img");
    if (!img) return;

    const result = this._cssTransformForAlignment(alignment, img);
    if (!result) return;

    this._applyOverlayTransform(el, result);
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
      this.otherOpacitySlider.removeEventListener(
        "input",
        this._onOtherOpacityInput,
      );
      this._onOtherOpacityInput = null;
    }

    this.otherOpacitySlider = nextSlider;
    // The other-levels control is conditionally rendered, so this runs on the
    // rebind path too — including the case where the slider has just appeared
    // or disappeared across a LiveView patch.
    this._syncSliderReadouts();

    if (!this.otherOpacitySlider || !this._otherLevels) return;

    this._onOtherOpacityInput = (e) => {
      this._otherLevels.setOpacity(parseFloat(e.target.value));
      this._syncSliderReadouts();
    };

    this.otherOpacitySlider.addEventListener(
      "input",
      this._onOtherOpacityInput,
    );
    this._otherLevels.setOpacity(
      parseFloat(this.otherOpacitySlider.value) || 0.7,
    );
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
        try {
          dispose();
        } catch (_) {
          /* noop */
        }
      });
      this._overlayRestoreDisposers = [];
    }
  },

  _markPreviewDirty() {
    if (!this._previewActive) return;
    this._previewActive = false;
    this.pushEvent("alignment_preview_adjusted", {
      generation: this.generation,
    });
  },

  // Shared transform-change path. Every effective mutation calls this after
  // mutating `this.transform`. It applies/repositions the overlay, refreshes
  // pin status, preserves Package 07 preview-dirty semantics when
  // `previewAdjusted` is true, and debounces one generation-tagged
  // `alignment_transform_changed` so an open review closes (advisory only —
  // INV-4). The debounce coalesces bursts into one push per window and the
  // timer is cleared in destroyed() to avoid leaks.
  //
  // Two options, because the caller is answering two different questions:
  //   previewAdjusted — did the operator do this? (overlay drag, rotate/scale
  //     handle, nudge buttons). Only this fires _markPreviewDirty().
  //   dirtying — does this move the floorplan off its saved position? Defaults
  //     to `previewAdjusted`, which is correct for every path but one.
  // They differ only for applying an assisted preview: not an operator gesture,
  // but it does dirty the saved alignment. Flipping `previewAdjusted` there is
  // not available — it would fire _markPreviewDirty() and clobber the
  // `_previewActive` state that path has just set.
  _transformDidChange({ previewAdjusted, dirtying } = {}) {
    this._applyTransform();
    this._syncPreviewStatus();

    if (previewAdjusted) {
      this._markPreviewDirty();
    }

    // The server reads `unsaved` as the dirty signal and owns the resulting
    // unsaved indicator and the restore control's enabled state (INV-09D-3);
    // without it a restore would re-dirty itself one debounce window later.
    const isDirtying =
      dirtying === undefined ? previewAdjusted === true : dirtying === true;
    this._scheduleTransformInvalidation({ unsaved: isDirtying });
  },

  // `unsaved` defaults to true to match the server's own
  // `Map.get(params, "unsaved", true)`, so an option-less call behaves exactly
  // as this event did before the key existed.
  _scheduleTransformInvalidation({ unsaved = true } = {}) {
    this._clearTransformInvalidationTimer();

    // Deliberately every scheduling path, not only operator gestures: a restore
    // and a map recenter also leave the rendered number describing the previous
    // position for one debounce window, and a stale number in a confident band
    // reads as current (CRIT-005).
    this._beginMeasuringState();

    // Each call replaces the pending timer, so when changes coalesce inside one
    // window the later call's `unsaved` value wins. Deliberately not a sticky
    // OR: that would make a restore impossible to clear.
    this._transformInvalidationTimer = setTimeout(() => {
      this._transformInvalidationTimer = null;

      if (this._destroyed) return;

      // Computed here rather than at schedule time so a window that is
      // coalesced away, cancelled by open_coordinate_review, or dropped by
      // destroy() does no geometry work and logs no warning, and so the
      // reported alignment describes the transform actually being pushed.
      const alignment = this._computeAlignment();

      const payload = { generation: this.generation, unsaved };

      // `null` means the floorplan image is not loaded or the map geometry is
      // degenerate. Omit the key rather than sending nulls: the server leaves
      // its fit assign untouched when the key is absent — which also means it
      // will never resolve the measuring state, so put the last reading back.
      if (alignment) {
        payload.alignment = alignment;
        this._awaitMeasuringResolution();
      } else {
        this._abandonMeasuringState();
      }

      this.pushEvent("alignment_transform_changed", payload);
    }, TRANSFORM_INVALIDATION_DEBOUNCE_MS);
  },

  _clearTransformInvalidationTimer() {
    if (!this._transformInvalidationTimer) return;

    clearTimeout(this._transformInvalidationTimer);
    this._transformInvalidationTimer = null;
  },

  // --- Keyboard nudging and hold-to-hide (CRIT-004, CRIT-006, INV-10E-3) ---

  // Bound on #map-alignment-workspace, resolved by id exactly as the transform
  // controls are resolved by `document.querySelectorAll`. Binding on the hook
  // root instead would drop every shortcut fired while focus sits on a
  // tools-panel control, because that panel is a sibling of the root, not a
  // descendant of it.
  _bindWorkspaceKeyboard() {
    this._holdToHideActive = false;
    this._workspaceEl = document.getElementById("map-alignment-workspace");

    this._onWorkspaceKeyDown = (event) => {
      if (!this._keyboardShortcutAllowed(event)) return;

      const key = typeof event.key === "string" ? event.key : "";
      if (!key) return;

      if (key.toLowerCase() === HOLD_TO_HIDE_KEY) {
        event.preventDefault();
        this._engageHoldToHide();
        return;
      }

      const action = KEY_TRANSFORM_ACTIONS.get(key);
      // No preventDefault for anything else: Tab traversal and browser
      // shortcuts have to keep working on this surface.
      if (!action) return;

      event.preventDefault();
      this._adjustTransform(action, event.shiftKey === true);
    };

    // Release is a watchdog, so keyup is deliberately *not* guarded the way
    // keydown is. Releasing a hold that is not held costs nothing; leaving the
    // floorplan invisible costs the operator the surface.
    this._onWorkspaceKeyUp = (event) => {
      const key = typeof event?.key === "string" ? event.key : "";
      if (key.toLowerCase() !== HOLD_TO_HIDE_KEY) return;
      this._releaseHoldToHide();
    };

    this._onHoldToHideWatchdog = () => this._releaseHoldToHide();

    this._onDocumentFocusIn = (event) => {
      const workspace = this._workspaceEl;
      const target = event?.target;
      if (workspace && target && workspace.contains(target)) return;
      this._releaseHoldToHide();
    };

    if (this._workspaceEl) {
      this._workspaceEl.addEventListener("keydown", this._onWorkspaceKeyDown);
      this._workspaceEl.addEventListener("keyup", this._onWorkspaceKeyUp);

      // The keyup can be delivered to another window, to a closed popover, or
      // never — so the release does not enumerate the ways focus is lost. It
      // watches for focus leaving at all.
      window.addEventListener("blur", this._onHoldToHideWatchdog);
      document.addEventListener("visibilitychange", this._onHoldToHideWatchdog);
      document.addEventListener("focusin", this._onDocumentFocusIn);
    }
  },

  _unbindWorkspaceKeyboard() {
    if (this._workspaceEl) {
      if (this._onWorkspaceKeyDown) {
        this._workspaceEl.removeEventListener(
          "keydown",
          this._onWorkspaceKeyDown,
        );
      }
      if (this._onWorkspaceKeyUp) {
        this._workspaceEl.removeEventListener("keyup", this._onWorkspaceKeyUp);
      }
      this._workspaceEl = null;
    }
    if (this._onHoldToHideWatchdog) {
      window.removeEventListener("blur", this._onHoldToHideWatchdog);
      document.removeEventListener(
        "visibilitychange",
        this._onHoldToHideWatchdog,
      );
      this._onHoldToHideWatchdog = null;
    }
    if (this._onDocumentFocusIn) {
      document.removeEventListener("focusin", this._onDocumentFocusIn);
      this._onDocumentFocusIn = null;
    }
    this._onWorkspaceKeyDown = null;
    this._onWorkspaceKeyUp = null;
  },

  // The workspace carries tabindex="-1" so it can hold focus without joining
  // the tab order. Focus has to be *inside* the workspace for its key bindings
  // to fire at all, and no-ops harmlessly when the element or the API is absent.
  _focusWorkspace() {
    const workspace = this._workspaceEl;
    if (!workspace || typeof workspace.focus !== "function") return;
    if (workspace.contains(document.activeElement)) return;

    try {
      workspace.focus({ preventScroll: true });
    } catch (_) {
      /* jsdom and older engines ignore the options bag */
      workspace.focus();
    }
  },

  _keyboardShortcutAllowed(event) {
    if (!event) return false;
    // A chord belongs to the browser or the OS, never to this surface.
    if (event.metaKey || event.ctrlKey || event.altKey) return false;

    const target = event.target;
    if (
      target &&
      typeof target.closest === "function" &&
      target.closest(EDITABLE_TARGET_SELECTOR)
    ) {
      return false;
    }

    return true;
  },

  // Key repeat re-fires keydown for as long as the key is down, so engaging is
  // guarded rather than counted: one flag, one blank, one release.
  _engageHoldToHide() {
    if (this._holdToHideActive) return;
    if (!this.overlay) return;

    this._holdToHideActive = true;
    this.overlay.style.opacity = "0";
  },

  // Idempotent by contract: every watchdog calls this, and a doubled release
  // must be indistinguishable from a single one. Restores the slider's *current*
  // value rather than one captured at engage time, and never writes the slider.
  _releaseHoldToHide() {
    if (!this._holdToHideActive) return;

    this._holdToHideActive = false;
    if (!this.overlay) return;

    this.overlay.style.opacity = this.opacitySlider
      ? this.opacitySlider.value
      : DEFAULT_OVERLAY_OPACITY;
  },

  // --- Tools panel collapse ---

  // The licensed exception to INV-09D-3: view-only, gates no control, persists
  // nothing. It hides the panel body and relabels its own toggle; it never
  // touches `disabled`.
  _bindToolsToggle() {
    this._toolsCollapsed = false;
    this._toolsChildDisplay = new Map();

    const toggle = document.getElementById("map-alignment-tools-toggle");
    if (!toggle) return;

    this._toolsToggle = toggle;
    this._onToolsToggle = () => this._setToolsCollapsed(!this._toolsCollapsed);
    toggle.addEventListener("click", this._onToolsToggle);
  },

  _unbindToolsToggle() {
    if (this._toolsToggle && this._onToolsToggle) {
      this._toolsToggle.removeEventListener("click", this._onToolsToggle);
    }
    this._toolsToggle = null;
    this._onToolsToggle = null;
    if (this._toolsChildDisplay) this._toolsChildDisplay.clear();
  },

  // Re-resolved from the document each call so it survives a server patch that
  // replaced the panel, and safe to call repeatedly with the same value.
  _setToolsCollapsed(collapsed) {
    const panel = document.getElementById("map-alignment-tools");
    const toggle = document.getElementById("map-alignment-tools-toggle");
    if (!panel || !toggle) return;
    if (!this._toolsChildDisplay) this._toolsChildDisplay = new Map();

    this._toolsCollapsed = collapsed === true;

    Array.from(panel.children).forEach((child) => {
      // The row holding the toggle stays: collapsing away the control that
      // reverses the collapse would strand the operator.
      if (child === toggle || child.contains(toggle)) return;

      if (this._toolsCollapsed) {
        if (!this._toolsChildDisplay.has(child)) {
          this._toolsChildDisplay.set(child, child.style.display);
        }
        // `hidden` alone is a UA-stylesheet rule and loses to the panel's own
        // display utilities, so the inline display is what actually hides it.
        child.style.display = "none";
        child.hidden = true;
      } else {
        const prior = this._toolsChildDisplay.get(child);
        child.style.display = prior === undefined ? "" : prior;
        this._toolsChildDisplay.delete(child);
        child.hidden = false;
      }
    });

    // The toggle is icon-only, so the collapsed state is carried by a
    // presentational attribute the stylesheet flips the chevron on, and by the
    // tooltip and label that name what the next click will do.
    const label = this._toolsCollapsed ? TOOLS_SHOW_LABEL : TOOLS_HIDE_LABEL;
    toggle.setAttribute("data-collapsed", String(this._toolsCollapsed));
    toggle.setAttribute("data-tip", label);
    toggle.setAttribute("aria-label", label);
  },

  // --- In-flight fit readout ---

  // Text plus the presentational `data-fit-state`, into server-rendered
  // elements — the _syncPreviewStatus precedent, and the whole of what the hook
  // is allowed to write here (CRIT-002). No class, no `disabled`.
  _beginMeasuringState() {
    const container = document.getElementById("map-alignment-residual");
    const valueEl = document.getElementById("map-alignment-residual-value");
    if (!container && !valueEl) return;

    this._clearMeasuringResolveTimer();

    // Captured once per in-flight window, so a burst coalescing into one push
    // still restores the reading that stood before the burst began.
    if (!this._measuringRestore) {
      this._measuringRestore = {
        state: container ? container.getAttribute("data-fit-state") : null,
        value: valueEl ? valueEl.textContent : null,
      };
    }

    this._measuringAwaitingPush = true;
    this._writeMeasuringState();
  },

  _writeMeasuringState() {
    const container = document.getElementById("map-alignment-residual");
    const valueEl = document.getElementById("map-alignment-residual-value");

    if (container) {
      container.setAttribute("data-fit-state", RESIDUAL_MEASURING_STATE);
    }
    if (valueEl) valueEl.textContent = RESIDUAL_MEASURING_TEXT;
  },

  // A LiveView patch inside the debounce window re-renders the readout from the
  // fit the server scored *before* this change, putting the superseded number
  // back inside a confident colour band — observed on the real page, where the
  // preview-dirty push lands well before the debounced measurement. Only
  // re-asserted while the measurement has not been sent yet; once it is on the
  // wire the next patch is allowed to be the answer.
  _reassertMeasuringState() {
    if (!this._measuringAwaitingPush) return;
    this._writeMeasuringState();
  },

  // The measurement is on the wire. Stop defending the state so the answer can
  // land, but keep a watchdog: when the server re-scores to an unchanged
  // verdict there is no diff, so no patch ever arrives to clear "Measuring…".
  _awaitMeasuringResolution() {
    this._measuringAwaitingPush = false;
    this._clearMeasuringResolveTimer();
    this._measuringResolveTimer = setTimeout(() => {
      this._measuringResolveTimer = null;
      this._abandonMeasuringState();
    }, MEASURING_RESOLVE_GRACE_MS);
  },

  _clearMeasuringResolveTimer() {
    if (!this._measuringResolveTimer) return;
    clearTimeout(this._measuringResolveTimer);
    this._measuringResolveTimer = null;
  },

  // Called only where the measurement that would replace the reading will never
  // arrive: an open_coordinate_review consumed the window, the hook was
  // destroyed, or the payload carried no alignment for the server to score.
  // "Measuring…" forever is as wrong a readout as a stale number (CRIT-005).
  _abandonMeasuringState() {
    this._clearMeasuringResolveTimer();
    this._measuringAwaitingPush = false;

    const restore = this._measuringRestore;
    this._measuringRestore = null;
    if (!restore) return;

    const container = document.getElementById("map-alignment-residual");
    const valueEl = document.getElementById("map-alignment-residual-value");

    // Only undo the hook's own write. If the server has already resolved the
    // readout in the meantime, its value is the current one and stands.
    if (
      container &&
      restore.state !== null &&
      container.getAttribute("data-fit-state") === RESIDUAL_MEASURING_STATE
    ) {
      container.setAttribute("data-fit-state", restore.state);
    }
    if (
      valueEl &&
      restore.value !== null &&
      valueEl.textContent === RESIDUAL_MEASURING_TEXT
    ) {
      valueEl.textContent = restore.value;
    }
  },

  _handleApplyPreviewTransform(payload) {
    if (!payload || payload.generation !== this.generation) {
      this._logger.warn(
        "MapAlignment: apply_preview_transform rejected (stale generation)",
      );
      return;
    }

    if (!this._isValidAlignmentPayload(payload)) {
      this._logger.warn(
        "MapAlignment: apply_preview_transform rejected (invalid payload)",
        { payload },
      );
      return;
    }

    const img = this.overlay ? this.overlay.querySelector("img") : null;
    const alignment = {
      center_lat: payload.center_lat,
      center_lon: payload.center_lon,
      scale_mpp: payload.scale_mpp,
      rotation_deg: payload.rotation_deg,
    };

    const result = this._cssTransformForAlignment(alignment, img);
    if (!result) {
      this._logger.warn(
        "MapAlignment: apply_preview_transform rejected (geometry not ready)",
      );
      return;
    }

    this._markUserAdjusted();
    this.transform = result;
    this._previewActive = true;
    // The assisted preview is itself the new alignment source, so it does not
    // dirty the preview. It still invalidates any open review because the
    // displayed transform changed (advisory only — INV-4), and it does move the
    // floorplan off its saved position, so it reports unsaved — the one call
    // site where `dirtying` diverges from `previewAdjusted`.
    this._transformDidChange({ previewAdjusted: false, dirtying: true });
  },

  _handleRestoreSavedTransform(payload) {
    if (!payload || payload.generation !== this.generation) {
      this._logger.warn(
        "MapAlignment: restore_saved_transform rejected (stale generation)",
      );
      return;
    }

    // Clearing the unsaved indicator is part of the same LiveView patch that
    // delivers this event, so the map container has already changed height
    // while Leaflet still reports the pre-patch size. Re-measure before
    // deriving the transform, otherwise the restored floorplan lands half the
    // height delta away from its saved position.
    this.leafletMap?.invalidateSize?.();

    if (this.savedAlignment) {
      const img = this.overlay ? this.overlay.querySelector("img") : null;
      const result = this._cssTransformForAlignment(this.savedAlignment, img);
      if (!result) {
        this._logger.warn(
          "MapAlignment: restore_saved_transform rejected (geometry not ready)",
        );
        return;
      }
      this.transform = result;
    } else {
      this.transform = { ...IDENTITY_TRANSFORM };
    }

    this._previewActive = false;
    // Restore replaces the displayed transform; it invalidates any open review
    // (advisory only — INV-4) without dirtying the assisted preview.
    this._transformDidChange({ previewAdjusted: false });
  },

  _handleAlignmentSaved(payload) {
    if (!payload || payload.generation !== this.generation) {
      this._logger.warn(
        "MapAlignment: alignment_saved rejected (stale generation)",
      );
      return;
    }

    if (!this._isValidAlignmentPayload(payload)) {
      this._logger.warn(
        "MapAlignment: alignment_saved rejected (invalid payload)",
        { payload },
      );
      return;
    }

    this.savedAlignment = {
      center_lat: payload.center_lat,
      center_lon: payload.center_lon,
      scale_mpp: payload.scale_mpp,
      rotation_deg: payload.rotation_deg,
    };
    this._previewActive = false;
  },

  _applyTransform() {
    if (!this.overlay) return;
    const { tx, ty, rotation, scale } = this.transform;
    if (tx === 0 && ty === 0 && rotation === 0 && scale === 1) {
      this.overlay.style.transform = "none";
    } else {
      this.overlay.style.transform = `translate(${tx}px, ${ty}px) rotate(${rotation}deg) scale(${scale})`;
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

    const { center_lat, center_lon, scale_mpp, rotation_deg } = payload;

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
    // Server-rendered controls own enabled state. The hook reports image
    // readiness through the generation-tagged bridge instead of mutating
    // controls outside its ignored root. Compatibility mode is only used by
    // older isolated hook fixtures that omit the required generation attribute.
    if (!this._legacyTestMode || !this.applyBtn) return;
    const ready = !!(
      this._naturalSizeImg?.naturalWidth > 0 &&
      this._naturalSizeImg?.naturalHeight > 0
    );
    this.applyBtn.disabled = !ready;
    this.applyBtn.setAttribute("aria-disabled", ready ? "false" : "true");
    this.applyBtn.title = ready ? APPLY_ENABLED_TITLE : APPLY_DISABLED_TITLE;
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

    const diagramCount = records.filter(
      (s) => s.positionMode === "diagram",
    ).length;
    const geoCount = records.filter((s) => s.positionMode === "geo").length;
    statusEl.textContent = previewStatusText(diagramCount, geoCount);
  },

  // Write text into a server-rendered readout element. Text only: enabled
  // state stays server-owned (INV-09D-3), exactly as _syncPreviewStatus does.
  // The element is optional — isolated hook fixtures mount partial DOM and the
  // other-levels controls are conditionally rendered.
  _writeReadout(id, text) {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = text;
  },

  // Current slider values. Every reference is optional: the zoom slider's
  // min/max/value come from the Leaflet map at mount, so the readout reports
  // the slider's live value rather than the server-rendered default.
  _syncSliderReadouts() {
    // The opacity sliders carry their value in the tooltip rather than a
    // readout beside them: the thumb position already shows roughly where the
    // value sits, and the exact percentage is only wanted on demand.
    const opacity = parseFloat(this.opacitySlider?.value);
    if (Number.isFinite(opacity)) {
      this._writeSliderTooltip(
        this.opacitySlider,
        FLOORPLAN_OPACITY_LABEL,
        opacity,
      );
    }

    const zoom = parseFloat(this.zoomSlider?.value);
    if (Number.isFinite(zoom)) {
      this._writeReadout("map-alignment-zoom-value", zoom.toFixed(1));
    }

    const otherOpacity = parseFloat(this.otherOpacitySlider?.value);
    if (Number.isFinite(otherOpacity)) {
      this._writeSliderTooltip(
        this.otherOpacitySlider,
        OTHER_OPACITY_LABEL,
        otherOpacity,
      );
    }
  },

  // The tooltip lives on the slider's wrapper, not the slider: an <input> is a
  // replaced element and cannot render the ::before/::after the tooltip uses.
  // The element is optional for the same reason _writeReadout's is.
  _writeSliderTooltip(slider, label, value) {
    const tip = slider?.closest(".tooltip");
    if (!tip) return;
    tip.setAttribute("data-tip", `${label} · ${Math.round(value * 100)}%`);
  },

  _pushAlignmentEventIfValid(eventName, beforePush) {
    const payload = this._computeAlignment();
    if (!payload) return;
    if (!this._isValidAlignmentPayload(payload)) {
      this._logger.warn(
        "MapAlignmentHook: invalid alignment payload; skipping pushEvent",
        {
          eventName,
          payload,
        },
      );
      return;
    }

    if (beforePush) beforePush();

    this.pushEvent(
      eventName,
      this._legacyTestMode
        ? payload
        : { ...payload, generation: this.generation },
    );
  },

  _emitMapState(state) {
    if (
      this._destroyed ||
      this._legacyTestMode ||
      !this.generation ||
      !MAP_STATES.has(state)
    )
      return;
    this.pushEvent("map_state", { generation: this.generation, state });
  },

  _bindRuntimeStateEvents() {
    const markReady = () => this._emitMapState("ready");
    const markImageryUnavailable = () =>
      this._emitMapState("imagery_unavailable");
    this._tileLayers.filter(Boolean).forEach((layer) => {
      layer.on?.("load", markReady);
      layer.on?.("tileerror", markImageryUnavailable);
    });
    this._onOnline = () => {
      this._emitMapState("reconnecting");
      this._retryMapRuntime();
    };
    this._onOffline = () => this._emitMapState("offline");
    window.addEventListener("online", this._onOnline);
    window.addEventListener("offline", this._onOffline);
  },

  _retryMapRuntime() {
    if (this._destroyed || !this.leafletMap) return;
    this._emitMapState("reconnecting");
    this._tileLayers?.forEach((layer) => layer.redraw?.());
    this.leafletMap.invalidateSize();
    const center = this.leafletMap.getCenter?.();
    if (center) this._fetchBuildings(center.lat, center.lng);
  },

  _adjustTransform(action, coarse) {
    const amount = coarse ? 10 : 2;
    const rotation = coarse ? 5 : 1;
    const scale = coarse ? 1.1 : 1.01;

    switch (action) {
      case "left":
        this.transform.tx -= amount;
        break;
      case "right":
        this.transform.tx += amount;
        break;
      case "up":
        this.transform.ty -= amount;
        break;
      case "down":
        this.transform.ty += amount;
        break;
      case "rotate-left":
        this.transform.rotation -= rotation;
        break;
      case "rotate-right":
        this.transform.rotation += rotation;
        break;
      case "scale-down": {
        const nextScale = clampScaleInDirection(
          this.transform.scale,
          this.transform.scale / scale,
        );
        if (nextScale === this.transform.scale) return;
        this.transform.scale = nextScale;
        break;
      }
      case "scale-up": {
        const nextScale = clampScaleInDirection(
          this.transform.scale,
          this.transform.scale * scale,
        );
        if (nextScale === this.transform.scale) return;
        this.transform.scale = nextScale;
        break;
      }
      default:
        return;
    }
    this._markUserAdjusted();
    this._transformDidChange({ previewAdjusted: true });
  },

  _fetchBuildings(lat, lon) {
    const L = window.L;
    if (!L) return;

    if (this._buildingsLayer && this.leafletMap) {
      this.leafletMap.removeLayer(this._buildingsLayer);
      this._buildingsLayer = null;
    }

    const url = `/map/buildings?lat=${lat}&lon=${lon}&radius=500`;
    fetch(url, { credentials: "same-origin" })
      .then((res) => (res.ok ? res.json() : null))
      .then((geojson) => {
        if (!geojson || !this.leafletMap) return;
        this._buildingsLayer = L.geoJSON(geojson, {
          style: {
            color: paletteColor(
              this.el.closest("#diagram-page"),
              "--diagram-building-outline",
              "#374151",
            ),
            weight: 2,
            fill: false,
            interactive: false,
          },
        }).addTo(this.leafletMap);
      })
      .catch(() => this._emitMapState("buildings_degraded"));
  },

  _handleZoomSliderInput(e) {
    // The readout tracks the slider's live value, so it is written before the
    // no-op guards below.
    this._syncSliderReadouts();

    const map = this.leafletMap;
    if (!map) return;

    const target = parseFloat(e?.target?.value);
    if (!Number.isFinite(target)) return;
    const current = map.getZoom();
    if (target === current) return;

    this._markUserAdjusted();

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

    map.setZoom(target, { animate: false });

    const newCenterPt = map.latLngToContainerPoint(worldCenter);
    this.transform.tx = newCenterPt.x - canvasW / 2;
    this.transform.ty = newCenterPt.y - canvasH / 2;
    this.transform.scale = this.transform.scale * scaleFactor;
    this._transformDidChange({ previewAdjusted: false });
    if (this._otherLevels) this._otherLevels.reposition();
  },

  _renderActiveChildStops(payload = {}) {
    const { stops, level_id: levelId } = payload;
    const received = (stops || []).length;
    if (!this._activePinsRoot) {
      this._logger.warn(
        "MapAlignment: set_active_child_stops received but no #map-alignment-pins-active root",
        { received },
      );
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

    const activeStopColor = paletteColor(
      this.el.closest("#diagram-page"),
      "--diagram-active-stop",
      DIAGRAM_BASE_COLOR,
    );

    this._activePinsRoot.innerHTML = "";
    this._activeChildStops.forEach((s) => {
      const treatment = treatmentForLocationType(
        s.location_type,
        activeStopColor,
      );
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

      appendStopBadges(pin, s.badges, activeStopColor);

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
  },
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

export { parseAlignmentPayload, readActiveAlignment };
export default MapAlignmentHook;
