/**
 * createOtherLevelsLayers
 *
 * Reconciliation module for the "other levels" render layer. Owns only the DOM
 * lifecycle and per-frame positioning of N floorplan overlays and N pin groups.
 * All map math (CSS transform, lat/lon projection) is injected, so the module
 * carries no Leaflet dependency and is unit-testable under jsdom.
 *
 * deps = {
 *   overlaysRoot, pinsRoot,
 *   applyOverlayTransform: (el, alignment) => void,
 *   projectLatLng: (lat, lon) => {x, y},
 *   symbolFor: (locationType) => string,
 * }
 * payload = { active_level_id, levels: [LevelRender] }
 */

const DEFAULT_OPACITY = 0.7;

// The active editable overlay (#map-alignment-overlay) renders at z-index 2.
// Other-level overlays must sit strictly below it so the active overlay stays
// the only drag/rotate/scale target (AC-16).
const OTHER_OVERLAY_Z_INDEX = "1";

function dimensionsForSymbol(symbol) {
  if (symbol === "rect_upright") return { width: "8px", height: "12px" };
  return { width: "10px", height: "10px" };
}

function borderRadiusForSymbol(symbol) {
  if (symbol === "rect_upright" || symbol === "rect_square") return "2px";
  return "9999px";
}

export function createOtherLevelsLayers(deps) {
  const { overlaysRoot, pinsRoot, applyOverlayTransform, projectLatLng, symbolFor } = deps || {};

  if (!overlaysRoot) throw new Error("createOtherLevelsLayers: overlaysRoot is required");
  if (!pinsRoot) throw new Error("createOtherLevelsLayers: pinsRoot is required");
  if (typeof applyOverlayTransform !== "function") {
    throw new Error("createOtherLevelsLayers: applyOverlayTransform must be a function");
  }
  if (typeof projectLatLng !== "function") {
    throw new Error("createOtherLevelsLayers: projectLatLng must be a function");
  }
  if (typeof symbolFor !== "function") {
    throw new Error("createOtherLevelsLayers: symbolFor must be a function");
  }

  const overlays = new Map();
  const pinGroups = new Map();
  let opacity = DEFAULT_OPACITY;

  function createOverlay(levelId) {
    const overlayEl = document.createElement("div");
    overlayEl.className = "absolute inset-0";
    overlayEl.style.pointerEvents = "none";
    overlayEl.style.zIndex = OTHER_OVERLAY_Z_INDEX;
    overlayEl.dataset.otherLevelId = String(levelId);
    overlayEl.style.transformOrigin = "center";

    const img = document.createElement("img");
    img.className = "absolute inset-0 w-full h-full object-contain select-none pointer-events-none";
    img.draggable = false;
    img.alt = "Other level floorplan";
    img.style.opacity = String(opacity);

    overlayEl.appendChild(img);
    overlaysRoot.appendChild(overlayEl);

    const record = { overlayEl, img, alignment: null };
    overlays.set(levelId, record);
    return record;
  }

  function applyFloorplan(levelId, floorplan) {
    const record = overlays.get(levelId) || createOverlay(levelId);
    if (record.img.getAttribute("src") !== floorplan.url) {
      record.img.setAttribute("src", floorplan.url);
    }
    record.alignment = floorplan;
    applyOverlayTransform(record.img, floorplan);
  }

  function createMarker(levelId, color, stop) {
    const symbol = symbolFor(stop.location_type);
    const { width, height } = dimensionsForSymbol(symbol);

    const pin = document.createElement("div");
    pin.className = "map-pin absolute -translate-x-1/2 -translate-y-1/2 group pointer-events-auto";
    pin.style.width = width;
    pin.style.height = height;

    const dot = document.createElement("div");
    dot.className = "w-full h-full border";
    dot.style.backgroundColor = color;
    dot.style.opacity = "0.3";
    dot.style.borderColor = color;
    dot.style.borderStyle = "dashed";
    dot.style.borderWidth = "1.5px";
    dot.style.borderRadius = borderRadiusForSymbol(symbol);
    pin.appendChild(dot);

    const tip = document.createElement("div");
    tip.className =
      "absolute left-1/2 bottom-full mb-1 -translate-x-1/2 whitespace-nowrap rounded bg-black/80 text-white text-xs px-1.5 py-0.5 opacity-0 group-hover:opacity-100 pointer-events-none";
    tip.textContent = stop.label || "";
    pin.appendChild(tip);

    return { lat: stop.lat, lon: stop.lon, el: pin };
  }

  function applyStops(levelId, color, stops) {
    let group = pinGroups.get(levelId);
    if (!group) {
      const pinGroupEl = document.createElement("div");
      pinGroupEl.className = "absolute inset-0 pointer-events-none";
      pinGroupEl.dataset.otherLevelId = String(levelId);
      pinsRoot.appendChild(pinGroupEl);
      group = { pinGroupEl, markers: [] };
      pinGroups.set(levelId, group);
    }

    group.pinGroupEl.innerHTML = "";
    group.markers = stops.map((stop) => {
      const marker = createMarker(levelId, color, stop);
      group.pinGroupEl.appendChild(marker.el);
      positionMarker(marker);
      return marker;
    });
  }

  function positionMarker(marker) {
    const pt = projectLatLng(marker.lat, marker.lon);
    if (!pt) return;
    marker.el.style.left = `${pt.x}px`;
    marker.el.style.top = `${pt.y}px`;
  }

  function removeOverlay(levelId) {
    const record = overlays.get(levelId);
    if (!record) return;
    record.overlayEl.remove();
    overlays.delete(levelId);
  }

  function removePinGroup(levelId) {
    const group = pinGroups.get(levelId);
    if (!group) return;
    group.pinGroupEl.remove();
    pinGroups.delete(levelId);
  }

  function update(payload = {}) {
    const levels = payload.levels || [];
    const seenFloorplan = new Set();
    const seenStops = new Set();

    levels.forEach((level) => {
      const levelId = level.level_id;

      if (level.floorplan) {
        applyFloorplan(levelId, level.floorplan);
        seenFloorplan.add(levelId);
      }

      const stops = level.stops || [];
      if (stops.length > 0) {
        applyStops(levelId, level.color, stops);
        seenStops.add(levelId);
      }
    });

    Array.from(overlays.keys()).forEach((levelId) => {
      if (!seenFloorplan.has(levelId)) removeOverlay(levelId);
    });

    Array.from(pinGroups.keys()).forEach((levelId) => {
      if (!seenStops.has(levelId)) removePinGroup(levelId);
    });
  }

  function reposition() {
    overlays.forEach((record) => {
      if (record.alignment) applyOverlayTransform(record.img, record.alignment);
    });

    pinGroups.forEach((group) => {
      group.markers.forEach(positionMarker);
    });
  }

  function setOpacity(value) {
    opacity = value;
    overlays.forEach((record) => {
      record.img.style.opacity = String(value);
    });
  }

  function destroy() {
    overlays.forEach((record) => record.overlayEl.remove());
    pinGroups.forEach((group) => group.pinGroupEl.remove());
    overlays.clear();
    pinGroups.clear();
  }

  return { update, reposition, setOpacity, destroy };
}

export default createOtherLevelsLayers;
