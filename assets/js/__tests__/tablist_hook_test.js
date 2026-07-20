/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import TablistHook from "../tablist_hook.js";

function tablist(active = "details") {
  document.body.innerHTML = `
    <div id="stop-tabs" role="tablist" phx-hook="TablistHook">
      <button id="stop-tab-details" role="tab" aria-selected="${active === "details"}" tabindex="${active === "details" ? "0" : "-1"}">Details</button>
      <button id="stop-tab-history" role="tab" aria-selected="${active === "history"}" tabindex="${active === "history" ? "0" : "-1"}">History</button>
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
});
