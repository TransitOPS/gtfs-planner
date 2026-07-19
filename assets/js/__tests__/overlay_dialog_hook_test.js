/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import OverlayDialog from "../overlay_dialog_hook.js";

let originalShowModal;
let originalClose;
let showModalStub;
let closeStub;

function stubNativeDialog() {
  originalShowModal = HTMLDialogElement.prototype.showModal;
  originalClose = HTMLDialogElement.prototype.close;
  showModalStub = vi.fn(function () {
    this.open = true;
  });
  closeStub = vi.fn(function () {
    this.open = false;
  });
  HTMLDialogElement.prototype.showModal = showModalStub;
  HTMLDialogElement.prototype.close = closeStub;
}

function restoreNativeDialog() {
  if (originalShowModal !== undefined) {
    HTMLDialogElement.prototype.showModal = originalShowModal;
  }
  if (originalClose !== undefined) {
    HTMLDialogElement.prototype.close = originalClose;
  }
}

function buildDialog(attrs = {}) {
  const dialog = document.createElement("dialog");
  if (attrs.id) dialog.id = attrs.id;
  if (attrs.role) dialog.setAttribute("role", attrs.role);
  Object.entries(attrs.dataset || {}).forEach(([k, v]) => {
    dialog.dataset[k] = v;
  });
  if (attrs.innerHTML) dialog.innerHTML = attrs.innerHTML;
  document.body.appendChild(dialog);
  return dialog;
}

function closeButtonHTML(label = "Close") {
  return `<button data-dialog-dismiss>${label}</button>`;
}

function makeHook(dialog) {
  const hook = Object.create(OverlayDialog);
  hook.el = dialog;
  return hook;
}

function makeRendered(element) {
  vi.spyOn(element, "getClientRects").mockReturnValue([{}]);
}

describe("OverlayDialog", () => {
  beforeEach(() => {
    stubNativeDialog();
    document.body.innerHTML = "";
  });

  afterEach(() => {
    restoreNativeDialog();
    vi.restoreAllMocks();
  });

  // =========================================================================
  // Mount / Update reconciliation
  // =========================================================================
  describe("mount and update reconciliation", () => {
    it("calls showModal when data-open is true on mount", () => {
      const dialog = buildDialog({ dataset: { open: "true" } });
      const hook = makeHook(dialog);
      hook.mounted();
      expect(showModalStub).toHaveBeenCalledTimes(1);
      expect(dialog.open).toBe(true);
    });

    it("does not call showModal when data-open is false on mount", () => {
      const dialog = buildDialog({ dataset: { open: "false" } });
      const hook = makeHook(dialog);
      hook.mounted();
      expect(showModalStub).not.toHaveBeenCalled();
    });

    it("calls showModal when data-open changes from false to true on update", () => {
      const dialog = buildDialog({ dataset: { open: "false" } });
      const hook = makeHook(dialog);
      hook.mounted();
      showModalStub.mockClear();

      dialog.dataset.open = "true";
      hook.updated();
      expect(showModalStub).toHaveBeenCalledTimes(1);
    });

    it("calls close when data-open changes from true to false on update", () => {
      const dialog = buildDialog({ dataset: { open: "true" } });
      const hook = makeHook(dialog);
      hook.mounted();
      showModalStub.mockClear();

      dialog.dataset.open = "false";
      hook.updated();
      expect(closeStub).toHaveBeenCalledTimes(1);
    });

    it("is idempotent: does not call showModal again when data-open stays true", () => {
      const dialog = buildDialog({ dataset: { open: "true" } });
      const hook = makeHook(dialog);
      hook.mounted();
      showModalStub.mockClear();

      hook.updated();
      expect(showModalStub).not.toHaveBeenCalled();
    });

    it("is idempotent: does not call close again when data-open stays false", () => {
      const dialog = buildDialog({ dataset: { open: "false" } });
      const hook = makeHook(dialog);
      hook.mounted();
      closeStub.mockClear();

      hook.updated();
      expect(closeStub).not.toHaveBeenCalled();
    });

    it("handles repeated toggles without stacking effects", () => {
      const dialog = buildDialog({ dataset: { open: "false" } });
      const hook = makeHook(dialog);
      hook.mounted();

      dialog.dataset.open = "true";
      hook.updated();
      dialog.dataset.open = "false";
      hook.updated();
      dialog.dataset.open = "true";
      hook.updated();
      dialog.dataset.open = "false";
      hook.updated();

      expect(showModalStub).toHaveBeenCalledTimes(2);
      expect(closeStub).toHaveBeenCalledTimes(2);
    });

    it("guards showModal by native el.open to avoid double open", () => {
      const dialog = buildDialog({ dataset: { open: "true" } });
      dialog.open = true; // already open
      const hook = makeHook(dialog);
      hook.mounted();
      expect(showModalStub).not.toHaveBeenCalled();
    });

    it("guards close by native el.open to avoid double close", () => {
      const dialog = buildDialog({ dataset: { open: "false" } });
      dialog.open = false; // already closed
      const hook = makeHook(dialog);
      hook.mounted();
      expect(closeStub).not.toHaveBeenCalled();
    });

    it("reconciles browser-owned open: update re-examines data-open against native open", () => {
      // data-open is false, but somehow browser open is true (stale)
      const dialog = buildDialog({ dataset: { open: "false" } });
      dialog.open = true;
      const hook = makeHook(dialog);
      hook.mounted();
      closeStub.mockClear();

      hook.updated();
      expect(closeStub).toHaveBeenCalledTimes(1);
    });
  });

  // =========================================================================
  // Focus resolution
  // =========================================================================
  describe("focus resolution", () => {
    it("prevents initial focus from scrolling the animated dialog", () => {
      const dialog = buildDialog({
        dataset: { open: "true", initialFocus: "heading" },
        innerHTML: '<h2 id="my-title" tabindex="-1">Title</h2>',
      });
      dialog.scrollLeft = 720;
      dialog.scrollTop = 40;

      const heading = dialog.querySelector("#my-title");
      const focusSpy = vi.spyOn(heading, "focus");
      const hook = makeHook(dialog);
      hook.mounted();

      expect(focusSpy).toHaveBeenCalledWith({ preventScroll: true });
      expect(dialog.scrollLeft).toBe(0);
      expect(dialog.scrollTop).toBe(0);
    });

    it("focuses an explicit descendant ID when valid", () => {
      const inner =
        '<h2 id="my-title" tabindex="-1">Title</h2><button id="btn-ok">OK</button>';
      const dialog = buildDialog({
        dataset: { open: "true", initialFocusId: "btn-ok" },
        innerHTML: inner,
      });
      const btn = dialog.querySelector("#btn-ok");
      const focusSpy = vi.spyOn(btn, "focus");
      const hook = makeHook(dialog);
      hook.mounted();
      expect(focusSpy).toHaveBeenCalledTimes(1);
    });

    it("falls back to the dialog panel when explicit ID is not in dialog", () => {
      const inner =
        '<h2 id="my-title" tabindex="-1">Title</h2><div id="panel" data-dialog-panel tabindex="-1">Panel</div><button id="btn-ok">OK</button>';
      const dialog = buildDialog({
        dataset: { open: "true", initialFocusId: "nonexistent" },
        innerHTML: inner,
      });
      const panel = dialog.querySelector("#panel");
      const focusSpy = vi.spyOn(panel, "focus");
      const hook = makeHook(dialog);
      hook.mounted();
      expect(focusSpy).toHaveBeenCalledTimes(1);
    });

    it("falls back to panel when explicit ID resolves outside the dialog", () => {
      const outer = document.createElement("div");
      outer.id = "outside-btn";
      document.body.appendChild(outer);

      const inner = '<div data-dialog-panel tabindex="-1" id="panel">Panel</div>';
      const dialog = buildDialog({
        dataset: { open: "true", initialFocusId: "outside-btn" },
        innerHTML: inner,
      });
      const panel = dialog.querySelector("#panel");
      const focusSpy = vi.spyOn(panel, "focus");
      const hook = makeHook(dialog);
      hook.mounted();
      // Should fall through to panel (outside-scope ID is ignored)
      expect(focusSpy).toHaveBeenCalled();
    });

    it("focuses heading when data-initial-focus is heading", () => {
      const inner =
        '<h2 id="my-title" tabindex="-1">Title</h2><button id="btn-ok">OK</button>';
      const dialog = buildDialog({
        dataset: { open: "true", initialFocus: "heading" },
        innerHTML: inner,
      });
      const heading = dialog.querySelector("#my-title");
      const focusSpy = vi.spyOn(heading, "focus");
      const hook = makeHook(dialog);
      hook.mounted();
      expect(focusSpy).toHaveBeenCalledTimes(1);
    });

    it("focuses first visible input when data-initial-focus is first_field", () => {
      const inner =
        '<input id="field-a" /><input id="field-b" /><select id="sel"><option>A</option></select>';
      const dialog = buildDialog({
        dataset: { open: "true", initialFocus: "first_field" },
        innerHTML: inner,
      });
      const first = dialog.querySelector("#field-a");
      makeRendered(first);
      const focusSpy = vi.spyOn(first, "focus");
      const hook = makeHook(dialog);
      hook.mounted();
      expect(focusSpy).toHaveBeenCalledTimes(1);
    });

    it("skips hidden and disabled inputs in first_field mode", () => {
      const inner =
        '<input id="hidden-field" type="hidden" /><input id="disabled-field" disabled /><input id="active-field" />';
      const dialog = buildDialog({
        dataset: { open: "true", initialFocus: "first_field" },
        innerHTML: inner,
      });
      const active = dialog.querySelector("#active-field");
      makeRendered(active);
      const focusSpy = vi.spyOn(active, "focus");
      const hook = makeHook(dialog);
      hook.mounted();
      expect(focusSpy).toHaveBeenCalledTimes(1);
    });

    it("focuses Cancel (dismiss button) for alertdialog without explicit focus mode", () => {
      const inner = closeButtonHTML("Cancel") + "<p>Are you sure?</p>";
      const dialog = buildDialog({
        role: "alertdialog",
        dataset: { open: "true" },
        innerHTML: inner,
      });
      const cancel = dialog.querySelector("[data-dialog-dismiss]");
      const focusSpy = vi.spyOn(cancel, "focus");
      const hook = makeHook(dialog);
      hook.mounted();
      expect(focusSpy).toHaveBeenCalledTimes(1);
    });

    it("falls back to the explicit dialog panel when no focusable target matches", () => {
      const inner = '<div data-dialog-panel tabindex="-1" id="panel">Fallback</div>';
      const dialog = buildDialog({
        dataset: { open: "true" },
        innerHTML: inner,
      });
      const panel = dialog.querySelector("#panel");
      const focusSpy = vi.spyOn(panel, "focus");
      const hook = makeHook(dialog);
      hook.mounted();
      expect(focusSpy).toHaveBeenCalledTimes(1);
    });

    it("never assigns tabindex to the dialog root", () => {
      const dialog = buildDialog({
        dataset: { open: "true" },
        innerHTML: "<p>No interactive elements</p>",
      });
      const hook = makeHook(dialog);
      hook.mounted();
      expect(dialog.hasAttribute("tabindex")).toBe(false);
    });
  });

  // =========================================================================
  // Cancel / Escape / Backdrop dismissal
  // =========================================================================
  describe("cancel, escape, and backdrop dismissal", () => {
    it("prevents default and stops propagation on cancel event", () => {
      const dialog = buildDialog({
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();

      const event = new Event("cancel", { cancelable: true, bubbles: true });
      const preventSpy = vi.spyOn(event, "preventDefault");
      const stopSpy = vi.spyOn(event, "stopPropagation");
      dialog.dispatchEvent(event);

      expect(preventSpy).toHaveBeenCalledTimes(1);
      expect(stopSpy).toHaveBeenCalledTimes(1);
    });

    it("clicks the dismiss button on cancel event", () => {
      const dialog = buildDialog({
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      const dismissBtn = dialog.querySelector("[data-dialog-dismiss]");
      const clickSpy = vi.spyOn(dismissBtn, "click");

      dialog.dispatchEvent(
        new Event("cancel", { cancelable: true, bubbles: true }),
      );
      expect(clickSpy).toHaveBeenCalledTimes(1);
    });

    it("ignores backdrop click when closeOnBackdrop is false", () => {
      const dialog = buildDialog({
        dataset: { open: "true", closeOnBackdrop: "false" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      const dismissBtn = dialog.querySelector("[data-dialog-dismiss]");
      const clickSpy = vi.spyOn(dismissBtn, "click");

      const event = new MouseEvent("click", { bubbles: false, cancelable: true });
      Object.defineProperty(event, "target", {
        value: dialog,
        configurable: true,
      });
      dialog.dispatchEvent(event);
      expect(clickSpy).not.toHaveBeenCalled();
    });

    it("clicks dismiss on backdrop click when closeOnBackdrop is true", () => {
      const dialog = buildDialog({
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      const dismissBtn = dialog.querySelector("[data-dialog-dismiss]");
      const clickSpy = vi.spyOn(dismissBtn, "click");

      const event = new MouseEvent("click", { bubbles: false, cancelable: true });
      Object.defineProperty(event, "target", {
        value: dialog,
        configurable: true,
      });
      dialog.dispatchEvent(event);
      expect(clickSpy).toHaveBeenCalledTimes(1);
    });

    it("does not dismiss when click target is a child, not the dialog backdrop", () => {
      const inner = '<div id="panel">' + closeButtonHTML("Close") + "</div>";
      const dialog = buildDialog({
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: inner,
      });
      const hook = makeHook(dialog);
      hook.mounted();
      const dismissBtn = dialog.querySelector("[data-dialog-dismiss]");
      const clickSpy = vi.spyOn(dismissBtn, "click");

      const panel = dialog.querySelector("#panel");
      const event = new MouseEvent("click", { bubbles: true, cancelable: true });
      Object.defineProperty(event, "target", {
        value: panel,
        configurable: true,
      });
      dialog.dispatchEvent(event);
      expect(clickSpy).not.toHaveBeenCalled();
    });

    it("blocks cancel when pending is true", () => {
      const dialog = buildDialog({
        dataset: { open: "true", pending: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Cancel"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      const dismissBtn = dialog.querySelector("[data-dialog-dismiss]");
      const clickSpy = vi.spyOn(dismissBtn, "click");

      const event = new Event("cancel", { cancelable: true, bubbles: true });
      const preventSpy = vi.spyOn(event, "preventDefault");
      dialog.dispatchEvent(event);

      expect(preventSpy).toHaveBeenCalled();
      expect(clickSpy).not.toHaveBeenCalled();
    });

    it("blocks backdrop click when pending is true", () => {
      const dialog = buildDialog({
        dataset: { open: "true", pending: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Cancel"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      const dismissBtn = dialog.querySelector("[data-dialog-dismiss]");
      const clickSpy = vi.spyOn(dismissBtn, "click");

      const event = new MouseEvent("click", { bubbles: false, cancelable: true });
      Object.defineProperty(event, "target", {
        value: dialog,
        configurable: true,
      });
      dialog.dispatchEvent(event);
      expect(clickSpy).not.toHaveBeenCalled();
    });

    it("isolates nested dialog: cancel on child stops so parent is unaffected", () => {
      const parentDialog = buildDialog({
        id: "parent-dialog",
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Parent Close"),
      });
      const parentHook = makeHook(parentDialog);
      parentHook.mounted();
      const parentDismiss = parentDialog.querySelector("[data-dialog-dismiss]");
      const parentClickSpy = vi.spyOn(parentDismiss, "click");

      const childDialog = buildDialog({
        id: "child-dialog",
        role: "alertdialog",
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Child Cancel"),
      });
      const childHook = makeHook(childDialog);
      childHook.mounted();

      // Dispatch cancel on child only; stopPropagation should prevent parent handler
      const event = new Event("cancel", { cancelable: true, bubbles: false });
      childDialog.dispatchEvent(event);

      // Parent dismiss should not have been clicked
      expect(parentClickSpy).not.toHaveBeenCalled();
    });

    it("dismiss button is activated exactly once per cancel event", () => {
      const dialog = buildDialog({
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      const dismissBtn = dialog.querySelector("[data-dialog-dismiss]");
      const clickSpy = vi.spyOn(dismissBtn, "click");

      dialog.dispatchEvent(
        new Event("cancel", { cancelable: true, bubbles: true }),
      );
      expect(clickSpy).toHaveBeenCalledTimes(1);
    });
  });

  // =========================================================================
  // Close and return focus
  // =========================================================================
  describe("close and return focus", () => {
    it("focuses a connected return_focus_id on deactivation", () => {
      const returnTarget = document.createElement("button");
      returnTarget.id = "return-target";
      document.body.appendChild(returnTarget);

      const dialog = buildDialog({
        id: "test-dialog",
        dataset: {
          open: "true",
          returnFocusId: "return-target",
        },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      const returnSpy = vi.spyOn(returnTarget, "focus");

      dialog.dataset.open = "false";
      hook.updated();

      expect(closeStub).toHaveBeenCalled();
      expect(returnSpy).toHaveBeenCalledTimes(1);
    });

    it("preserves native restoration when return_focus_id is absent", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();

      dialog.dataset.open = "false";
      hook.updated();

      expect(closeStub).toHaveBeenCalled();
    });

    it("does not throw when return_focus_id target is removed from DOM", () => {
      const returnTarget = document.createElement("button");
      returnTarget.id = "return-target";
      document.body.appendChild(returnTarget);

      const dialog = buildDialog({
        id: "test-dialog",
        dataset: {
          open: "true",
          returnFocusId: "return-target",
        },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();

      returnTarget.remove();

      dialog.dataset.open = "false";
      expect(() => hook.updated()).not.toThrow();
      expect(closeStub).toHaveBeenCalled();
    });

    it("does not focus body when opener has been removed", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();

      const bodyFocusSpy = vi.spyOn(document.body, "focus");

      dialog.dataset.open = "false";
      hook.updated();

      expect(bodyFocusSpy).not.toHaveBeenCalled();
    });
  });

  // =========================================================================
  // Disconnect / Reconnect / Destroy
  // =========================================================================
  describe("disconnect, reconnect, and destroy", () => {
    it("disconnected closes an open dialog and restores opener focus", () => {
      const opener = document.createElement("button");
      opener.id = "opener-btn";
      document.body.appendChild(opener);
      opener.focus();

      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      closeStub.mockClear();

      const openerSpy = vi.spyOn(opener, "focus");
      hook.disconnected();

      expect(closeStub).toHaveBeenCalledTimes(1);
      expect(openerSpy).toHaveBeenCalled();
    });

    it("disconnected does nothing when dialog is already closed", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "false" },
        innerHTML: closeButtonHTML("Close"),
      });
      dialog.open = false;
      const hook = makeHook(dialog);
      hook.mounted();
      closeStub.mockClear();

      hook.disconnected();
      expect(closeStub).not.toHaveBeenCalled();
    });

    it("reconnected re-activates when data-open is true and dialog is closed", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      showModalStub.mockClear();

      dialog.open = false;
      hook.reconnected();
      expect(showModalStub).toHaveBeenCalledTimes(1);
    });

    it("reconnected deactivates when data-open is false and dialog is open", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "false" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      closeStub.mockClear();

      dialog.open = true;
      hook.reconnected();
      expect(closeStub).toHaveBeenCalledTimes(1);
    });

    it("reconnected clears stale opener reference", () => {
      const opener = document.createElement("button");
      opener.id = "opener-btn";
      document.body.appendChild(opener);
      opener.focus();

      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();

      expect(hook._overlayDialog_opener).toBe(opener);

      opener.remove();
      hook.reconnected();

      expect(hook._overlayDialog_opener).toBeNull();
    });

    it("destroyed removes listeners and closes if open", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      closeStub.mockClear();

      hook.destroyed();

      expect(closeStub).toHaveBeenCalledTimes(1);

      // After destroy, cancel should not trigger dismiss
      const dismissBtn = dialog.querySelector("[data-dialog-dismiss]");
      const clickSpy = vi.spyOn(dismissBtn, "click");
      dialog.dispatchEvent(
        new Event("cancel", { cancelable: true, bubbles: true }),
      );
      expect(clickSpy).not.toHaveBeenCalled();
    });

    it("destroyed is idempotent: repeated calls do not throw or re-close", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();

      hook.destroyed();
      expect(() => hook.destroyed()).not.toThrow();
      expect(() => hook.destroyed()).not.toThrow();
    });

    it("multiple toggle cycles leave listeners and open state deterministic", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "false", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();

      // Open -> close multiple times
      for (let i = 0; i < 3; i++) {
        dialog.dataset.open = "true";
        hook.updated();
        dialog.dataset.open = "false";
        hook.updated();
      }

      expect(dialog.open).toBe(false);

      // Re-open and verify cancel still works
      dialog.dataset.open = "true";
      hook.updated();
      const dismissBtn = dialog.querySelector("[data-dialog-dismiss]");
      const clickSpy = vi.spyOn(dismissBtn, "click");
      dialog.dispatchEvent(
        new Event("cancel", { cancelable: true, bubbles: true }),
      );
      expect(clickSpy).toHaveBeenCalledTimes(1);
    });

    it("preserves correct showModal/close count through full lifecycle", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true", closeOnBackdrop: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);

      hook.mounted();
      expect(showModalStub).toHaveBeenCalledTimes(1);

      hook.disconnected();
      expect(closeStub).toHaveBeenCalledTimes(1);

      hook.reconnected();
      expect(showModalStub).toHaveBeenCalledTimes(2);

      hook.destroyed();
      expect(closeStub).toHaveBeenCalledTimes(2);
    });
  });

  // =========================================================================
  // Edge cases
  // =========================================================================
  describe("edge cases", () => {
    it("records opener as document.activeElement on activation", () => {
      const opener = document.createElement("button");
      opener.id = "opener-btn";
      document.body.appendChild(opener);
      opener.focus();

      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true" },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();

      expect(hook._overlayDialog_opener).toBe(opener);
    });

    it("handles update when data-open was absent and becomes true", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        innerHTML: closeButtonHTML("Close"),
      });
      dialog.dataset.open = undefined;
      const hook = makeHook(dialog);
      hook.mounted();
      showModalStub.mockClear();

      dialog.dataset.open = "true";
      hook.updated();
      expect(showModalStub).toHaveBeenCalledTimes(1);
    });

    it("does not throw on mount with no focusable elements", () => {
      const dialog = buildDialog({
        id: "test-dialog",
        dataset: { open: "true" },
        innerHTML: "<p>Just text, nothing focusable</p>",
      });
      const hook = makeHook(dialog);
      expect(() => hook.mounted()).not.toThrow();
    });

    it("return_focus_id overrides native restoration on successful close", () => {
      const returnTarget = document.createElement("button");
      returnTarget.id = "success-target";
      document.body.appendChild(returnTarget);

      const dialog = buildDialog({
        id: "test-dialog",
        dataset: {
          open: "true",
          returnFocusId: "success-target",
        },
        innerHTML: closeButtonHTML("Close"),
      });
      const hook = makeHook(dialog);
      hook.mounted();
      const returnSpy = vi.spyOn(returnTarget, "focus");

      dialog.dataset.returnFocusId = "success-target";
      dialog.dataset.open = "false";
      hook.updated();

      expect(closeStub).toHaveBeenCalled();
      expect(returnSpy).toHaveBeenCalledTimes(1);
    });

    it("first_field selects first visible input among mixed inputs", () => {
      const inner = `
        <input id="a" type="hidden" />
        <textarea id="b"></textarea>
        <input id="c" disabled />
        <select id="d"><option>X</option></select>
      `;
      const dialog = buildDialog({
        dataset: { open: "true", initialFocus: "first_field" },
        innerHTML: inner,
      });
      const textarea = dialog.querySelector("#b");
      makeRendered(textarea);
      const focusSpy = vi.spyOn(textarea, "focus");
      const hook = makeHook(dialog);
      hook.mounted();
      expect(focusSpy).toHaveBeenCalledTimes(1);
    });
  });
});
