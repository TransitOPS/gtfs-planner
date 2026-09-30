/**
 * PatternCompareWorkspace
 *
 * The client-only workspace of the Compare patterns page (spec 19, `R11`,
 * `AC-18`, `AC-19`). Everything a click changes here — the selected
 * difference, the selected row, All stops/Differences, fold reveals and hover
 * — is local DOM state: the hook never calls `pushEvent` (`INV-4`). The map
 * pane listens to the hook's window events instead.
 *
 * Mounted on the empty ignored anchor `#compare-workspace-hook`
 * (`phx-hook="PatternCompareWorkspace"`, `phx-update="ignore"`), which owns no
 * content of its own; the hook finds `#compare-workspace` by id and decorates
 * that server-rendered workspace, so the stop-table stream and every server
 * patch keep working. The server renders every state's markup; the hook only
 * flips attributes and classes:
 *
 *   #compare-summary button[data-diff-index]
 *       data-diff-rows   zero-based row indexes of the item, comma-separated
 *       data-diff-stops  the item's frame stop ids, comma-separated
 *       aria-pressed     exactly the selected button stays "true"
 *   #compare-stops[data-mode]        "all" | "diff"; the server sets the mode
 *   button[data-mode]                the All stops / Differences pair
 *   #stops-previous/#stops-next      data-step="-1" | "1"
 *   #stops-position                  "Difference i of n" for the selection
 *   tr[data-row]                     data-stop-id, data-type and the tint class
 *   button[data-select]              row selection by click or Enter
 *   a[data-goto-row]                 the moved pair's "Go to …'s visit"
 *   tr[data-fold="from-to"]          a fold marker with button[data-unfold]
 *   tr[data-fold-range="from-to"]    the rows that marker hides in diff mode
 *
 * A highlighted row gives up its series tint (`bg-navy-300/15`, `bg-soft`,
 * `bg-warning-bg/50`) for `bg-selection` and gets the tint back when the
 * highlight moves on. Differences mode toggles `hidden` only; an opened fold
 * stays open across mode switches until the hook is dropped.
 *
 * Window events this hook dispatches (the PatternCompareMap contract):
 *   compare:frame        {stopIds: string[]}  fit the map to the difference
 *                                            frame; the row selection clears
 *   compare:hot          {stopId: string|null}  a row was entered or left
 *   compare:select-stop  {stopId: string}     a row was selected
 *
 * Window event this hook listens for (dispatched by the map hook):
 *   compare:row-for-stop {stopId: string}     select the first row serving
 *                                            that stop
 */

const WORKSPACE_ID = "compare-workspace";
const ROW_SELECTOR = "tr[data-row]";
const FOLD_MARKER_SELECTOR = "tr[data-fold]";
const DIFF_BUTTON_SELECTOR = "button[data-diff-index]";
const MODE_BUTTON_SELECTOR = "button[data-mode]";
const STEP_BUTTON_SELECTOR = "button[data-step]";
const UNFOLD_BUTTON_SELECTOR = "button[data-unfold]";
const GOTO_LINK_SELECTOR = "a[data-goto-row]";
const SELECT_BUTTON_SELECTOR = "button[data-select]";
const STATUS_ID = "stops-position";

const ROW_HIGHLIGHT_CLASS = "bg-selection";
const ROW_TINT_CLASSES = ["bg-warning-bg/50", "bg-navy-300/15", "bg-soft"];

// The wrapped index of the next/previous difference. `null` means nothing is
// selected yet: Next opens the first item, Previous the last (R11, AC-19).
export function nextIndex(current, count) {
  if (count <= 0) return null;
  if (current == null) return 0;
  return (current + 1) % count;
}

export function prevIndex(current, count) {
  if (count <= 0) return null;
  if (current == null) return count - 1;
  return (current - 1 + count) % count;
}

// The zero-based row indexes an item's `data-diff-rows` names.
export function rowsForDifference(attribute) {
  return splitList(attribute).map(Number);
}

function splitList(attribute) {
  if (typeof attribute !== "string" || attribute.trim() === "") return [];
  return attribute
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value !== "");
}

function statusLabel(count) {
  if (count === 0) return "No differences";
  return count === 1 ? "1 difference" : `${count} differences`;
}

const PatternCompareWorkspace = {
  mounted() {
    this._diffIndex = null;
    this._selectedRow = null;
    this._selectedRowElement = null;
    this._diffRows = new Set();
    this._removedTints = new Map();
    this._openFolds = new Set();
    this._boundRows = new WeakSet();

    this._handleClickEvent = (event) => this._handleClick(event);
    this._handleRowEnterEvent = (event) =>
      this._dispatch("compare:hot", { stopId: event.currentTarget.dataset.stopId || null });
    this._handleRowLeaveEvent = () => this._dispatch("compare:hot", { stopId: null });
    this._handleRowForStopEvent = (event) => this._handleRowForStop(event);

    this._bindScope();
    window.addEventListener("compare:row-for-stop", this._handleRowForStopEvent);

    this._bindRows();
    this._syncModeButtons();
    this._applyFoldState();
    this._updateStatus();
  },

  // Stream rows and the toolbar are patched by the server; the hook's own
  // state has to survive a patch and be visible again on the new nodes.
  updated() {
    this._bindScope();
    if (this._diffIndex != null && this._diffIndex >= this._diffButtons().length) {
      this._diffIndex = null;
    }
    this._bindRows();
    this._syncModeButtons();
    this._applyFoldState();
    this._clearDifferenceHighlight();
    this._applyDifferenceHighlight();
    this._reapplyRowSelection();
    this._updateStatus();
  },

  destroyed() {
    if (this._scope) this._scope.removeEventListener("click", this._handleClickEvent);
    window.removeEventListener("compare:row-for-stop", this._handleRowForStopEvent);
  },

  // The hook's own element is an ignored, empty anchor; the workspace it
  // decorates is found by id so the server keeps owning the DOM inside it.
  _bindScope() {
    const scope = document.getElementById(WORKSPACE_ID) || this.el;
    if (this._scope === scope) return;
    if (this._scope) this._scope.removeEventListener("click", this._handleClickEvent);
    this._scope = scope;
    this._scope.addEventListener("click", this._handleClickEvent);
  },

  _handleClick(event) {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;

    const diffButton = target.closest(DIFF_BUTTON_SELECTOR);
    if (diffButton) {
      event.preventDefault();
      this._selectDifference(Number(diffButton.dataset.diffIndex));
      return;
    }

    const modeButton = target.closest(MODE_BUTTON_SELECTOR);
    if (modeButton) {
      this._setMode(modeButton.dataset.mode);
      return;
    }

    const stepButton = target.closest(STEP_BUTTON_SELECTOR);
    if (stepButton) {
      this._stepDifference(Number(stepButton.dataset.step));
      return;
    }

    const unfoldButton = target.closest(UNFOLD_BUTTON_SELECTOR);
    if (unfoldButton) {
      this._openFold(unfoldButton.dataset.unfold);
      return;
    }

    const gotoLink = target.closest(GOTO_LINK_SELECTOR);
    if (gotoLink) {
      // The anchor's href is the row id; selecting the row is the hook's job,
      // so the URL's hash never changes.
      event.preventDefault();
      this._selectRow(Number(gotoLink.dataset.gotoRow), { scroll: true });
      return;
    }

    const selectButton = target.closest(SELECT_BUTTON_SELECTOR);
    if (selectButton) this._selectRow(Number(selectButton.dataset.select));
  },

  _handleRowForStop(event) {
    const stopId = event.detail && event.detail.stopId;
    if (!stopId) return;
    const row = this._rows().find((candidate) => candidate.dataset.stopId === stopId);
    if (row) this._selectRow(Number(row.dataset.row), { scroll: true });
  },

  _selectDifference(index) {
    const buttons = this._diffButtons();
    if (!(index >= 0 && index < buttons.length)) return;

    this._diffIndex = index;
    for (const [position, button] of buttons.entries()) {
      button.setAttribute("aria-pressed", position === index ? "true" : "false");
    }

    const rowIndexes = rowsForDifference(buttons[index].dataset.diffRows);
    for (const rowIndex of rowIndexes) this._openFoldContaining(rowIndex);

    this._clearRowSelection();
    this._clearDifferenceHighlight();
    this._applyDifferenceHighlight();
    this._updateStatus();

    const firstRow = rowIndexes.map((rowIndex) => this._row(rowIndex)).find(Boolean);
    if (firstRow) this._scrollTo(firstRow);

    this._dispatch("compare:frame", { stopIds: splitList(buttons[index].dataset.diffStops) });
  },

  _stepDifference(step) {
    const count = this._diffButtons().length;
    if (count === 0) return;
    const index = step < 0 ? prevIndex(this._diffIndex, count) : nextIndex(this._diffIndex, count);
    if (index != null) this._selectDifference(index);
  },

  _selectRow(index, { scroll = false } = {}) {
    const row = this._row(index);
    if (!row) return;

    this._openFoldContaining(index);
    this._clearRowSelection();
    this._selectedRow = index;
    this._selectedRowElement = row;
    this._highlight(row);
    if (scroll) this._scrollTo(row);

    this._dispatch("compare:select-stop", { stopId: row.dataset.stopId || null });
  },

  _setMode(mode) {
    if (mode !== "all" && mode !== "diff") return;
    const stops = this._scope.querySelector("#compare-stops");
    if (stops) stops.dataset.mode = mode;
    this._syncModeButtons();
    this._applyFoldState();
  },

  _syncModeButtons() {
    const mode = this._mode();
    for (const button of this._scope.querySelectorAll(MODE_BUTTON_SELECTOR)) {
      button.setAttribute("aria-pressed", button.dataset.mode === mode ? "true" : "false");
    }
  },

  _mode() {
    const stops = this._scope.querySelector("#compare-stops");
    return stops && stops.dataset.mode === "diff" ? "diff" : "all";
  },

  _openFold(key) {
    if (!key) return;
    this._openFolds.add(key);
    this._applyFoldState();
  },

  _openFoldContaining(index) {
    for (const marker of this._foldMarkers()) {
      const key = marker.dataset.fold;
      if (!key) continue;
      const [from, to] = key.split("-").map(Number);
      if (index >= from && index <= to) {
        this._openFold(key);
        return;
      }
    }
  },

  // Differences mode hides every folded run that has not been opened; All
  // stops shows every row and hides every marker. An opened fold keeps its
  // rows visible when the mode is switched back to Differences.
  _applyFoldState() {
    const mode = this._mode();
    for (const marker of this._foldMarkers()) {
      const key = marker.dataset.fold;
      if (!key) continue;
      const open = this._openFolds.has(key);
      marker.hidden = mode !== "diff" || open;
      for (const row of this._foldedRows(key)) row.hidden = mode === "diff" && !open;
    }
  },

  _highlight(row) {
    if (!this._removedTints.has(row)) {
      this._removedTints.set(
        row,
        ROW_TINT_CLASSES.filter((name) => row.classList.contains(name)),
      );
    }
    for (const name of ROW_TINT_CLASSES) row.classList.remove(name);
    row.classList.add(ROW_HIGHLIGHT_CLASS);
  },

  _unhighlight(row) {
    row.classList.remove(ROW_HIGHLIGHT_CLASS);
    const tints = this._removedTints.get(row);
    if (tints) for (const name of tints) row.classList.add(name);
    this._removedTints.delete(row);
  },

  _clearDifferenceHighlight() {
    for (const row of this._diffRows) this._unhighlight(row);
    this._diffRows.clear();
  },

  _applyDifferenceHighlight() {
    const button = this._diffButtons()[this._diffIndex];
    if (!button) return;
    for (const rowIndex of rowsForDifference(button.dataset.diffRows)) {
      const row = this._row(rowIndex);
      if (!row) continue;
      this._highlight(row);
      this._diffRows.add(row);
    }
  },

  _clearRowSelection() {
    if (this._selectedRowElement) this._unhighlight(this._selectedRowElement);
    this._selectedRow = null;
    this._selectedRowElement = null;
  },

  _reapplyRowSelection() {
    if (this._selectedRow == null) return;
    const row = this._row(this._selectedRow);
    if (!row) return;
    this._selectedRowElement = row;
    this._highlight(row);
  },

  _updateStatus() {
    const status = this._scope.querySelector(`#${STATUS_ID}`);
    if (!status) return;
    const count = this._diffButtons().length;
    status.textContent =
      this._diffIndex == null ? statusLabel(count) : `Difference ${this._diffIndex + 1} of ${count}`;
  },

  _scrollTo(row) {
    if (typeof row.scrollIntoView !== "function") return;
    const reduceMotion =
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    row.scrollIntoView({ block: "center", behavior: reduceMotion ? "auto" : "smooth" });
  },

  _dispatch(name, detail) {
    window.dispatchEvent(new CustomEvent(name, { detail }));
  },

  _bindRows() {
    for (const row of this._rows()) {
      if (this._boundRows.has(row)) continue;
      this._boundRows.add(row);
      row.addEventListener("mouseenter", this._handleRowEnterEvent);
      row.addEventListener("mouseleave", this._handleRowLeaveEvent);
    }
  },

  _rows() {
    return [...this._scope.querySelectorAll(ROW_SELECTOR)];
  },

  _row(index) {
    return this._scope.querySelector(`tr[data-row="${index}"]`);
  },

  _diffButtons() {
    return [...this._scope.querySelectorAll(DIFF_BUTTON_SELECTOR)];
  },

  _foldMarkers() {
    return [...this._scope.querySelectorAll(FOLD_MARKER_SELECTOR)];
  },

  _foldedRows(key) {
    return [...this._scope.querySelectorAll(`tr[data-fold-range="${key}"]`)];
  },
};

export default PatternCompareWorkspace;
