/**
 * Station report and change history — browser contracts (Package 15).
 *
 * These are the checks that only a real engine can settle: measured layout at
 * four viewport widths, measured target sizes, real keyboard focus movement,
 * the reduced-motion cascade, and print media. Everything provable from
 * rendered markup alone stays in the focused ExUnit suites.
 *
 * Decision 0.12 bounds what is asserted here. Semantic structure, keyboard
 * operation, visible focus, text-plus-colour state, 44 px targets, responsive
 * zoom, and reduced motion are all under test. Speech output, live regions,
 * screen-reader smoke runs, and nonvisual equivalents are deliberately NOT
 * asserted and must not be added to this file.
 *
 * Fixtures come from `mix ecto.reset` + `test/support/browser_seed.exs`:
 * station BROWSER_STATION with platforms A/B, entrance C, one elevator
 * pathway, one long-named isolated generic node, and one agency in
 * America/New_York. The history case writes through the production editor and
 * then reverts through the production rollback, so it restores the seeded stop
 * name and can be re-run without a reseed.
 */
import { test, expect } from "@playwright/test";
import {
  VIEWPORTS,
  bodyFitsViewport,
  readPendingStates,
  watchPendingState,
} from "./browser_helpers";

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const STATION = "BROWSER_STATION";
const CHILD_STOP = "BROWSER_STOP_A";

// Two values long enough to prove that neither the report nor the audit diff
// truncates. The history case picks whichever one differs from the stop's
// current name, so it records a real change no matter what state it starts in
// and can always revert to what it found.
const LONG_NAMES = [
  "Platform A Northbound Upper Mezzanine Interchange Concourse Alpha Extension",
  "Platform A Southbound Lower Mezzanine Interchange Concourse Bravo Extension",
];

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

/**
 * Resolves the seeded version by name from the version switcher.
 *
 * The header task links point at whichever version the session last selected,
 * which is not necessarily the one holding BROWSER_STATION. The switcher lists
 * every version with its id, so reading it by name is deterministic.
 */
async function seededVersionId(page) {
  await page.waitForSelector("#gtfs-version-switcher");

  const id = await page.evaluate(() => {
    const option = Array.from(document.querySelectorAll("[data-version-option]")).find((button) =>
      button.textContent.trim().startsWith("Browser E2E Version"),
    );
    return option ? option.dataset.versionId : null;
  });

  if (!id) throw new Error("Browser E2E Version is missing from the version switcher");
  return id;
}

async function waitForLiveSocket(page) {
  await page.waitForFunction(() => window.liveSocket && window.liveSocket.isConnected(), null, {
    timeout: 20000,
  });
}

async function openReport(page) {
  await logIn(page);
  const versionId = await seededVersionId(page);
  await page.goto(`/gtfs/${versionId}/stops/${STATION}/report`);
  await page.waitForSelector("#report2-station-inventory", { timeout: 20000 });
  await waitForLiveSocket(page);
  return versionId;
}

async function openDiagram(page) {
  await logIn(page);
  const versionId = await seededVersionId(page);
  await page.goto(`/gtfs/${versionId}/stops/${STATION}/diagram`);
  await page.waitForSelector("#diagram-page", { timeout: 20000 });
  await waitForLiveSocket(page);
  // The diagram finishes wiring its canvas after connect; clicking a row before
  // that patch settles loses the event, so wait for the page to go quiet.
  await page.waitForLoadState("networkidle");
  await page.waitForSelector("#child-stops-table", { timeout: 20000 });
  return versionId;
}

/**
 * Opens an entity drawer and waits for it to actually open.
 *
 * A `phx-click` that lands while the diagram is still patching is dropped, so
 * the activation is re-attempted rather than slept on. Every attempt asserts
 * the same production selector.
 */
async function openDrawer(page, locator, overlayId, attempts = 3) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    await locator.click();

    try {
      await page.waitForFunction(
        (id) => document.getElementById(id)?.getAttribute("data-open") === "true",
        overlayId,
        { timeout: 4000 },
      );
      return;
    } catch (error) {
      if (attempt === attempts) throw error;
    }
  }
}

async function expandAllReportDisclosures(page) {
  await page.locator("#report-expand-all").click();
  await page.waitForFunction(
    () => document.getElementById("report-expand-all").getAttribute("aria-expanded") === "true",
    null,
    { timeout: 10000 },
  );
}

async function tabUntilFocused(page, id, maxTabs = 80) {
  for (let attempt = 0; attempt < maxTabs; attempt += 1) {
    await page.keyboard.press("Tab");
    const focused = await page.evaluate(() => document.activeElement?.id ?? null);
    if (focused === id) return;
  }
  throw new Error(`Could not reach #${id} with ${maxTabs} Tab presses`);
}

async function activeElementId(page) {
  return page.evaluate(() => document.activeElement?.id ?? null);
}

// ─────────────────────────────────────────────────────────────────────────────
// AC-11 — responsive layout, 200% zoom, and long values
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Station report responsive contracts", () => {
  for (const viewport of VIEWPORTS) {
    test(`report keeps identity, status, counts and actions at ${viewport.label}`, async ({
      page,
    }) => {
      await openReport(page);
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await expandAllReportDisclosures(page);

      expect(await bodyFitsViewport(page), "the report page clips horizontally").toBe(true);

      // Primary identity, the outcome counts, and one action remain available.
      await expect(page.locator("#station-report-2 h1")).toBeVisible();
      await expect(page.locator("#report-outcome-counts")).toBeVisible();
      await expect(page.locator("#report-expand-all")).toBeVisible();
      await expect(
        page.locator("#station-report-2 [data-status]").first(),
      ).toBeVisible();

      const layout = await page.evaluate(() => {
        const root = document.getElementById("station-report-2");

        // A true comparison table may scroll inside its own labelled region;
        // every such region must be labelled and keyboard reachable.
        // An overflow container wraps its table directly; the disclosure
        // regions that merely contain one are not scroll containers.
        const regions = Array.from(root.querySelectorAll("[role='region']"))
          .filter((region) => region.querySelector(":scope > table"))
          .map((region) => ({
            label: region.getAttribute("aria-label"),
            tabindex: region.getAttribute("tabindex"),
            overflowX: getComputedStyle(region).overflowX,
          }));

        // Non-comparison content wraps instead of scrolling.
        const longValue = Array.from(root.querySelectorAll("[phx-click='select_entity']")).find(
          (el) => el.textContent.includes("Northbound Interchange Concourse"),
        );

        return {
          regions,
          longValue: longValue
            ? { scrollWidth: longValue.scrollWidth, clientWidth: longValue.clientWidth }
            : null,
        };
      });

      expect(layout.longValue, "the long-named isolated node is not rendered").not.toBeNull();
      expect(
        layout.longValue.scrollWidth,
        "a long stop name is clipped instead of wrapping",
      ).toBeLessThanOrEqual(layout.longValue.clientWidth);

      expect(layout.regions.length, "no labelled overflow region is rendered").toBeGreaterThan(0);
      for (const region of layout.regions) {
        expect(region.label, "an overflow region has no accessible label").toBeTruthy();
        expect(region.tabindex, "an overflow region is not keyboard reachable").toBe("0");
        expect(region.overflowX, "an overflow region does not scroll locally").toBe("auto");
      }
    });

    test(`report disclosure and action targets meet 44 px at ${viewport.label}`, async ({
      page,
    }) => {
      await openReport(page);
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await expandAllReportDisclosures(page);

      const controls = await page.evaluate(() =>
        Array.from(
          document.querySelectorAll("#station-report-2 [data-report-control]"),
        ).map((el) => ({
          id: el.id || el.getAttribute("phx-click"),
          height: Math.round(el.getBoundingClientRect().height),
        })),
      );

      expect(controls.length, "the report renders no controls to measure").toBeGreaterThan(0);
      for (const control of controls) {
        expect(control.height, `${control.id} is a ${control.height} px target`).toBeGreaterThanOrEqual(
          44,
        );
      }
    });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// AC-10 — keyboard operation, visible focus, disclosures, reduced motion
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Station report keyboard and motion contracts", () => {
  test("a disclosure is reachable by Tab, shows focus, toggles with Enter, and keeps focus", async ({
    page,
  }) => {
    await openReport(page);
    await page.setViewportSize({ width: 1280, height: 900 });

    await tabUntilFocused(page, "report-expand-all");

    const focusRing = await page.evaluate(() => {
      const el = document.getElementById("report-expand-all");
      const style = getComputedStyle(el);
      return {
        focusVisible: el.matches(":focus-visible"),
        boxShadow: style.boxShadow,
        outline: style.outlineStyle,
        expanded: el.getAttribute("aria-expanded"),
      };
    });

    expect(focusRing.focusVisible, "the disclosure does not match :focus-visible").toBe(true);
    expect(
      focusRing.boxShadow !== "none" || focusRing.outline !== "none",
      "the focused disclosure has no visible focus indicator",
    ).toBe(true);
    expect(focusRing.expanded).toBe("false");

    await page.keyboard.press("Enter");
    await page.waitForFunction(
      () => document.getElementById("report-expand-all").getAttribute("aria-expanded") === "true",
      null,
      { timeout: 10000 },
    );

    // Focus survives the LiveView round trip that re-renders the control.
    expect(await activeElementId(page)).toBe("report-expand-all");

    // Every disclosure names the region it controls, and the region exists.
    const disclosures = await page.evaluate(() => {
      const buttons = Array.from(
        document.querySelectorAll("#station-report-2 button[aria-expanded]"),
      );
      return buttons.map((button) => ({
        controls: button.getAttribute("aria-controls"),
        expanded: button.getAttribute("aria-expanded"),
        regionPresent: !!document.getElementById(button.getAttribute("aria-controls")),
      }));
    });

    expect(disclosures.length).toBeGreaterThan(1);
    for (const disclosure of disclosures) {
      expect(disclosure.controls, "a disclosure controls nothing").toBeTruthy();
      expect(disclosure.regionPresent, `no region for ${disclosure.controls}`).toBe(true);
    }
  });

  test("reduced motion removes report transitions and skeleton animation", async ({ page }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await openReport(page);
    await page.setViewportSize({ width: 1280, height: 900 });

    const durations = await page.evaluate(() => {
      const sample = (el) => {
        if (!el) return null;
        const style = getComputedStyle(el);
        return { transition: style.transitionDuration, animation: style.animationDuration };
      };

      const control = document.querySelector("#station-report-2 [data-report-control]");
      return {
        control: sample(control),
        icon: sample(control && control.querySelector("span")),
      };
    });

    expect(durations.control.transition).toBe("0s");
    expect(durations.control.animation).toBe("0s");
    expect(durations.icon.transition).toBe("0s");
    expect(durations.icon.animation).toBe("0s");
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC-13 / INV-006 — print media on a report nobody has expanded
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Station report print evidence", () => {
  test("a newly loaded report prints complete evidence without chrome, controls, or drawers", async ({
    page,
  }) => {
    await openReport(page);
    await page.setViewportSize({ width: 1280, height: 900 });

    // Nothing is clicked before print media is emulated: print completeness
    // must not depend on prior disclosure interaction.
    const untouched = await page.evaluate(
      () => document.querySelectorAll("#station-report-2 [aria-expanded='true']").length,
    );
    expect(untouched, "a disclosure was already open before printing").toBe(0);

    await page.emulateMedia({ media: "print" });

    const printed = await page.evaluate(() => {
      const root = document.getElementById("station-report-2");
      const visible = (el) => el && getComputedStyle(el).display !== "none";
      const ids = (selector) => Array.from(root.querySelectorAll(selector)).map((el) => el.id);
      const allVisible = (selector) =>
        Array.from(root.querySelectorAll(selector)).every((el) => visible(el));

      const controls = Array.from(root.querySelectorAll("[data-report-control]"));

      return {
        headings: Array.from(root.querySelectorAll("h2")).map((h) => h.textContent.trim()),
        h1: Array.from(root.querySelectorAll("h1")).map((h) => h.textContent.trim()),
        checkRegions: ids("[id^='check-detail-']"),
        checkAllVisible: allVisible("[id^='check-detail-']"),
        connectivityRegions: ids("[id^='connectivity-detail-']"),
        connectivityAllVisible: allVisible("[id^='connectivity-detail-']"),
        routeRegions: ids("[id^='route-']"),
        routeAllVisible: allVisible("[id^='route-']"),
        stepRows: root.querySelectorAll("[id^='route-'] table tbody tr").length,
        totalControls: controls.length,
        visibleControls: controls.filter(visible).length,
        headerVisible: visible(document.getElementById("app-header")),
        subHeaderVisible: visible(document.getElementById("sub-header-wrapper")),
        visibleDialogs: Array.from(document.querySelectorAll("dialog")).filter(visible).length,
        headerRepeats: Array.from(root.querySelectorAll("thead")).every(
          (thead) => getComputedStyle(thead).display === "table-header-group",
        ),
      };
    });

    // Station identity and all six section headings.
    expect(printed.h1).toEqual(["Browser Test Station"]);
    expect(printed.headings).toEqual([
      "Station Inventory",
      "Data Quality",
      "GPS",
      "Naming & ID Conventions",
      "Reachability & Connectivity",
      "Pathway Field Completeness",
    ]);

    // Every failed-check detail and every connectivity source/target/route.
    expect(printed.checkRegions.length, "no failed-check detail is printed").toBeGreaterThan(0);
    expect(printed.checkAllVisible, "a failed-check detail is hidden in print").toBe(true);

    expect(
      printed.connectivityRegions.length,
      "no connectivity source detail is printed",
    ).toBeGreaterThan(0);
    expect(printed.connectivityAllVisible, "a connectivity source is hidden in print").toBe(true);

    expect(printed.routeRegions.length, "no connectivity route is printed").toBeGreaterThan(0);
    expect(printed.routeAllVisible, "a connectivity route is hidden in print").toBe(true);
    expect(printed.stepRows, "no route step rows are printed").toBeGreaterThan(0);

    // Chrome, controls, and overlays are not evidence.
    expect(printed.totalControls).toBeGreaterThan(0);
    expect(printed.visibleControls, "a report control survives into print").toBe(0);
    expect(printed.headerVisible, "the application header prints").toBe(false);
    expect(printed.subHeaderVisible, "the sub header prints").toBe(false);
    expect(printed.visibleDialogs, "a drawer prints").toBe(0);

    // Usable pagination: table headers repeat across printed pages.
    expect(printed.headerRepeats, "a table header does not repeat across pages").toBe(true);

    await page.emulateMedia({ media: "screen" });
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC-14 / AC-7 — the report stop drawer
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Station report stop drawer", () => {
  test("opens focused, stays one column at 320 px, acknowledges submit, and restores the opener", async ({
    page,
  }) => {
    await openReport(page);
    await page.setViewportSize({ width: 320, height: 640 });
    await expandAllReportDisclosures(page);

    const openerId = await page.evaluate(
      () => document.querySelector("#station-report-2 [phx-click='select_entity']").id,
    );

    await page.locator(`[id="${openerId}"]`).click();
    await page.waitForSelector("#report-stop-edit-form", { timeout: 10000 });

    const opened = await page.evaluate(() => {
      const form = document.getElementById("report-stop-edit-form");
      const controls = Array.from(
        form.querySelectorAll("input:not([type='hidden']), select"),
      );

      return {
        active: document.activeElement?.id ?? null,
        returnFocusId: document
          .getElementById("report-entity-drawer-overlay")
          .getAttribute("data-return-focus-id"),
        leftEdges: Array.from(
          new Set(controls.map((el) => Math.round(el.getBoundingClientRect().left))),
        ),
        controlCount: controls.length,
        submitHeight: Math.round(
          form.querySelector("button[type='submit']").getBoundingClientRect().height,
        ),
        formScrollWidth: form.scrollWidth,
        formClientWidth: form.clientWidth,
        pathwayFormPresent: !!document.getElementById("report-pathway-edit-form"),
      };
    });

    // The drawer takes focus into the form, and the opener is recorded.
    expect(opened.active).toBe("stop_stop_name");
    expect(opened.returnFocusId).toBe(openerId);

    // One column: every control shares a single left edge at 320 px.
    expect(opened.controlCount).toBe(6);
    expect(opened.leftEdges, "the stop form is not one column at 320 px").toHaveLength(1);
    expect(opened.formScrollWidth).toBeLessThanOrEqual(opened.formClientWidth);
    expect(await bodyFitsViewport(page), "the drawer clips the page at 320 px").toBe(true);

    // Only the reachable stop form exists; the pathway form is gone.
    expect(opened.pathwayFormPresent).toBe(false);
    expect(opened.submitHeight).toBeGreaterThanOrEqual(44);

    // Submitting acknowledges immediately and prevents a duplicate submit.
    await watchPendingState(page, "#report-stop-edit-form button[type='submit']");
    await page.locator("#report-stop-edit-form button[type='submit']").click();

    const pendingStates = await readPendingStates(page);
    expect(
      pendingStates.some((state) => state.disabled && state.text === "Saving…"),
      `submit never showed a disabled "Saving…" state: ${JSON.stringify(pendingStates)}`,
    ).toBe(true);

    // The drawer closes on a successful save and focus returns to the opener.
    await page.waitForFunction(
      () =>
        document
          .getElementById("report-entity-drawer-overlay")
          .getAttribute("data-open") === "false",
      null,
      { timeout: 15000 },
    );
    await expect
      .poll(async () => activeElementId(page), { timeout: 5000 })
      .toBe(openerId);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC-20 — Details/History tab semantics for all three drawer hosts
// ─────────────────────────────────────────────────────────────────────────────
test.describe("History tab keyboard contracts", () => {
  async function readTabs(page, entity) {
    return page.evaluate((prefix) => {
      const tabs = Array.from(document.querySelectorAll(`#${prefix}-tabs [role='tab']`)).map(
        (tab) => ({
          id: tab.id,
          selected: tab.getAttribute("aria-selected"),
          tabindex: tab.getAttribute("tabindex"),
          controls: tab.getAttribute("aria-controls"),
          height: Math.round(tab.getBoundingClientRect().height),
        }),
      );

      const panel = (id) => document.getElementById(id);

      return {
        role: document.getElementById(`${prefix}-tabs`).getAttribute("role"),
        tabs,
        detailsHidden: panel(`${prefix}-panel-details`).hasAttribute("hidden"),
        historyHidden: panel(`${prefix}-panel-history`).hasAttribute("hidden"),
        detailsLabelledBy: panel(`${prefix}-panel-details`).getAttribute("aria-labelledby"),
        historyLabelledBy: panel(`${prefix}-panel-history`).getAttribute("aria-labelledby"),
        active: document.activeElement?.id ?? null,
      };
    }, entity);
  }

  async function assertTabContract(page, entity) {
    const initial = await readTabs(page, entity);

    expect(initial.role).toBe("tablist");
    expect(initial.tabs.map((tab) => tab.id)).toEqual([
      `${entity}-tab-details`,
      `${entity}-tab-history`,
    ]);
    expect(initial.tabs.map((tab) => tab.controls)).toEqual([
      `${entity}-panel-details`,
      `${entity}-panel-history`,
    ]);
    expect(initial.detailsLabelledBy).toBe(`${entity}-tab-details`);
    expect(initial.historyLabelledBy).toBe(`${entity}-tab-history`);
    expect(initial.tabs.map((tab) => tab.selected)).toEqual(["true", "false"]);
    expect(initial.tabs.map((tab) => tab.tabindex)).toEqual(["0", "-1"]);
    expect(initial.detailsHidden).toBe(false);
    expect(initial.historyHidden).toBe(true);
    for (const tab of initial.tabs) {
      expect(tab.height, `${tab.id} is a ${tab.height} px target`).toBeGreaterThanOrEqual(44);
    }

    // ArrowRight moves the roving tab stop and selects the History panel.
    await page.locator(`#${entity}-tab-details`).focus();
    await page.keyboard.press("ArrowRight");
    await page.waitForSelector(`#${entity}-tab-history[aria-selected='true']`, { timeout: 10000 });

    const afterRight = await readTabs(page, entity);
    expect(afterRight.active).toBe(`${entity}-tab-history`);
    expect(afterRight.tabs.map((tab) => tab.tabindex)).toEqual(["-1", "0"]);
    expect(afterRight.detailsHidden).toBe(true);
    expect(afterRight.historyHidden).toBe(false);

    // ArrowLeft returns, Home selects the first tab, End the last.
    await page.keyboard.press("ArrowLeft");
    await page.waitForSelector(`#${entity}-tab-details[aria-selected='true']`, { timeout: 10000 });
    expect(await activeElementId(page)).toBe(`${entity}-tab-details`);

    await page.keyboard.press("End");
    await page.waitForSelector(`#${entity}-tab-history[aria-selected='true']`, { timeout: 10000 });
    expect(await activeElementId(page)).toBe(`${entity}-tab-history`);

    await page.keyboard.press("Home");
    await page.waitForSelector(`#${entity}-tab-details[aria-selected='true']`, { timeout: 10000 });
    expect(await activeElementId(page)).toBe(`${entity}-tab-details`);
  }

  test("the stop drawer tabs stay synchronized under Arrow, Home and End", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await openDiagram(page);

    await openDrawer(
      page,
      page.locator("button[phx-click='edit_child_stop']", { hasText: CHILD_STOP }).first(),
      "child-stop-drawer-overlay",
    );

    await assertTabContract(page, "stop");
  });

  test("the pathway drawer tabs stay synchronized under Arrow, Home and End", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await openDiagram(page);

    await openDrawer(
      page,
      page.locator("#pathways-table button[phx-click='edit_pathway']").first(),
      "pathway-drawer-overlay",
    );

    await assertTabContract(page, "pathway");
  });

  test("the level sidebar tabs stay synchronized under Arrow, Home and End", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await openDiagram(page);

    await page.locator("#level-control-trigger").click();
    await page.waitForSelector("#edit-level-action", { state: "visible", timeout: 10000 });
    await openDrawer(page, page.locator("#edit-level-action"), "level-sidebar-overlay");

    await assertTabContract(page, "level");
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC-17 / AC-18 / AC-19 — history evidence and rollback focus outcomes
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Change history and rollback", () => {
  test("an edit is audited, rendered in agency time, and reverted with deterministic focus", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await openDiagram(page);

    const openStopDrawer = () =>
      openDrawer(
        page,
        page.locator("button[phx-click='edit_child_stop']", { hasText: CHILD_STOP }).first(),
        "child-stop-drawer-overlay",
      );

    // 1. Write a real change through the production editor.
    await openStopDrawer();
    const originalName = await page.inputValue("#child-stop-form input[name='stop_name']");
    const newName = LONG_NAMES.find((candidate) => candidate !== originalName);
    expect(newName.length).toBeGreaterThan(60);

    await page.fill("#child-stop-form input[name='stop_name']", newName);
    await page.locator("#child-stop-form button[type='submit']").click();
    await expect
      .poll(
        async () =>
          page.locator("button[phx-click='edit_child_stop']", { hasText: CHILD_STOP }).count(),
        { timeout: 10000 },
      )
      .toBeGreaterThan(0);

    // 2. The History panel renders that change.
    await openStopDrawer();
    await page.locator("#stop-tab-history").click();
    await page.waitForFunction(
      () => document.querySelector("#history-stop")?.dataset.state === "ready",
      null,
      { timeout: 20000 },
    );

    const history = await page.evaluate(() => {
      const entry = document.querySelector("[data-role='history-entry']");
      // The audit row lists every changed field; assert the one under test.
      const nameChange = entry.querySelector(
        "[data-role='version-diff-change'][data-change-key='stop_name']",
      );
      const after = nameChange?.querySelector("[data-role='version-diff-after']");
      const time = entry.querySelector("time[datetime]");

      return {
        entryCount: document.querySelectorAll("[data-role='history-entry']").length,
        zoneNotes: [
          document.getElementById("history-timezone-stop")?.textContent.trim(),
          document.getElementById("history-utc-fallback-stop")?.textContent.trim(),
        ].filter(Boolean),
        countStripMode: document
          .getElementById("history-counts-stop")
          .getAttribute("data-mode"),
        filterSelect: !!document.getElementById("history-filter-stop"),
        diffRows: entry.querySelectorAll("[data-role='version-diff-row']").length,
        statusWord: entry
          .querySelector("[data-role='version-diff-status']")
          ?.textContent.trim(),
        changeLabel: nameChange
          ?.querySelector("[data-role='version-diff-change-label']")
          ?.textContent.trim(),
        changeKey: nameChange
          ?.querySelector("[data-role='version-diff-change-key']")
          ?.textContent.trim(),
        afterText: after?.textContent.trim(),
        afterFits: after ? after.scrollWidth <= after.clientWidth : null,
        // Stored timestamps stay UTC; only the display is localized.
        storedUtc: time?.getAttribute("datetime"),
        shownTime: time?.textContent.trim(),
        actionId: document.querySelector("[data-history-entry-action]")?.id,
      };
    });

    expect(history.entryCount).toBeGreaterThan(0);
    // Exactly one zone statement per panel, and it names the agency zone.
    expect(history.zoneNotes).toHaveLength(1);
    expect(history.zoneNotes[0]).toContain("America/New_York");
    expect(history.countStripMode).toBe("display");
    expect(history.filterSelect).toBe(true);
    expect(history.diffRows).toBe(1);
    expect(history.statusWord).toBe("Applied");

    // A human label with the raw GTFS key as secondary metadata (AC-18).
    expect(history.changeLabel).toBe("Stop name");
    expect(history.changeKey).toBe("stop_name");

    // The 74-character new value renders whole and unclipped.
    expect(history.afterText).toBe(newName);
    expect(history.afterFits, "the audit value is clipped instead of wrapping").toBe(true);

    // Stored UTC, displayed as unpadded 12-hour agency-local time.
    expect(history.storedUtc).toMatch(/Z$|\+00:00$/);
    expect(history.shownTime).toMatch(/^(?!0)\d{1,2}:\d{2} (AM|PM)$/);

    // 3. Rollback preview: focus moves into the preview, cancel returns it.
    await page.locator("[data-history-entry-action]").first().click();
    await page.waitForSelector("#rollback-preview-stop", { timeout: 10000 });

    const preview = await page.evaluate(() => ({
      active: document.activeElement?.id ?? null,
      heading: document.getElementById("rollback-preview-heading-stop")?.textContent.trim(),
      confirmHeight: Math.round(
        document.getElementById("rollback-preview-confirm-stop").getBoundingClientRect().height,
      ),
      confirmLabel: document
        .getElementById("rollback-preview-confirm-stop")
        .textContent.trim(),
      cancelPresent: !!document.getElementById("rollback-preview-cancel-stop"),
    }));

    expect(preview.active).toBe("rollback-preview-stop");
    expect(preview.heading, "the preview does not name the stop").toContain(newName);
    expect(preview.confirmLabel).toBe("Revert stop");
    expect(preview.confirmHeight).toBeGreaterThanOrEqual(44);
    expect(preview.cancelPresent).toBe(true);

    await page.locator("#rollback-preview-cancel-stop").click();
    await expect
      .poll(async () => activeElementId(page), { timeout: 10000 })
      .toBe(history.actionId);

    // 4. Confirm the revert: focus lands on the replacement entry and the
    //    seeded value is restored, so this spec is re-runnable.
    await page.locator("[data-history-entry-action]").first().click();
    await page.waitForSelector("#rollback-preview-confirm-stop", { timeout: 10000 });
    await page.locator("#rollback-preview-confirm-stop").click();
    await page.waitForFunction(
      () => document.querySelector("#history-stop")?.dataset.state === "ready",
      null,
      { timeout: 20000 },
    );

    await expect
      .poll(async () => activeElementId(page), { timeout: 10000 })
      .toMatch(/^history-entry-/);

    const reverted = await page.evaluate(() => {
      const entry = document.querySelector("[data-role='history-entry']");
      return {
        statusWord: entry.querySelector("[data-role='version-diff-status']")?.textContent.trim(),
        text: entry.textContent.replace(/\s+/g, " ").trim(),
      };
    });

    expect(reverted.statusWord).toBe("Rejected");
    expect(reverted.text).toContain("Reverted by");

    await page.locator("#stop-tab-details").click();
    await page.waitForSelector("#child-stop-form", { timeout: 10000 });
    expect(await page.inputValue("#child-stop-form input[name='stop_name']")).toBe(originalName);
  });

  test("the history panel fits a 320 px drawer without clipping", async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 640 });
    await openDiagram(page);

    await openDrawer(
      page,
      page.locator("button[phx-click='edit_child_stop']", { hasText: CHILD_STOP }).first(),
      "child-stop-drawer-overlay",
    );
    await page.locator("#stop-tab-history").click();
    await page.waitForFunction(
      () => {
        const state = document.querySelector("#history-stop")?.dataset.state;
        return state && state !== "loading";
      },
      null,
      { timeout: 20000 },
    );

    const narrow = await page.evaluate(() => {
      const panel = document.getElementById("history-stop");
      return { scrollWidth: panel.scrollWidth, clientWidth: panel.clientWidth };
    });

    expect(narrow.scrollWidth).toBeLessThanOrEqual(narrow.clientWidth);
    expect(await bodyFitsViewport(page), "the history panel clips the page at 320 px").toBe(true);
  });
});
