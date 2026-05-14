/* @vitest-environment jsdom */
import { beforeEach, describe, expect, it, vi } from "vitest";
import GtfsVersionHook from "../gtfs_version_hook";

const ORG_ID = "11111111-2222-3333-4444-555555555555";
const STORAGE_KEY = `gtfs_version_${ORG_ID}`;

function makeHook({ withSelect = true } = {}) {
  const el = document.createElement("div");
  el.dataset.organizationId = ORG_ID;
  if (withSelect) {
    el.innerHTML =
      "<select><option value='v1'>v1</option><option value='v2'>v2</option></select>";
  }
  document.body.appendChild(el);

  const hook = Object.create(GtfsVersionHook);
  hook.el = el;
  hook.pushEvent = vi.fn();
  hook.handleEvent = vi.fn();
  hook.selectVersion = vi.fn();
  return hook;
}

function dispatchChange(select, value) {
  select.value = value;
  select.dispatchEvent(new Event("change"));
}

describe("GtfsVersionHook", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    localStorage.clear();
    window.history.replaceState({}, "", "/gtfs/v1/stations");
  });

  it("binds the initial select on mount and routes changes through selectVersion", () => {
    const hook = makeHook();
    hook.mounted();

    const select = hook.el.querySelector("select");
    dispatchChange(select, "v2");

    expect(hook.selectVersion).toHaveBeenCalledTimes(1);
    expect(hook.selectVersion).toHaveBeenCalledWith("v2");
  });

  it("writes localStorage and rewrites the path inside selectVersion", () => {
    const hook = makeHook();
    hook.storageKey = STORAGE_KEY;

    const hrefSetter = vi.fn();
    const originalLocation = window.location;
    Object.defineProperty(window, "location", {
      configurable: true,
      value: {
        pathname: "/gtfs/v1/stations",
        set href(value) {
          hrefSetter(value);
        },
      },
    });

    try {
      GtfsVersionHook.selectVersion.call(hook, "v9");
    } finally {
      Object.defineProperty(window, "location", {
        configurable: true,
        value: originalLocation,
      });
    }

    expect(localStorage.getItem(STORAGE_KEY)).toBe("v9");
    expect(hrefSetter).toHaveBeenCalledWith("/gtfs/v9/stations");
  });

  it("rebinds to a new select after the inner DOM is patched", () => {
    const hook = makeHook();
    hook.mounted();
    const oldSelect = hook.el.querySelector("select");

    hook.el.innerHTML =
      "<select><option value='v3'>v3</option><option value='v4'>v4</option></select>";
    hook.updated();

    const newSelect = hook.el.querySelector("select");
    expect(newSelect).not.toBe(oldSelect);

    dispatchChange(newSelect, "v4");
    expect(hook.selectVersion).toHaveBeenCalledWith("v4");

    dispatchChange(oldSelect, "v3");
    expect(hook.selectVersion).toHaveBeenCalledTimes(1);
  });

  it("is idempotent: repeated updated() calls do not stack listeners", () => {
    const hook = makeHook();
    hook.mounted();

    hook.updated();
    hook.updated();
    hook.updated();

    dispatchChange(hook.el.querySelector("select"), "v2");
    expect(hook.selectVersion).toHaveBeenCalledTimes(1);
  });

  it("tolerates updated() when the select is absent (edit mode)", () => {
    const hook = makeHook({ withSelect: false });
    hook.mounted();

    expect(() => hook.updated()).not.toThrow();
    expect(hook.boundSelect).toBeNull();
  });

  it("cleans up the listener on destroyed()", () => {
    const hook = makeHook();
    hook.mounted();
    const select = hook.el.querySelector("select");

    hook.destroyed();
    dispatchChange(select, "v2");

    expect(hook.selectVersion).not.toHaveBeenCalled();
    expect(hook.boundSelect).toBeNull();
  });
});
