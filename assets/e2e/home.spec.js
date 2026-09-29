import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers.js";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

// Logged-in homepage browser journeys (26-homepage, step 22; EV-21).
//
// Every state this file measures is the committed browser seed
// (`test/support/browser_seed.exs`, users 5-7 plus the existing access seeds)
// rendered by the real `/` route through `GtfsPlanner.Home`:
//
//   * planner-attention   home-planner@gtfs-planner.test        #home-planner
//   * planner-newmember   home-planner-member@gtfs-planner.test #home-planner
//   * pathways-board      home-pathways@gtfs-planner.test       #home-pathways
//   * admin-only          admin-contracts@gtfs-planner.test     #home-admin-only
//   * no-version          account-no-version@gtfs-planner.test  #dashboard-no-version
//   * no-task             account-no-task@gtfs-planner.test     #dashboard-no-task-access
//   * system-admin        browser-test@gtfs-planner.test        #dashboard-system-administrator
//
// The assertions are the acceptance criteria's numbers (AC-6, AC-24, AC-34),
// never values read back from the surface under test: no document overflow at
// 1440x900 and 390x844, controls at least 44px tall, at most one visible
// `.bg-action` primary, a visible focus outline under Tab, and the board's URL
// params, "Not started" filter, ID search and mobile column hiding.
//
// Captures are written only when `HOME_CAPTURE_DIR` is set (EV-21 runs with
// `HOME_CAPTURE_DIR=../.specs/26-homepage/evidence/app-captures`, resolved
// against the assets working directory). They are the visual-loop and QA-tour
// inputs, not the gate's oracle.

const PASSWORD = "BrowserTest123!";

const STATES = [
  {
    label: "planner-attention",
    user: { email: "home-planner@gtfs-planner.test", password: PASSWORD },
    root: "#home-planner",
    ready: "#attention",
    primary: "Open calendars",
    contains: { selector: "#check-badge", text: "No errors · 12 warnings" },
  },
  {
    label: "planner-newmember",
    user: { email: "home-planner-member@gtfs-planner.test", password: PASSWORD },
    root: "#home-planner",
    ready: "#resume-list li:not(#resume-empty)",
    // The member shares the version's attention state (calendars end in ten
    // days), so its first item stays the page's primary; what changes for a
    // member without own changes is the resume list: the team's destinations.
    primary: "Open calendars",
    contains: { selector: "#resume-title", text: "What your team changed recently" },
  },
  {
    label: "pathways-board",
    user: { email: "home-pathways@gtfs-planner.test", password: PASSWORD },
    root: "#home-pathways",
    ready: "#board-rows tr",
    primary: "Open floorplan",
    contains: { selector: "#board-count", text: "Showing 12 of 14" },
  },
  {
    label: "admin-only",
    user: { email: "admin-contracts@gtfs-planner.test", password: "AdminContracts123!" },
    root: "#home-admin-only",
    ready: "#home-admin-only",
    primary: "Manage users",
    contains: { selector: "#home-admin-only", text: "People at Admin Contracts Org" },
  },
  {
    label: "no-version",
    user: { email: "account-no-version@gtfs-planner.test", password: "AccountNoVersion123!" },
    root: "#dashboard-no-version",
    ready: "#dashboard-no-version",
    primary: null,
    contains: { selector: "#org-admins", text: "account-admin@gtfs-planner.test" },
  },
  {
    label: "no-task",
    user: { email: "account-no-task@gtfs-planner.test", password: "AccountNoTask123!" },
    root: "#dashboard-no-task-access",
    ready: "#dashboard-no-task-access",
    primary: null,
    contains: { selector: "#org-admins", text: "account-admin@gtfs-planner.test" },
  },
  {
    label: "system-admin",
    user: { email: "browser-test@gtfs-planner.test", password: PASSWORD },
    root: "#dashboard-system-administrator",
    ready: "#dashboard-system-administrator",
    primary: "Manage organizations",
    contains: { selector: "#system-admin-title", text: "Organizations" },
  },
];

const VIEWPORTS = [
  { label: "1440x900", width: 1440, height: 900 },
  { label: "390x844", width: 390, height: 844 },
];

// The async regions' skeletons. Measuring before they resolve would assert on
// the loading layout instead of the state's final geometry.
const SKELETON_IDS = "#resume-loading, #share-loading, #attention-loading, #board-loading";

const captureDir = process.env.HOME_CAPTURE_DIR
  ? resolve(process.cwd(), process.env.HOME_CAPTURE_DIR)
  : null;

if (captureDir) {
  mkdirSync(captureDir, { recursive: true });
}

async function logIn(page, user) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return main && !main.hasAttribute("data-phx-pending");
  });
  await page.evaluate(async () => {
    if (document.fonts?.ready) await document.fonts.ready;
  });
}

// The page is loaded when the LiveView is connected and every region has left
// its skeleton. `[data-phx-main].phx-connected` is the connected marker the
// browser suite uses; the skeleton ids are the regions' own loading states.
async function waitForRegions(page) {
  await waitForLiveView(page);
  await page.waitForSelector("[data-phx-main].phx-connected", { state: "attached" });
  await expect(page.locator(SKELETON_IDS)).toHaveCount(0);
}

async function openHome(page, state) {
  await page.context().clearCookies();
  await logIn(page, state.user);
  await page.goto("/");
  await waitForRegions(page);
  await expect(page.locator(state.root)).toBeVisible();
  await page.waitForSelector(state.ready, { state: "visible" });
}

async function openHomeIn(page, state, viewport) {
  await page.setViewportSize({ width: viewport.width, height: viewport.height });
  await page.goto("/");
  await waitForRegions(page);
  await expect(page.locator(state.root)).toBeVisible();
  await page.waitForSelector(state.ready, { state: "visible" });
}

async function visiblePrimaries(page) {
  return page.locator("#home-page .bg-action:visible").allTextContents();
}

// Tabs from the top of the document and asserts that every control the page's
// own scope receives shows a visible indicator while focused. Controls outside
// `#home-page` (the production header) are skipped: header focus is the
// account-navigation block's contract, not this page's.
async function assertTabFocusOutlines(page, max = 60) {
  const controls = page.locator(
    "#home-page a:visible, #home-page button:visible, #home-page input:visible",
  );

  // The access states without a contact card have no focusable page control;
  // there is nothing to tab through and nothing to assert.
  if ((await controls.count()) === 0) return;

  const checked = [];

  for (let i = 0; i < max; i++) {
    await page.keyboard.press("Tab");
    const focused = await page.evaluate(() => {
      const el = document.activeElement;
      if (!el || el === document.body) return null;
      const style = window.getComputedStyle(el);
      return {
        inside: Boolean(el.closest("#home-page")),
        id: el.id,
        tag: el.tagName.toLowerCase(),
        outlineStyle: style.outlineStyle,
        outlineWidth: parseFloat(style.outlineWidth || "0"),
        boxShadow: style.boxShadow,
      };
    });

    if (!focused) break;
    if (!focused.inside) {
      if (checked.length > 0) break; // wrapped past the page's controls
      continue;
    }

    const label = focused.id || focused.tag;
    const ringVisible = focused.boxShadow !== "none" && focused.boxShadow.includes("rgb");
    // AC-34: a visible 2 px outline, which `#home-page`'s focus rule draws.
    const outlineVisible = focused.outlineStyle !== "none" && focused.outlineWidth >= 2;
    expect(outlineVisible || ringVisible, `focus indicator on ${label}`).toBe(true);
    checked.push(label);
  }

  // A state with page controls must receive focus on at least one of them;
  // otherwise the loop never entered `#home-page`.
  expect(checked.length).toBeGreaterThan(0);
}

test.describe("homepage states", () => {
  test("no overflow, 44px targets, one primary and a focus outline per seeded state", async ({
    page,
  }) => {
    test.setTimeout(600_000);

    for (const state of STATES) {
      await openHome(page, state);

      await page.locator(state.contains.selector).first().waitFor({ state: "visible" });
      await expect(page.locator(state.contains.selector).first()).toContainText(
        state.contains.text,
      );

      for (const viewport of VIEWPORTS) {
        await openHomeIn(page, state, viewport);

        expect(
          await bodyFitsViewport(page),
          `${state.label} overflow at ${viewport.label}`,
        ).toBe(true);

        const h1Count = await page.locator("#home-page h1").count();
        expect(h1Count, `${state.label} h1 count`).toBe(1);

        const controls = page.locator(
          "#home-page a:visible, #home-page button:visible, #home-page input:visible",
        );
        const controlCount = await controls.count();
        for (let i = 0; i < controlCount; i++) {
          const control = controls.nth(i);
          const box = await control.boundingBox();
          expect(box).not.toBeNull();
          expect(
            box.height,
            `${state.label} control ${i} height at ${viewport.label}`,
          ).toBeGreaterThanOrEqual(44);
        }

        const primaries = await visiblePrimaries(page);
        if (state.primary) {
          expect(
            primaries,
            `${state.label} primaries at ${viewport.label}`,
          ).toHaveLength(1);
          expect(primaries[0]).toContain(state.primary);
        } else {
          expect(
            primaries,
            `${state.label} primaries at ${viewport.label}`,
          ).toHaveLength(0);
        }

        await assertTabFocusOutlines(page);

        if (captureDir) {
          await page.screenshot({
            path: resolve(captureDir, `${state.label}--${viewport.width}.png`),
            fullPage: true,
          });
        }
      }
    }
  });

  test("the board filters by stage, searches an ID and hides mobile columns", async ({
    page,
  }) => {
    const boardState = STATES.find((state) => state.label === "pathways-board");

    await openHome(page, boardState);

    // The version-total counts and 12-row page come from the seed: 14
    // stations, 8 without pathways, 5 in progress and 1 with no open issues.
    await expect(page.locator("#board-filter-all")).toContainText("14");
    await expect(page.locator("#board-filter-not_started")).toContainText("8");
    await expect(page.locator("#board-filter-in_progress")).toContainText("5");
    await expect(page.locator("#board-filter-clean")).toContainText("1");
    await expect(page.locator("#board-rows tr")).toHaveCount(12);

    // "Not started" leaves only the stations with no pathways, in name order.
    await page.locator("#board-filter-not_started").click();
    await expect(page).toHaveURL(/stage=not_started/);
    await expect(page.locator("#board-rows tr")).toHaveCount(8);
    await expect(page.locator("#board-filter-not_started")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    const pathwayCells = await page
      .locator("#board-rows tr td:nth-child(3)")
      .allTextContents();
    expect(pathwayCells.map((text) => text.trim())).toEqual(Array(8).fill("0"));
    const reportCells = await page
      .locator("#board-rows tr td:nth-child(4)")
      .allTextContents();
    expect(reportCells.map((text) => text.trim())).toEqual(Array(8).fill("Not started"));

    // Searching a station ID from the full board leaves exactly one row.
    await page.locator("#board-filter-all").click();
    await expect(page).not.toHaveURL(/stage=/);
    await page.fill("#board-search", "UNS");
    await expect(page).toHaveURL(/q=UNS/);
    await expect(page.locator("#board-rows tr")).toHaveCount(1);
    await expect(page.locator("#board-rows tr")).toContainText("Union Station");

    // At 390 the board hides the Levels and Last edited columns (AC-34).
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/");
    await waitForRegions(page);
    await page.waitForSelector("#board-rows tr", { state: "visible" });
    await expect(page.locator("#board-table thead th", { hasText: "Station" })).toBeVisible();
    await expect(page.locator("#board-table thead th", { hasText: "Levels" })).toBeHidden();
    await expect(
      page.locator("#board-table thead th", { hasText: "Last edited" }),
    ).toBeHidden();
    await expect(page.locator("#board-table thead th", { hasText: "Pathways" })).toBeVisible();
    await expect(page.locator("#board-table thead th", { hasText: "Report" })).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
  });
});
