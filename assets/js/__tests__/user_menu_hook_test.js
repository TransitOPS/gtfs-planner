/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import UserMenuHook from "../user_menu_hook.js";

function userMenu() {
  document.body.innerHTML = `
    <div id="user-menu" phx-hook="UserMenu">
      <button data-user-menu-trigger aria-haspopup="menu" aria-expanded="false" aria-controls="user-menu-panel">
        user@test.com
      </button>
      <div id="user-menu-panel" data-user-menu-panel role="menu" hidden>
        <a href="/users/settings" role="menuitem">Account settings</a>
        <a href="/users/log_out" role="menuitem">Log out</a>
      </div>
    </div>
    <a href="/outside" id="outside">Outside</a>`;

  const el = document.getElementById("user-menu");
  const hook = Object.create(UserMenuHook);
  hook.el = el;
  hook.mounted();

  return {
    el,
    hook,
    trigger: el.querySelector("[data-user-menu-trigger]"),
    panel: el.querySelector("[data-user-menu-panel]"),
    items: Array.from(el.querySelectorAll('[role="menuitem"]')),
  };
}

function keydown(target, key) {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true }));
}

describe("UserMenuHook", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
  });
  afterEach(() => vi.restoreAllMocks());

  it("opens on trigger click and focuses the first item", () => {
    const { trigger, panel, items } = userMenu();

    trigger.click();

    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    expect(panel.hidden).toBe(false);
    expect(document.activeElement).toBe(items[0]);
  });

  it("toggles closed on a second trigger click", () => {
    const { trigger, panel } = userMenu();

    trigger.click();
    trigger.click();

    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(panel.hidden).toBe(true);
  });

  it("opens to the last item when ArrowUp is pressed on the trigger", () => {
    const { trigger, items } = userMenu();

    keydown(trigger, "ArrowUp");

    expect(document.activeElement).toBe(items[items.length - 1]);
  });

  it("wraps roving focus with ArrowDown/ArrowUp/Home/End", () => {
    const { trigger, items } = userMenu();
    const [settings, logout] = items;

    trigger.click();
    expect(document.activeElement).toBe(settings);

    keydown(settings, "ArrowDown");
    expect(document.activeElement).toBe(logout);

    keydown(logout, "ArrowDown");
    expect(document.activeElement).toBe(settings);

    keydown(settings, "End");
    expect(document.activeElement).toBe(logout);

    keydown(logout, "Home");
    expect(document.activeElement).toBe(settings);

    keydown(settings, "ArrowUp");
    expect(document.activeElement).toBe(logout);
  });

  it("closes on Escape and returns focus to the trigger", () => {
    const { trigger, panel, items } = userMenu();

    trigger.click();
    keydown(items[0], "Escape");

    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(panel.hidden).toBe(true);
    expect(document.activeElement).toBe(trigger);
  });

  it("closes on Tab without stealing focus back to the trigger", () => {
    const { trigger, panel, items } = userMenu();

    trigger.click();
    keydown(items[0], "Tab");

    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(panel.hidden).toBe(true);
    expect(document.activeElement).not.toBe(trigger);
  });

  it("closes when pointing outside the menu, leaving focus where it landed", () => {
    const { trigger, panel } = userMenu();
    const outside = document.getElementById("outside");

    trigger.click();
    outside.dispatchEvent(new Event("pointerdown", { bubbles: true }));

    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(panel.hidden).toBe(true);
    expect(document.activeElement).not.toBe(trigger);
  });

  it("ignores pointerdown inside the menu", () => {
    const { trigger, panel, items } = userMenu();

    trigger.click();
    items[0].dispatchEvent(new Event("pointerdown", { bubbles: true }));

    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    expect(panel.hidden).toBe(false);
  });

  it("tears down listeners on destroy", () => {
    const { hook, trigger, panel } = userMenu();

    hook.destroyed();
    trigger.click();

    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(panel.hidden).toBe(true);
  });
});
