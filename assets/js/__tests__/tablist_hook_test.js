/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import TablistHook from "../tablist_hook.js";

function tablist(active = "details", { journal = false } = {}) {
  const journalHtml = journal
    ? `<button id="stop-tab-journal" role="tab" aria-selected="${active === "journal"}" tabindex="${active === "journal" ? "0" : "-1"}">Journal</button>`
    : "";

  document.body.innerHTML = `
    <div id="stop-tabs" role="tablist" phx-hook="TablistHook">
      <button id="stop-tab-details" role="tab" aria-selected="${active === "details"}" tabindex="${active === "details" ? "0" : "-1"}">Details</button>
      <button id="stop-tab-history" role="tab" aria-selected="${active === "history"}" tabindex="${active === "history" ? "0" : "-1"}">History</button>
      ${journalHtml}
    </div>`;

  const el = document.querySelector("[role=tablist]");
  const hook = Object.create(TablistHook);
  hook.el = el;
  hook.mounted();
  return { el, hook, tabs: Array.from(el.querySelectorAll("[role=tab]")) };
}

function keydown(tab, key) {
  tab.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true }));
}

describe("TablistHook", () => {
  beforeEach(() => { document.body.innerHTML = ""; });
  afterEach(() => vi.restoreAllMocks());

  it("uses Arrow, Home, and End for roving focus and activation", () => {
    const { tabs } = tablist();
    const [details, history] = tabs;
    const historyClick = vi.spyOn(history, "click");
    const detailsClick = vi.spyOn(details, "click");

    details.focus();
    keydown(details, "ArrowRight");
    expect(document.activeElement).toBe(history);
    expect(history.getAttribute("tabindex")).toBe("0");
    expect(details.getAttribute("tabindex")).toBe("-1");
    expect(historyClick).toHaveBeenCalledOnce();

    keydown(history, "Home");
    expect(document.activeElement).toBe(details);
    expect(detailsClick).toHaveBeenCalledOnce();

    keydown(details, "End");
    expect(document.activeElement).toBe(history);
  });

  it("is idempotent across LiveView updates and tears down its listener", () => {
    const { el, hook, tabs } = tablist("history");
    const [details, history] = tabs;
    const click = vi.spyOn(details, "click");

    hook.updated();
    hook.updated();
    history.focus();
    keydown(history, "ArrowLeft");
    expect(click).toHaveBeenCalledOnce();

    hook.destroyed();
    click.mockClear();
    keydown(details, "ArrowRight");
    expect(click).not.toHaveBeenCalled();
    expect(el.querySelectorAll("[role=tab]")).toHaveLength(2);
  });

  it("wraps Arrow, Home, and End across a three-tab DOM without needing changes to TablistHook", () => {
    const { tabs } = tablist("details", { journal: true });
    const [details, history, journal] = tabs;

    const journalClick = vi.spyOn(journal, "click");
    const detailsClick = vi.spyOn(details, "click");
    const historyClick = vi.spyOn(history, "click");

    details.focus();
    keydown(details, "ArrowRight");
    expect(document.activeElement).toBe(history);
    expect(history.getAttribute("tabindex")).toBe("0");
    expect(historyClick).toHaveBeenCalledOnce();

    keydown(history, "ArrowRight");
    expect(document.activeElement).toBe(journal);
    expect(journal.getAttribute("tabindex")).toBe("0");
    expect(journalClick).toHaveBeenCalledOnce();

    keydown(journal, "ArrowLeft");
    expect(document.activeElement).toBe(history);

    keydown(history, "Home");
    expect(document.activeElement).toBe(details);
    expect(detailsClick).toHaveBeenCalledOnce();

    keydown(details, "End");
    expect(document.activeElement).toBe(journal);
  });

  it("handles Journal-selected three-tab roving correctly", () => {
    const { tabs } = tablist("journal", { journal: true });
    const [details, history, journal] = tabs;

    expect(journal.getAttribute("aria-selected")).toBe("true");
    expect(journal.getAttribute("tabindex")).toBe("0");

    journal.focus();
    keydown(journal, "ArrowLeft");
    expect(document.activeElement).toBe(history);

    keydown(history, "ArrowLeft");
    expect(document.activeElement).toBe(details);

    keydown(details, "ArrowLeft");
    expect(document.activeElement).toBe(journal);
  });

  it("preserves two-tab idempotence unchanged", () => {
    const { el, hook, tabs } = tablist("details");
    const [details, history] = tabs;

    expect(el.querySelectorAll("[role=tab]")).toHaveLength(2);

    hook.updated();
    hook.updated();
    expect(details.getAttribute("tabindex")).toBe("0");
    expect(history.getAttribute("tabindex")).toBe("-1");

    history.focus();
    keydown(history, "ArrowLeft");
    expect(document.activeElement).toBe(details);
  });
});
