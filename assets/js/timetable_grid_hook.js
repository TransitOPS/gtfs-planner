/**
 * Keyboard navigation for the Schedules timetable grid.
 *
 * The server renders every stop and timing cell with tabindex="-1"; this hook
 * owns one roving cursor (tabindex="0" plus the is-cursor ring). Arrows move
 * within and across rows and sections, Home/End reach the row's edges,
 * Cmd/Ctrl+Up/Down reach the grid's first and last row, Page Up/Down move by
 * the rows the table region shows, and Tab keeps the browser default so focus
 * can leave the grid. Clicking a cell moves the cursor there.
 *
 * LiveView re-streams sections after every write, which replaces the cells the
 * cursor points at, so beforeUpdate() remembers whether the grid held focus
 * and updated() re-applies the cursor to the re-rendered cell and restores
 * that focus (falling back to the same row when the remembered trip is gone).
 * Movement scrolls with the table region's scroll padding so the sticky grid
 * bar never covers the cursor.
 */
const CELL_SELECTOR = 'td[id^="cell-"]';
const SCROLL_REGION_SELECTOR = '[id$="-table-container"]';
const TYPING_SELECTOR = "input, textarea, select, [contenteditable]";
const NAVIGATION_KEYS = new Set([
  "ArrowDown",
  "ArrowUp",
  "ArrowLeft",
  "ArrowRight",
  "Home",
  "End",
  "PageDown",
  "PageUp",
]);
// The fallback page step keeps Page Up/Down useful when the region's layout
// cannot be measured; browsers measure the visible rows instead.
const PAGE_ROWS_FALLBACK = 10;

const TimetableGrid = {
  mounted() {
    this._cursorCell = null;
    this._cursor = null;
    this._columnIndex = 0;
    this._rowIndex = 0;
    this._restoreFocus = false;

    this._onKeydown = (event) => this._handleKeydown(event);
    this._onClick = (event) => this._handleClick(event);
    this._onFocusIn = () => this.el.classList.remove("grid-idle");
    this._onFocusOut = (event) => {
      if (!this.el.contains(event.relatedTarget)) this.el.classList.add("grid-idle");
    };

    this.el.addEventListener("keydown", this._onKeydown);
    this.el.addEventListener("click", this._onClick);
    this.el.addEventListener("focusin", this._onFocusIn);
    this.el.addEventListener("focusout", this._onFocusOut);

    this.el.classList.add("grid-idle");
  },

  beforeUpdate() {
    this._restoreFocus = this.el.contains(document.activeElement);
  },

  updated() {
    const focus = this._restoreFocus;
    this._restoreFocus = false;
    if (!this._cursor && !this._cursorCell) return;

    this._applyCursor({ focus });
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown);
    this.el.removeEventListener("click", this._onClick);
    this.el.removeEventListener("focusin", this._onFocusIn);
    this.el.removeEventListener("focusout", this._onFocusOut);
    this._onKeydown = null;
    this._onClick = null;
  },

  _cells() {
    return Array.from(this.el.querySelectorAll(CELL_SELECTOR));
  },

  _rows() {
    const rows = [];
    const byRow = new Map();

    for (const cell of this._cells()) {
      const row = cell.closest("tr");
      if (!row) continue;

      let entry = byRow.get(row);
      if (!entry) {
        entry = { row, cells: [] };
        byRow.set(row, entry);
        rows.push(entry);
      }

      entry.cells.push(cell);
    }

    return rows;
  },

  _handleKeydown(event) {
    if (event.defaultPrevented) return;

    const target = event.target;
    if (!(target instanceof Element) || target.closest(TYPING_SELECTOR)) return;

    const cell = target.closest(CELL_SELECTOR);

    // A navigation key pressed on the table region itself (its focusable
    // scroll area) enters the grid at that section's first cell, so a keyboard
    // user reaches the cursor without a pointer.
    if (!cell || !this.el.contains(cell)) {
      if (!NAVIGATION_KEYS.has(event.key)) return;

      const region = target.closest(SCROLL_REGION_SELECTOR);
      const first =
        region && this.el.contains(region) ? region.querySelector(CELL_SELECTOR) : null;
      if (!first) return;

      event.preventDefault();
      this._setCursor(first, { focus: true });
      return;
    }

    const modifier = event.metaKey || event.ctrlKey;

    switch (event.key) {
      case "ArrowDown":
      case "ArrowUp": {
        event.preventDefault();
        const delta = event.key === "ArrowDown" ? 1 : -1;
        if (modifier) this._moveV(cell, 0, { to: delta > 0 ? "last" : "first" });
        else this._moveV(cell, delta);
        return;
      }
      case "ArrowRight":
      case "ArrowLeft": {
        // Cmd/Ctrl+Left/Right belong to the browser's Back and Forward.
        if (modifier) return;
        event.preventDefault();
        this._moveH(cell, event.key === "ArrowRight" ? 1 : -1);
        return;
      }
      case "Home":
      case "End": {
        if (modifier) return;
        event.preventDefault();
        this._moveH(cell, 0, { to: event.key === "Home" ? "first" : "last" });
        return;
      }
      case "PageDown":
      case "PageUp": {
        event.preventDefault();
        const pages = this._pageRows(cell);
        this._moveV(cell, event.key === "PageDown" ? pages : -pages);
        return;
      }
      default:
        return;
    }
  },

  _handleClick(event) {
    if (event.defaultPrevented) return;

    const cell = event.target.closest(CELL_SELECTOR);
    if (!cell || !this.el.contains(cell)) return;

    this._setCursor(cell, { focus: true });
  },

  _moveH(reference, delta, { to = null } = {}) {
    const row = this._rows().find((entry) => entry.cells.includes(reference));
    if (!row) return;

    const index = row.cells.indexOf(reference);
    const next = to === "first" ? 0 : to === "last" ? row.cells.length - 1 : index + delta;
    const clamped = Math.max(0, Math.min(row.cells.length - 1, next));

    this._setCursor(row.cells[clamped], { focus: true });
  },

  _moveV(reference, delta, { to = null } = {}) {
    const rows = this._rows();
    if (rows.length === 0) return;

    const current = Math.max(0, rows.findIndex((entry) => entry.cells.includes(reference)));
    const target = to === "first" ? 0 : to === "last" ? rows.length - 1 : current + delta;
    const row = rows[Math.max(0, Math.min(rows.length - 1, target))];
    const column = rows[current].cells.indexOf(reference);
    const pos = reference.dataset.pos ?? null;

    const samePos =
      pos === null ? null : row.cells.find((cell) => (cell.dataset.pos ?? null) === pos);
    const fallback = row.cells[Math.max(0, Math.min(row.cells.length - 1, column))];

    this._setCursor(samePos || fallback, { focus: true });
  },

  _pageRows(reference) {
    const region = reference.closest(SCROLL_REGION_SELECTOR);
    const row = reference.closest("tr");
    const rowHeight = row ? row.getBoundingClientRect().height : 0;
    const regionHeight = region ? region.clientHeight : 0;

    if (rowHeight <= 0 || regionHeight <= 0) return PAGE_ROWS_FALLBACK;

    return Math.max(1, Math.floor(regionHeight / rowHeight));
  },

  // Re-applies tabindex=0 and the ring to the remembered cursor, or moves it to
  // the same row index when the re-rendered grid no longer holds that trip.
  _applyCursor({ focus = false } = {}) {
    const rows = this._rows();
    if (rows.length === 0) {
      this._cursorCell = null;
      return;
    }

    let cell = null;

    if (this._cursorCell && rows.some((entry) => entry.cells.includes(this._cursorCell))) {
      cell = this._cursorCell;
    }

    if (!cell && this._cursor) {
      for (const entry of rows) {
        const match = entry.cells.find(
          (candidate) =>
            (candidate.dataset.trip || null) === this._cursor.trip &&
            (candidate.dataset.pos ?? null) === this._cursor.pos
        );
        if (match) {
          cell = match;
          break;
        }
      }
    }

    if (!cell) {
      const row = rows[Math.min(this._rowIndex, rows.length - 1)];
      cell = row.cells[Math.min(this._columnIndex, row.cells.length - 1)];
    }

    this._setCursor(cell, { focus });
  },

  _setCursor(cell, { focus = true } = {}) {
    if (!cell) return;

    const rows = this._rows();
    const row = rows.find((entry) => entry.cells.includes(cell));
    const column = row ? row.cells.indexOf(cell) : 0;

    for (const other of this._cells()) {
      if (other === cell) continue;
      if (other.classList.contains("is-cursor")) other.classList.remove("is-cursor");
      if (other.getAttribute("tabindex") === "0") other.setAttribute("tabindex", "-1");
    }

    this._cursorCell = cell;
    this._cursor = { trip: cell.dataset.trip || null, pos: cell.dataset.pos ?? null };
    this._columnIndex = column;
    this._rowIndex = row ? rows.indexOf(row) : 0;

    cell.classList.add("is-cursor");
    cell.setAttribute("tabindex", "0");

    if (!focus) return;

    this.el.classList.remove("grid-idle");
    cell.focus();
    cell.scrollIntoView({ block: "nearest" });
  },
};

export default TimetableGrid;
