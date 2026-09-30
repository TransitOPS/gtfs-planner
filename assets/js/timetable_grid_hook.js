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
 * cursor points at; a `reset: true` stream drops focus to the body before
 * beforeUpdate() runs, so the hook records focus when it sends an event and
 * updated() re-applies the cursor to the re-rendered cell and restores that
 * focus (falling back to the same row when the remembered trip is gone).
 * Movement scrolls with the table region's scroll padding so the sticky grid
 * bar never covers the cursor.
 *
 * The hook also owns the in-cell time editor: the LiveView renders the empty
 * `#cell-editor` container once, outside the streamed sections, and this hook
 * places it over the cursor cell and fills it with the time input and the
 * `#cell-reading` line. Typing a digit, `+` or `-` starts editing with that
 * character; Enter or F2 edits the current text; Tab commits and moves right,
 * Shift+Enter up, Enter down, Alt+Enter only the edited stop and Ctrl/⌘+Enter
 * the whole trip; Esc cancels; Delete/Backspace outside editing clears the
 * cell. The server owns the grammar: every text change asks for a reading with
 * a 150 ms debounce over `cell_preview`, Enter asks `cell_commit` and the cell
 * carries the pending state until the reply. The editor never holds a parsed
 * time, a fingerprint or a restore payload.
 *
 * R12 scopes the shortcuts: they act only while focus is inside the grid and
 * never when the event target is a field (the hook's own editor included), a
 * dialog or a drawer. Space toggles the cursor row (`toggle_trip`), Shift+Up/
 * Down extend the selection (`select_range`), Cmd/Ctrl+A selects every visible
 * row, `]`/`[`/`}`/`{` nudge by ±1/±5 minutes (`nudge`, the cursor row's
 * trip), Cmd/Ctrl+Z undoes (never while the editor is open), Cmd/Ctrl+C copies
 * the selection, a `paste` event pushes `paste_trips`, `?` and Cmd/Ctrl+/
 * open the shortcut sheet, and Cmd/Ctrl+S is prevented and pushes
 * `save_shortcut`. Brackets match on `event.key`, so AltGr/Option layouts work;
 * Meta with a bracket stays with the browser's Back/Forward. Enter opens the
 * editor on a stop cell, the Change timing strip on the Timing cell and the
 * trip drawer on a frequency row.
 */
const CELL_SELECTOR = 'td[id^="cell-"]';
const SCROLL_REGION_SELECTOR = '[id$="-table-container"]';
const TYPING_SELECTOR = "input, textarea, select, [contenteditable]";
const DIALOG_SELECTOR = "dialog, [role=dialog]";
const EDITOR_SELECTOR = "#cell-editor";
// The shifted faces of the bracket keys are included, so the same physical key
// nudges on layouts that report `{`/`}`; Meta is handled by the browser.
const NUDGE_MINUTES = new Map([
  ["]", 1],
  ["[", -1],
  ["}", 5],
  ["{", -5],
]);
// The design system's text input, 44 px tall and right-aligned for a clock.
const EDITOR_INPUT_CLASS =
  "min-h-11 w-full rounded-control border border-control bg-white px-3 text-right text-sm font-[650] text-strong tabular-nums focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus";
// The reference's empty-entry hint; the reading itself always comes from the server.
const EDIT_HINT = "Type 605, 6:05p, 25:10 or +3";
const EMPTY_COMMIT_MESSAGE = "Type a time, or press Esc to keep the current one.";
const SAVING_TITLE = "Saving…";
// Two keystrokes inside this window ask the server for one reading (PM-7).
const PREVIEW_DEBOUNCE_MS = 150;
const START_EDIT_KEYS = /^[0-9+\-]$/;
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
    this._editor = null;
    this._editorElement = this.el.querySelector(EDITOR_SELECTOR);
    this._editorInput = null;
    this._editorReadingText = null;
    this._editorReadingKeys = null;
    this._selectionAnchor = null;

    this._onKeydown = (event) => this._handleKeydown(event);
    this._onClick = (event) => this._handleClick(event);
    this._onPaste = (event) => this._handlePaste(event);
    // A write the grid did not send itself (the docked strip's Cancel, Refresh
    // preview and Apply) keeps the cursor too: the strip dispatches this event
    // before the server round trip, and this arm sets the flag `_pushEvent`
    // sets so `updated()` re-applies the cursor after the reset stream dropped
    // focus to the body.
    this._onKeepCursor = () => {
      this._restoreFocus = true;
    };
    this._onFocusIn = () => this.el.classList.remove("grid-idle");
    this._onFocusOut = (event) => {
      if (!this.el.contains(event.relatedTarget)) this.el.classList.add("grid-idle");
    };
    this._onViewportChange = () => this._placeEditor();

    this.el.addEventListener("keydown", this._onKeydown);
    this.el.addEventListener("click", this._onClick);
    this.el.addEventListener("timetable-grid:keep-cursor", this._onKeepCursor);
    this.el.addEventListener("focusin", this._onFocusIn);
    this.el.addEventListener("focusout", this._onFocusOut);
    this.el.addEventListener("paste", this._onPaste);
    // Capture so the table region's own scrolling keeps the editor on its cell.
    window.addEventListener("scroll", this._onViewportChange, true);
    window.addEventListener("resize", this._onViewportChange);

    this.el.classList.add("grid-idle");
  },

  beforeUpdate() {
    // `||`: a `reset: true` stream removes the streamed sections before morphdom
    // runs, so the browser has already moved focus to the body by the time this
    // hook's beforeUpdate() sees it. `_pushEvent` records that the grid owned
    // the focus for the write it sent.
    this._restoreFocus = this._restoreFocus || this.el.contains(document.activeElement);
  },

  updated() {
    const focus = this._restoreFocus;
    this._restoreFocus = false;
    if (!this._cursor && !this._cursorCell) return;

    // An open editor owns the focus ring: re-rendering the cell under it must
    // not pull focus back to the cell.
    const editing = this._editorOpen();
    this._applyCursor({ focus: focus && !editing });

    if (!editing) return;

    const cell = this._cellFor(this._editor);
    if (cell) this._placeEditor(cell);
    else this._closeEditor();
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown);
    this.el.removeEventListener("click", this._onClick);
    this.el.removeEventListener("timetable-grid:keep-cursor", this._onKeepCursor);
    this.el.removeEventListener("focusin", this._onFocusIn);
    this.el.removeEventListener("focusout", this._onFocusOut);
    this.el.removeEventListener("paste", this._onPaste);
    window.removeEventListener("scroll", this._onViewportChange, true);
    window.removeEventListener("resize", this._onViewportChange);
    this._stopEditing();
    this._onKeydown = null;
    this._onClick = null;
    this._onPaste = null;
    this._onKeepCursor = null;
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

  // Every event this hook sends comes from a key, click or paste inside the grid,
  // and the LiveView reload that answers it replaces the focused cell before this
  // hook's beforeUpdate() runs. Recording the focus here keeps the cursor cell
  // focused after the write (AC-6) instead of dropping focus to the body, where
  // the grid's own shortcuts (Cmd/Ctrl+Z included) could no longer reach it.
  _pushEvent(name, payload, callback) {
    this._restoreFocus = this.el.contains(document.activeElement);
    return this.pushEvent(name, payload, callback);
  },

  _handleKeydown(event) {
    if (event.defaultPrevented) return;

    const target = event.target;
    if (!(target instanceof Element) || !this.el.contains(target)) return;
    // R12: a field, dialog or drawer keeps every key. The editor's own input is
    // a field too, so its keys never reach this handler.
    if (target.closest(TYPING_SELECTOR) || target.closest(DIALOG_SELECTOR)) return;

    const modifier = event.metaKey || event.ctrlKey;
    const key = event.key;

    // These chords act anywhere in the grid, so they are checked before the
    // cursor cell. Cmd/Ctrl+S never reaches the browser's Save dialog.
    if (modifier && key.toLowerCase() === "s") {
      event.preventDefault();
      this._pushEvent("save_shortcut", {});
      return;
    }

    if (modifier && key.toLowerCase() === "z" && !event.shiftKey && !this._editorOpen()) {
      event.preventDefault();
      this._pushEvent("undo", {});
      return;
    }

    if ((key === "?" && !modifier) || (modifier && key === "/")) {
      event.preventDefault();
      this._pushEvent("toggle_shortcuts", {});
      return;
    }

    const cell = target.closest(CELL_SELECTOR);

    // A navigation key pressed on the table region itself (its focusable
    // scroll area) enters the grid at that section's first cell, so a keyboard
    // user reaches the cursor without a pointer.
    if (!cell || !this.el.contains(cell)) {
      if (!NAVIGATION_KEYS.has(key)) return;

      const region = target.closest(SCROLL_REGION_SELECTOR);
      const first =
        region && this.el.contains(region) ? region.querySelector(CELL_SELECTOR) : null;
      if (!first) return;

      event.preventDefault();
      this._setCursor(first, { focus: true });
      return;
    }

    // Enter and F2 open the Timing strip from the timing cell (no occurrence
    // position), a frequency trip's drawer from its cells, and the editor from
    // a listed stop cell; a digit, `+` or `-` opens the editor already holding
    // that character.
    if (key === "Enter" || key === "F2") {
      event.preventDefault();

      if (!cell.dataset.pos) {
        this._pushEvent("open_change", { kind: "timing", trip: cell.dataset.trip });
        return;
      }

      const row = cell.closest("tr");
      if (row && row.querySelector('[id$="-frequency"]')) {
        this._pushEvent("open_edit_drawer", { trip: cell.dataset.trip });
        return;
      }

      if (!this._canEdit(cell)) return;
      this._startEdit(cell);
      return;
    }

    if (key === "Delete" || key === "Backspace") {
      if (!this._canEdit(cell)) return;
      event.preventDefault();
      this._clearCell(cell);
      return;
    }

    if (!modifier && !event.altKey && START_EDIT_KEYS.test(key) && this._canEdit(cell)) {
      event.preventDefault();
      this._startEdit(cell, key);
      return;
    }

    if (key === " ") {
      event.preventDefault();
      this._toggleTrip(cell);
      return;
    }

    if (modifier && key.toLowerCase() === "a") {
      event.preventDefault();
      this._pushEvent("select_all", {});
      return;
    }

    if (modifier && key.toLowerCase() === "c") {
      event.preventDefault();
      this._pushEvent("copy_trips", {});
      return;
    }

    // Matched on `event.key` so AltGr/Option layouts work; Meta with a bracket
    // is left to the browser's Back/Forward.
    const minutes = NUDGE_MINUTES.get(key);
    if (minutes !== undefined && !event.metaKey) {
      event.preventDefault();
      this._nudge(cell, minutes);
      return;
    }

    switch (key) {
      case "ArrowDown":
      case "ArrowUp": {
        event.preventDefault();
        const delta = key === "ArrowDown" ? 1 : -1;
        if (modifier) this._moveV(cell, 0, { to: delta > 0 ? "last" : "first" });
        else if (event.shiftKey) this._extendSelection(cell, delta);
        else this._moveV(cell, delta);
        return;
      }
      case "ArrowRight":
      case "ArrowLeft": {
        // Cmd/Ctrl+Left/Right belong to the browser's Back and Forward.
        if (modifier) return;
        event.preventDefault();
        this._moveH(cell, key === "ArrowRight" ? 1 : -1);
        return;
      }
      case "Home":
      case "End": {
        if (modifier) return;
        event.preventDefault();
        this._moveH(cell, 0, { to: key === "Home" ? "first" : "last" });
        return;
      }
      case "PageDown":
      case "PageUp": {
        event.preventDefault();
        const pages = this._pageRows(cell);
        this._moveV(cell, key === "PageDown" ? pages : -pages);
        return;
      }
      default:
        return;
    }
  },

  _handleClick(event) {
    if (event.defaultPrevented) return;

    const target = event.target;
    if (!(target instanceof Element)) return;

    // A click outside the editor ends an open edit; the click still moves the cursor.
    if (this._editorOpen() && !target.closest(EDITOR_SELECTOR)) this._closeEditor();

    const cell = target.closest(CELL_SELECTOR);
    if (!cell || !this.el.contains(cell)) return;

    this._setCursor(cell, { focus: true });
  },

  // --- selection, nudges and the clipboard ----------------------------------

  // Space toggles the cursor row and becomes the anchor the next Shift+Up/Down
  // extends from, like the reference's row toggle.
  _toggleTrip(cell) {
    const trip = this._tripFor(cell);
    if (!trip) return;

    this._selectionAnchor = trip;
    this._pushEvent("toggle_trip", { trip });
  },

  _extendSelection(cell, delta) {
    const anchor = this._selectionAnchor || this._tripFor(cell);
    if (!anchor) return;

    this._selectionAnchor = anchor;
    this._moveV(cell, delta);

    const to = this._cursor && this._cursor.trip;
    if (to) this._pushEvent("select_range", { from: anchor, to });
  },

  // Nudges act on the selection server-side; `trip` names the cursor row.
  _nudge(cell, minutes) {
    const trip = this._tripFor(cell);
    if (!trip) return;

    this._pushEvent("nudge", { minutes, trip });
  },

  _tripFor(cell) {
    return (this._cursor && this._cursor.trip) || cell.dataset.trip || null;
  },

  // A paste in the grid asks the LiveView for its server-held clipboard; when
  // that is empty and the system clipboard carried text, the server says so
  // and `paste_text` reports the spreadsheet message instead.
  _handlePaste(event) {
    const target = event.target;
    if (!(target instanceof Element) || !this.el.contains(target)) return;
    if (target.closest(TYPING_SELECTOR) || target.closest(DIALOG_SELECTOR)) return;

    const cell = target.closest(CELL_SELECTOR);
    if (!cell || this._editorOpen()) return;

    event.preventDefault();
    const text = event.clipboardData ? event.clipboardData.getData("text") : "";

    this._pushEvent("paste_trips", {}, (reply) => {
      if (reply && reply.clipboard === false && text) this._pushEvent("paste_text", {});
    });
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

  // --- the in-cell time editor ----------------------------------------------

  _editorOpen() {
    return Boolean(
      this._editor && this._editorElement && this._editorElement.classList.contains("is-open")
    );
  },

  // Only a stop time is edited here: the timing cell carries no occurrence
  // position, and a frequency trip's cells open its drawer instead (step 24).
  _canEdit(cell) {
    if (!cell || !cell.dataset.pos) return false;
    const row = cell.closest("tr");
    return !(row && row.querySelector('[id$="-frequency"]'));
  },

  _cellFor(source) {
    if (!source) return null;
    const trip = source.trip ?? null;
    const pos = source.pos ?? null;

    return (
      this._cells().find(
        (cell) => (cell.dataset.trip || null) === trip && (cell.dataset.pos ?? null) === pos
      ) || null
    );
  },

  // The server owns the grammar, so the editor starts from the cell's shown
  // text: `8:05` without the `+1 day` marker, and empty for a missing time.
  _cellText(cell) {
    const shown = cell.querySelector(".tabular-nums") || cell;
    const text = (shown.textContent || "").trim();
    return text === "—" ? "" : text;
  },

  _buildEditor() {
    if (this._editorInput && this._editorElement.contains(this._editorInput)) return;

    const input = document.createElement("input");
    input.type = "text";
    input.id = "cell-editor-input";
    input.className = EDITOR_INPUT_CLASS;
    input.autocomplete = "off";
    input.spellcheck = false;
    input.inputMode = "text";
    input.setAttribute("aria-label", "Time at this stop");
    input.setAttribute("aria-describedby", "cell-reading");
    input.addEventListener("keydown", (event) => this._handleEditorKeydown(event));
    input.addEventListener("input", () => this._handleEditorInput());
    input.addEventListener("blur", () => setTimeout(() => this._closeEditor(), 0));

    const reading = document.createElement("div");
    reading.id = "cell-reading";
    reading.innerHTML = '<p class="cell-reading-value"></p><p class="cell-reading-keys"></p>';

    this._editorElement.replaceChildren(input, reading);
    this._editorInput = input;
    this._editorReadingText = reading.querySelector(".cell-reading-value");
    this._editorReadingKeys = reading.querySelector(".cell-reading-keys");
  },

  _startEdit(cell, initial = null) {
    if (!this._editorElement || !this._canEdit(cell)) return;

    const value = initial === null ? this._cellText(cell) : initial;
    this._editor = {
      trip: cell.dataset.trip,
      pos: cell.dataset.pos,
      cell,
      value,
      sequence: 0,
      timer: null,
      committing: false,
    };

    this._buildEditor();
    this._editorInput.value = value;
    this._editorElement.classList.add("is-open");
    this._editorElement.classList.remove("is-error");
    this._renderKeys(cell);
    this._placeEditor(cell);

    this._editorInput.focus();
    if (initial === null) this._editorInput.select();
    else this._editorInput.setSelectionRange(value.length, value.length);

    this._schedulePreview();
  },

  _handleEditorInput() {
    if (!this._editor) return;
    this._editor.value = this._editorInput.value;
    this._schedulePreview();
  },

  _handleEditorKeydown(event) {
    const modifier = event.metaKey || event.ctrlKey;

    if (event.key === "Enter") {
      event.preventDefault();
      const mode = modifier ? "anchor" : event.altKey ? "only" : "later";
      this._commitEditor(event.shiftKey ? "up" : "down", mode);
      return;
    }

    if (event.key === "Tab") {
      event.preventDefault();
      this._commitEditor(event.shiftKey ? "left" : "right", "later");
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      this._cancelEditor();
    }
  },

  // A reading request per settled keystroke burst; an empty entry keeps the hint.
  _schedulePreview() {
    const editor = this._editor;
    if (!editor) return;

    clearTimeout(editor.timer);
    editor.timer = null;
    editor.sequence += 1;
    this._clearError();

    if (editor.value.trim() === "") {
      this._renderHint();
      return;
    }

    const sequence = editor.sequence;
    this._editorReadingText.replaceChildren();
    editor.timer = setTimeout(() => this._pushPreview(sequence), PREVIEW_DEBOUNCE_MS);
  },

  _pushPreview(sequence) {
    const editor = this._editor;
    if (!editor || editor.sequence !== sequence) return;

    editor.timer = null;
    this._pushEvent(
      "cell_preview",
      { trip: editor.trip, position: Number(editor.pos), text: editor.value },
      (reply) => {
        if (this._editor !== editor || editor.sequence !== sequence) return;
        if (reply && reply.ok && reply.reading !== undefined) this._renderReading(reply);
        else this._renderError(reply && reply.message);
      }
    );
  },

  _commitEditor(move, mode) {
    const editor = this._editor;
    if (!editor) return;

    const text = editor.value;
    if (text.trim() === "") {
      this._renderError(EMPTY_COMMIT_MESSAGE);
      return;
    }

    clearTimeout(editor.timer);
    editor.timer = null;
    editor.sequence += 1;
    editor.committing = true;

    const cell = editor.cell;
    this._hideEditor();
    this._setPending(cell);

    this._pushEvent(
      "cell_commit",
      { trip: editor.trip, position: Number(editor.pos), text, mode },
      (reply) => {
        this._clearPending(this._cellFor(editor) || cell);
        if (this._editor === editor) editor.committing = false;

        if (reply && reply.ok) {
          this._clearEditor();
          this._moveAfterCommit(editor, move);
          return;
        }

        // A refused edit keeps the typed text in place with the server's reason.
        if (this._editor !== editor) return;
        this._showEditor();
        this._renderError(reply && reply.message);
      }
    );
  },

  _cancelEditor() {
    const editor = this._editor;
    const cell = editor ? this._cellFor(editor) || editor.cell : null;

    this._closeEditor();
    if (cell) this._setCursor(cell, { focus: true });
  },

  // Esc and leaving the grid close the editor; `cell_commit` only hides it while
  // the write is in flight so the cell's pending state is visible underneath.
  _closeEditor() {
    if (this._editor && this._editor.committing) return;
    this._clearEditor();
  },

  _clearEditor() {
    this._stopEditing();
    if (!this._editorElement) return;
    this._editorElement.classList.remove("is-open", "is-error");
    this._editorElement.removeAttribute("style");
  },

  _stopEditing() {
    if (this._editor) clearTimeout(this._editor.timer);
    this._editor = null;
  },

  _hideEditor() {
    this._editorElement.classList.remove("is-open");
  },

  _showEditor() {
    const editor = this._editor;
    if (!editor || !this._editorElement) return;

    const cell = this._cellFor(editor);
    if (!cell) return;

    editor.cell = cell;
    this._editorElement.classList.add("is-open");
    this._placeEditor(cell);
    this._editorInput.focus();
  },

  _moveAfterCommit(editor, move) {
    const cell = this._cellFor(editor) || editor.cell;
    if (!cell) return;

    if (move === "up") this._moveV(cell, -1);
    else if (move === "right") this._moveH(cell, 1);
    else if (move === "left") this._moveH(cell, -1);
    else this._moveV(cell, 1);
  },

  _clearCell(cell) {
    const trip = cell.dataset.trip;
    const position = cell.dataset.pos;
    if (!trip || !position) return;

    this._setPending(cell);
    this._pushEvent("cell_clear", { trip, position: Number(position) });
  },

  _setPending(cell) {
    if (!cell) return;
    if (cell.dataset.savedTitle === undefined) {
      cell.dataset.savedTitle = cell.getAttribute("title") || "";
    }

    cell.classList.add("is-pending");
    cell.setAttribute("title", SAVING_TITLE);
  },

  _clearPending(cell) {
    if (!cell) return;
    cell.classList.remove("is-pending");

    if (cell.dataset.savedTitle) cell.setAttribute("title", cell.dataset.savedTitle);
    else cell.removeAttribute("title");
  },

  _placeEditor(cell = null) {
    const editor = this._editor;
    if (!editor || !this._editorOpen()) return;

    const target = cell || this._cellFor(editor) || editor.cell;
    if (!target || !target.isConnected) return;

    const rect = target.getBoundingClientRect();
    const style = this._editorElement.style;
    style.left = `${rect.left}px`;
    style.top = `${rect.top}px`;
    style.width = `${rect.width}px`;
    style.height = `${rect.height}px`;
  },

  _renderHint() {
    if (!this._editorReadingText) return;

    const hint = document.createElement("span");
    hint.className = "text-muted";
    hint.textContent = EDIT_HINT;
    this._editorReadingText.replaceChildren(hint);
  },

  _renderReading(reply) {
    if (!this._editorReadingText) return;

    const value = document.createElement("span");
    value.className = "font-[650] text-strong";
    value.textContent = `Reads as ${reply.reading}`;
    this._editorReadingText.replaceChildren(value);

    if (reply.note) {
      const note = document.createElement("span");
      note.className = "text-muted";
      note.textContent = ` (${reply.note})`;
      this._editorReadingText.append(note);
    }

    if (reply.effect) {
      const effect = document.createElement("span");
      effect.className = "text-default";
      effect.textContent = ` · ${reply.effect}`;
      this._editorReadingText.append(effect);
    }
  },

  _renderError(message) {
    if (!this._editorReadingText) return;

    const text = document.createElement("span");
    text.className = "font-[650] text-error-fg";
    text.textContent = message || "";
    this._editorReadingText.replaceChildren(text);
    this._editorElement.classList.add("is-error");
  },

  _clearError() {
    if (this._editorElement) this._editorElement.classList.remove("is-error");
  },

  // The reference's key hints: the first column saves on Enter alone, every
  // other stop names what each commit key does to the rest of the trip.
  _renderKeys(cell) {
    if (!this._editorReadingKeys) return;

    const row = this._rows().find((entry) => entry.cells.includes(cell));
    const first = Boolean(row && row.cells[0] === cell);

    this._editorReadingKeys.replaceChildren();

    for (const [cap, text] of this._keyHintSegments(first)) {
      const key = document.createElement("kbd");
      key.textContent = cap;
      this._editorReadingKeys.append(key);
      if (text) this._editorReadingKeys.append(document.createTextNode(text));
    }
  },

  _keyHintSegments(first) {
    if (first) {
      return [
        ["Enter", " save · "],
        ["Esc", " cancel"],
      ];
    }

    return [
      ["Enter", " later stops move · "],
      ["Alt", "+"],
      ["Enter", " only this stop · "],
      ["⌘", "+"],
      ["Enter", " whole trip moves · "],
      ["Esc", " cancel"],
    ];
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
