/**
 * Static pathway floorplan for the Schedule closures locator and the access
 * preview.
 *
 * The island element is ignored by LiveView (`phx-update="ignore"`): its
 * children are owned here, and only its `data-*` attributes cross an update.
 * This hook therefore owns the image's natural dimensions, the static SVG
 * overlay and the one roving tab stop, and it never writes geometry:
 * activation either asks the server to select a pathway
 * (`data-select-event`, the same event the pathway list sends) or, in the
 * access preview, toggles a client-side highlight on the existing cause rows.
 *
 * Coordinates are the stored width-normalized diagram coordinates, normalized
 * with the same helper the mutation-time preview uses, so nothing here ever
 * turns browser geometry back into data.
 */
import { normalizeDiagramPoint } from "./floorplan_preview_points.js";

const MARKER_RADIUS = 2.3;

// Stop names and the Closed word render at a fixed screen size: SVG lengths
// are user units, so the hook computes the attributes from the image's
// rendered width. These are the label metrics the collision check uses.
const STOP_NAME_FONT_PX = 13;
const CLOSED_WORD_WIDTH_PX = 42;
const CLOSED_WORD_HEIGHT_PX = 16;

/**
 * Returns the SVG viewBox for an image's natural pixel dimensions.
 *
 * Stored diagram coordinates are width-normalized on both axes, so one user
 * unit is one percent of the image width and the viewBox height is
 * `100 * height / width`. The SVG box is the image box, so the mapping lands a
 * stored coordinate exactly on its pixel.
 */
export function floorplanViewBox(naturalWidth, naturalHeight) {
  if (!Number.isFinite(naturalWidth) || !Number.isFinite(naturalHeight)) return null;
  if (naturalWidth <= 0 || naturalHeight <= 0) return null;

  const height = Math.round((100 * naturalHeight * 1000) / naturalWidth) / 1000;

  return `0 0 100 ${height}`;
}

function parseJson(value, fallback) {
  if (typeof value !== "string" || value === "") return fallback;

  try {
    const parsed = JSON.parse(value);
    return parsed === null || parsed === undefined ? fallback : parsed;
  } catch (_error) {
    return fallback;
  }
}

function escapeMarkup(value) {
  return String(value === null || value === undefined ? "" : value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function geometry(pathway) {
  const from = normalizeDiagramPoint(pathway.from);
  const to = normalizeDiagramPoint(pathway.to);

  if (from && to) return { kind: "line", from, to };
  if (from) return { kind: "marker", at: from, stopId: pathway.from.stop_id };
  if (to) return { kind: "marker", at: to, stopId: pathway.to.stop_id };

  return null;
}

// The reference's closed-word placement: the first candidate that does not
// collide with a stop symbol (or an entrance name when names are shown), else
// the first candidate. Sizes are converted from screen pixels with `unitPx`
// (rendered width / 100), because the label renders at a fixed screen size.
export function closedLabelPosition(x, y, boxes, unitPx = 10) {
  const scale = Number.isFinite(unitPx) && unitPx > 0 ? unitPx : 10;
  const WIDTH = CLOSED_WORD_WIDTH_PX / scale;
  const HEIGHT = CLOSED_WORD_HEIGHT_PX / scale;

  const candidates = [
    [2.2, 6.6, "start"],
    [-2.2, 6.6, "end"],
    [0, 6.6, "middle"],
    [3.6, 1.1, "start"],
    [-3.6, 1.1, "end"],
    [0, -3.6, "middle"],
  ];

  for (const [dx, dy, anchor] of candidates) {
    const x0 =
      anchor === "start" ? x + dx : anchor === "end" ? x + dx - WIDTH : x + dx - WIDTH / 2;
    const y0 = y + dy - HEIGHT + 0.6;
    const collides = boxes.some(
      ([bx0, by0, bx1, by1]) => x0 < bx1 && x0 + WIDTH > bx0 && y0 < by1 && y0 + HEIGHT > by0,
    );

    if (!collides) return { x: x + dx, y: y + dy, anchor };
  }

  return { x: x + 2.2, y: y + 6.6, anchor: "start" };
}

function closedWord(x, y, boxes, unitPx) {
  const { x: cx, y: cy, anchor } = closedLabelPosition(x, y, boxes, unitPx);

  return `<text x="${cx}" y="${cy}" text-anchor="${anchor}" class="evo-fp-closed-word fill-evo-closed-ink" ${textScale(unitPx)} font-weight="700">Closed</text>`;
}

// SVG font sizes and strokes are user units, and one user unit is `unitPx`
// screen pixels, so a label that must render at 13px is `13 / unitPx` units on
// any image width. The white outline keeps it readable over a line or a stop
// symbol.
function textScale(unitPx) {
  const scale = Number.isFinite(unitPx) && unitPx > 0 ? unitPx : 10;
  const size = (STOP_NAME_FONT_PX / scale).toFixed(3);
  const outline = (3 / scale).toFixed(3);

  return `font-size="${size}" paint-order="stroke" stroke="white" stroke-width="${outline}" stroke-linejoin="round"`;
}

function stopBoxes(stops, showStopNames, unitPx) {
  return stops.flatMap((stop) => {
    const point = normalizeDiagramPoint(stop);
    if (!point) return [];

    const boxes = [[point.x - 2.6, point.y - 2.6, point.x + 2.6, point.y + 2.6]];

    if (showStopNames && stop.type === 2) {
      const ty = point.y + (point.y > 50 ? 5.2 : 1.1);
      const name = stop.name === null || stop.name === undefined ? "" : String(stop.name);
      const width = (name.length * STOP_NAME_FONT_PX * 0.58) / unitPx;
      boxes.push([point.x + 2.8, ty - 2.4, point.x + 2.8 + width, ty + 0.8]);
    }

    return boxes;
  });
}

function groupAttributes(pathway, state) {
  return [
    `data-pathway-id="${escapeMarkup(pathway.pathway_id)}"`,
    `data-pathway-uuid="${escapeMarkup(pathway.id)}"`,
    `role="button"`,
    `aria-label="${escapeMarkup(pathway.label)}, ${escapeMarkup(pathway.pathway_id)}"`,
    `tabindex="${state.roving ? "0" : "-1"}"`,
    state.selected ? 'aria-current="true"' : "",
    state.highlighted ? 'data-highlighted="true"' : "",
    'class="evo-fp-group cursor-pointer"',
  ]
    .filter(Boolean)
    .join(" ");
}

function closuresDot(x, y) {
  return `<circle cx="${x}" cy="${y}" r="0.75" class="evo-fp-dot fill-evo-dot stroke-white" stroke-width="1.5" vector-effect="non-scaling-stroke"/>`;
}

function lineMarkup(pathway, geo, state, markerStops, boxes, unitPx) {
  const { from, to } = geo;
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const length = Math.hypot(dx, dy) || 1;
  const trimStart = markerStops.has(pathway.from && pathway.from.stop_id)
    ? Math.min(MARKER_RADIUS + 0.4, length / 2 - 0.3)
    : 0;
  const trimEnd = markerStops.has(pathway.to && pathway.to.stop_id)
    ? Math.min(MARKER_RADIUS + 0.4, length / 2 - 0.3)
    : 0;
  const x1 = from.x + (dx / length) * trimStart;
  const y1 = from.y + (dy / length) * trimStart;
  const x2 = to.x - (dx / length) * trimEnd;
  const y2 = to.y - (dy / length) * trimEnd;
  const line = (className, width, a = { x: x1, y: y1 }, b = { x: x2, y: y2 }) =>
    `<line x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}" class="${className}" stroke-width="${width}" stroke-linecap="round" vector-effect="non-scaling-stroke"/>`;

  const closed = state.closed;
  const main = state.selected
    ? "evo-fp-line stroke-action"
    : closed
      ? "evo-fp-line stroke-evo-closed"
      : "evo-fp-line stroke-evo-pathway group-hover:stroke-evo-pathway-hover";
  const mainWidth = state.selected ? 5.5 : 3;
  const dash = closed ? ' stroke-dasharray="7 5"' : "";
  const midX = (from.x + to.x) / 2;
  const midY = (from.y + to.y) / 2;

  return `<g ${groupAttributes(pathway, state)}>
    <line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" class="evo-fp-hit" stroke="transparent" stroke-width="22" pointer-events="stroke" vector-effect="non-scaling-stroke"/>
    ${line("evo-fp-focus stroke-transparent group-focus-visible:stroke-focus group-data-[highlighted=true]:stroke-focus", state.selected ? 15 : 12)}
    ${line("evo-fp-casing stroke-white", state.selected ? 10 : 7)}
    <line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" class="${main}" stroke-width="${mainWidth}"${dash} stroke-linecap="round" vector-effect="non-scaling-stroke"/>
    ${state.hasClosures && !closed ? closuresDot(midX, midY) : ""}
    ${
      closed
        ? `<circle cx="${midX}" cy="${midY}" r="2.3" class="evo-fp-closed-marker fill-evo-closed-bg stroke-evo-closed" stroke-width="1.6" vector-effect="non-scaling-stroke"/>
           <path d="M${midX - 1} ${midY - 1}L${midX + 1} ${midY + 1}M${midX + 1} ${midY - 1}L${midX - 1} ${midY + 1}" class="evo-fp-closed-cross stroke-evo-closed-ink" stroke-width="1.8" stroke-linecap="round" vector-effect="non-scaling-stroke"/>
           ${closedWord(midX, midY, boxes, unitPx)}`
        : ""
    }
  </g>`;
}

function markerMarkup(pathway, geo, state) {
  const { x, y } = geo.at;
  const bodyClass = state.selected
    ? "evo-fp-marker-body fill-action stroke-action"
    : "evo-fp-marker-body fill-white stroke-evo-pathway group-hover:stroke-evo-pathway-hover";
  const iconClass = state.selected
    ? "evo-fp-marker-icon fill-none stroke-white"
    : "evo-fp-marker-icon fill-none stroke-evo-node";

  return `<g ${groupAttributes(pathway, state)} transform="translate(${x} ${y})">
    <circle r="0.01" class="evo-fp-marker-hit" fill="transparent" stroke="transparent" stroke-width="44" vector-effect="non-scaling-stroke"/>
    <circle r="${MARKER_RADIUS + 0.9}" class="evo-fp-focus stroke-transparent group-focus-visible:stroke-focus group-data-[highlighted=true]:stroke-focus" stroke-width="2.5" vector-effect="non-scaling-stroke"/>
    ${
      state.closed
        ? `<circle r="2.6" class="evo-fp-marker-body fill-evo-closed-bg stroke-evo-closed" stroke-width="2" stroke-dasharray="3 2" vector-effect="non-scaling-stroke"/>
           <path d="M-1.1 -1.1L1.1 1.1M1.1 -1.1L-1.1 1.1" class="evo-fp-marker-cross stroke-evo-closed-ink" stroke-width="2" stroke-linecap="round" vector-effect="non-scaling-stroke"/>`
        : `<circle r="${MARKER_RADIUS}" class="${bodyClass}" stroke-width="${state.selected ? 2.5 : 2}" vector-effect="non-scaling-stroke"/>
           <path d="M0 -1.35V1.35M-0.8 -0.55 0 -1.35 0.8 -0.55M-0.8 0.55 0 1.35 0.8 0.55" class="${iconClass}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>`
    }
    ${state.hasClosures && !state.closed ? closuresDot(1.75, -1.75) : ""}
  </g>`;
}

function stopMarkup(stop, markerStops, showStopNames, unitPx) {
  const point = normalizeDiagramPoint(stop);
  if (!point) return "";

  const title = `<title>${escapeMarkup(stop.name)} (${escapeMarkup(stop.stop_id)})</title>`;
  const { x, y } = point;

  if (stop.type === 2) {
    const name = showStopNames
      ? `<text x="${x + 2.8}" y="${y + (y > 50 ? 5.2 : 1.1)}" class="evo-fp-stop-name fill-evo-entrance" ${textScale(unitPx)} font-weight="650">${escapeMarkup(stop.name)}</text>`
      : "";

    return `<rect x="${x - 1.5}" y="${y - 1.5}" width="3" height="3" rx="0.4" class="evo-fp-entrance fill-evo-entrance stroke-white" stroke-width="1.5" vector-effect="non-scaling-stroke">${title}</rect>${name}`;
  }

  if (markerStops.has(stop.stop_id)) return "";

  return `<circle cx="${x}" cy="${y}" r="0.9" class="evo-fp-node fill-evo-node stroke-white" stroke-width="1.2" vector-effect="non-scaling-stroke">${title}</circle>`;
}

/**
 * Builds the static overlay markup for one floorplan island.
 *
 * Same-level pathways are lines between their two stored endpoints;
 * cross-level (or partly unplaced) pathways are a marker at their one plotted
 * endpoint. Every pathway is one labelled button, exactly one of them holds the
 * roving tab stop, and a closed pathway keeps the dashed error line, the
 * cross and the word `Closed` in addition to its colour.
 */
export function buildFloorplanSvg({
  stops = [],
  pathways = [],
  closedIds = [],
  selectedId = null,
  rovingId = null,
  highlightedId = null,
  showStopNames = false,
  unitPx = 10,
} = {}) {
  const closed = new Set(closedIds);
  const prepared = pathways.flatMap((pathway) => {
    const geo = geometry(pathway);
    return geo === null ? [] : [{ pathway, geo }];
  });
  const markerStops = new Set(
    prepared.filter(({ geo }) => geo.kind === "marker").map(({ geo }) => geo.stopId),
  );
  const boxes = stopBoxes(stops, showStopNames, unitPx);

  const state = (pathway) => ({
    selected: pathway.id !== undefined && pathway.id === selectedId,
    highlighted: pathway.id !== undefined && pathway.id === highlightedId,
    closed: closed.has(pathway.pathway_id),
    hasClosures: Number(pathway.closures) > 0,
    roving: pathway.id !== undefined && pathway.id === rovingId,
  });

  const lines = prepared.filter(({ geo }) => geo.kind === "line");
  const markers = prepared.filter(({ geo }) => geo.kind === "marker");
  // Two pathways between the same two stops overlap exactly. The closed ones
  // are drawn last so their dashed line, their cross and their hit target stay
  // on top - a reader pointing at the closed pathway must be able to reach it -
  // and the selected pathway is drawn above everything else.
  const orderedLines = [
    ...lines.filter(({ pathway }) => !state(pathway).closed && !state(pathway).selected),
    ...lines.filter(({ pathway }) => state(pathway).closed && !state(pathway).selected),
    ...lines.filter(({ pathway }) => state(pathway).selected),
  ];

  const lineMarkupAll = orderedLines
    .map(({ pathway, geo }) =>
      lineMarkup(pathway, geo, state(pathway), markerStops, boxes, unitPx),
    )
    .join("");
  const markerMarkupAll = markers
    .map(({ pathway, geo }) => markerMarkup(pathway, geo, state(pathway)))
    .join("");
  const nodes = `<g class="pointer-events-none">${stops
    .map((stop) => stopMarkup(stop, markerStops, showStopNames, unitPx))
    .join("")}</g>`;

  return `${lineMarkupAll}${nodes}${markerMarkupAll}`;
}

function closureCount(count) {
  return count === 1 ? "1 closure" : `${count} closures`;
}

function pathwayIdFor(node) {
  if (!node || typeof node.closest !== "function") return null;

  const group = node.closest("[data-pathway-uuid]");

  return group ? group.dataset.pathwayUuid : null;
}

const PathwayEvolutionsFloorplan = {
  mounted() {
    this._rovingId = null;
    this._highlightedId = null;
    this._lastSelectedId = null;
    this._restoreFocusId = null;
    this._failed = false;

    this._image = this.el.querySelector("[data-floorplan-image]");
    this._svg = this.el.querySelector("[data-floorplan-svg]");
    this._caption = this.el.querySelector("[data-floorplan-caption]");
    // The server renders the untouched caption's own words; the hook restores
    // them instead of owning a second copy of the copy.
    this._emptyCaption = this._caption ? this._caption.textContent.trim() : "";

    if (this._image) {
      this._image.addEventListener("load", () => this._maybeRender());
      this._image.addEventListener("error", () => this._handleImageError());
      this._syncImage();
    }

    if (this._svg) {
      this._svg.addEventListener("click", (event) => {
        const id = pathwayIdFor(event.target);
        if (id) this._activate(id);
      });
      this._svg.addEventListener("keydown", (event) => this._keydown(event));
      this._svg.addEventListener("pointerover", (event) => this._hover(pathwayIdFor(event.target)));
      this._svg.addEventListener("pointerleave", () => this._hover(null));
      this._svg.addEventListener("focusin", (event) => this._hover(pathwayIdFor(event.target)));
      this._svg.addEventListener("focusout", () => this._hover(null));
    }

    this._maybeRender();
  },

  updated() {
    this._syncImage();
    this._maybeRender();
  },

  destroyed() {
    this._failed = true;
  },

  _syncImage() {
    if (!this._image) return false;

    const url = this.el.dataset.imageUrl || "";
    if (url === "" || this._image.getAttribute("src") === url) return false;

    this._failed = false;
    this._image.src = url;

    return true;
  },

  _maybeRender() {
    if (this._failed || !this._image || !this._svg) return;

    if (this._image.naturalWidth > 0 && this._image.naturalHeight > 0) return this._render();

    if (this._image.complete) this._handleImageError();
  },

  _handleImageError() {
    if (this._failed) return;

    this._failed = true;

    // The whole panel goes with the image: a level label, an empty caption and
    // a legend with nothing above them would be worse than the note alone. The
    // note and the pathway list live outside the panel, so the fallback stays
    // visible and usable.
    const panel = this.el.closest("[data-floorplan-panel]");
    if (panel) panel.hidden = true;

    const note = document.getElementById(this.el.dataset.noteId || "");
    if (note) note.hidden = false;

    // The Floorplan/List switch has nothing to switch to once the image is gone.
    const toggle = document.getElementById(this.el.dataset.toggleId || "");
    if (toggle) toggle.hidden = true;

    const list = document.getElementById(this.el.dataset.listId || "");
    if (list) list.classList.remove("md:hidden");

    if (this._caption) this._caption.textContent = "";
  },

  _render() {
    const viewBox = floorplanViewBox(this._image.naturalWidth, this._image.naturalHeight);
    if (viewBox === null) return this._handleImageError();

    this._svg.setAttribute("viewBox", viewBox);

    const pathways = parseJson(this.el.dataset.pathways, []);
    const order = pathways.map((pathway) => pathway.id).filter(Boolean);
    const selectedId = this.el.dataset.selectedId || null;
    const focused = pathwayIdFor(document.activeElement);
    const inside = document.activeElement && this.el.contains(document.activeElement);
    let roving = this._rovingId;

    if (inside && focused) {
      roving = focused;
    } else if (selectedId !== this._lastSelectedId || !order.includes(roving)) {
      roving = selectedId || order[0] || null;
    }

    const html = buildFloorplanSvg({
      stops: parseJson(this.el.dataset.stops, []),
      pathways,
      closedIds: parseJson(this.el.dataset.closedIds, []),
      selectedId,
      rovingId: roving,
      highlightedId: this._highlightedId,
      showStopNames: this.el.dataset.showStopNames === "true",
      unitPx: this._unitPx(),
    });

    this._rovingId = roving;
    this._lastSelectedId = selectedId;

    // The pathway under the reader's focus keeps its own DOM node: the fresh
    // markup supplies its state, but the node already in the reader's hands is
    // moved into place instead of being recreated, so a patch that lands
    // between two key presses can never detach the node the next press is
    // addressed to.
    const kept =
      inside && focused ? this._svg.querySelector(`[data-pathway-uuid="${focused}"]`) : null;

    this._svg.innerHTML = html;

    if (kept) {
      const redrawn = this._svg.querySelector(`[data-pathway-uuid="${focused}"]`);
      if (redrawn) redrawn.replaceWith(this._adoptRedrawnState(redrawn, kept));
    }

    if (inside && focused) this._focusPathway(focused);
    this._restoreKeyboardFocus();

    this._renderCaption();
    this._renderCauseHighlight();
  },

  // The kept node takes the redrawn node's attributes and children, so its
  // state is exactly what the fresh render computed while its identity is the
  // one the reader already holds.
  _adoptRedrawnState(redrawn, kept) {
    for (const attribute of Array.from(kept.attributes)) {
      if (!redrawn.hasAttribute(attribute.name)) kept.removeAttribute(attribute.name);
    }

    for (const attribute of Array.from(redrawn.attributes)) {
      kept.setAttribute(attribute.name, attribute.value);
    }

    kept.replaceChildren(...Array.from(redrawn.childNodes));

    return kept;
  },

  _focusPathway(id) {
    if (!this._svg || !id) return;

    const group = this._svg.querySelector(`[data-pathway-uuid="${id}"]`);
    if (!group) return;

    const roving = this._svg.querySelector('[tabindex="0"]');
    if (roving && roving !== group) roving.setAttribute("tabindex", "-1");

    group.setAttribute("tabindex", "0");
    if (typeof group.focus === "function") group.focus();
  },

  _pathway(id) {
    return parseJson(this.el.dataset.pathways, []).find((pathway) => pathway.id === id) || null;
  },

  // How many screen pixels one diagram unit spans, so a fixed-size label can
  // still be placed against the stored geometry. jsdom reports a zero box, so
  // the reference's own 10px-per-unit default covers it.
  _unitPx() {
    const width = this._svg ? this._svg.getBoundingClientRect().width : 0;

    return width > 0 ? width / 100 : 10;
  },

  _renderCaption() {
    if (!this._caption) return;

    const pathway = this._hoveredId
      ? this._pathway(this._hoveredId)
      : this._pathway(this._rovingId) || this._pathway(this.el.dataset.selectedId);

    if (!pathway) {
      this._caption.textContent = this._emptyCaption;
      return;
    }

    const selected = pathway.id === this.el.dataset.selectedId;
    const prefix = selected ? "Selected: " : "";
    const closures = Number(pathway.closures) > 0 ? ` · ${closureCount(Number(pathway.closures))}` : "";

    this._caption.textContent = `${prefix}${pathway.label} ${pathway.pathway_id}${closures}`;
  },

  _hover(id) {
    this._hoveredId = id || null;
    this._renderCaption();
  },

  _activate(id) {
    const selectEvent = this.el.dataset.selectEvent;

    if (selectEvent) {
      this.pushEvent(selectEvent, { id });
      return;
    }

    this._highlightedId = this._highlightedId === id ? null : id;
    this._render();
  },

  // Selecting a pathway opens the editor on it, and the server moves focus into
  // that form — re-asserting that move on the next animation frame. A reader
  // who activated the pathway with Enter or Space keeps their place on the
  // floorplan instead: the restore is queued as a microtask from the update
  // this selection rendered, so its frame is registered after the server's own
  // and therefore runs last.
  _restoreKeyboardFocus() {
    const id = this._restoreFocusId;
    if (!id) return;

    this._restoreFocusId = null;

    queueMicrotask(() => {
      if (this._rovingId !== id) return;

      const nextFrame = typeof window !== "undefined" && window.requestAnimationFrame;
      if (!nextFrame) return this._focusPathway(id);

      nextFrame(() => {
        if (this._rovingId === id) this._focusPathway(id);
      });
    });
  },

  _renderCauseHighlight() {
    const pathways = parseJson(this.el.dataset.pathways, []);
    const highlighted = pathways.find((pathway) => pathway.id === this._highlightedId);
    const pathwayId = highlighted ? highlighted.pathway_id : null;

    document.querySelectorAll("[data-cause-pathway]").forEach((row) => {
      row.classList.toggle("evo-cause-highlight", pathwayId !== null && row.dataset.causePathway === pathwayId);
    });
  },

  _keydown(event) {
    const id = pathwayIdFor(event.target);
    if (!id) return;

    const order = parseJson(this.el.dataset.pathways, [])
      .map((pathway) => pathway.id)
      .filter(Boolean);
    const index = order.indexOf(id);
    if (index === -1) return;

    let next = null;

    if (event.key === "ArrowRight" || event.key === "ArrowDown") {
      next = order[(index + 1) % order.length];
    } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
      next = order[(index - 1 + order.length) % order.length];
    } else if (event.key === "Home") {
      next = order[0];
    } else if (event.key === "End") {
      next = order[order.length - 1];
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      this._rovingId = id;
      this._restoreFocusId = id;
      this._activate(id);
      return;
    }

    if (!next) return;

    // Moving the tab stop is a DOM move, not a redraw: re-rendering here would
    // rebuild the overlay from attributes that still name the old selection,
    // and the reader's focus would bounce back to the pathway they left.
    event.preventDefault();
    this._rovingId = next;

    const current = this._svg.querySelector(`[data-pathway-uuid="${id}"]`);
    if (current) current.setAttribute("tabindex", "-1");

    this._focusPathway(next);
    this._renderCaption();
  },
};

export default PathwayEvolutionsFloorplan;
