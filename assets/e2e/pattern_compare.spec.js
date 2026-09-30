import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Pattern comparison journey (spec 19, step 11 and later visual steps).
 *
 * Step 11 owns this file's shared helpers (login, version, tile stub, capture).
 * Step 12 adds the `capture: shell` block for the page's own states; later
 * visual steps add their own blocks, and step 23 adds the journey over
 * BROWSER_COMPARE's seeded patterns (FULL, DEV, SHORT, LOOP, MOVED, BACK) and
 * the cross-route BROWSER-CMP-OTHER.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const CAPTURE_DIR = process.env.PATTERN_COMPARE_CAPTURE_DIR;

// A verified-transparent 1×1 PNG served for every tile request, so captures
// never depend on the network or on Geoapify credits. (An earlier literal
// for this stub decoded to a half-green pixel and tinted the whole map.)
const BLANK_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=",
  "base64",
);

// Full-page captures go to PATTERN_COMPARE_CAPTURE_DIR when the operator sets
// it; a normal run writes nothing.
async function capture(page, name) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(CAPTURE_DIR, `${name}.png`),
    fullPage: true,
    animations: "disabled",
  });
}

async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function getVersionId(page, versionName = "Browser E2E Version") {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

function collectPageErrors(page) {
  const problems = [];
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  return problems;
}

async function stubTiles(page) {
  await page.route("**/map/tiles/**", async (route) => {
    await route.fulfill({ contentType: "image/png", body: BLANK_PNG });
  });
}

// ── Shell captures (step 12) ─────────────────────────────────────────────────
//
// The compare page's own states: the title row with the view switch and the
// calendar, the loading skeleton and the phone layout. The skeleton is the
// page's disconnected render, so that capture holds the LiveView socket open
// and reads the static HTML.

const COMPARE_ROUTE = "BROWSER_COMPARE";

function compareUrl(versionId, query = "") {
  return `/gtfs/${versionId}/routes/${COMPARE_ROUTE}/patterns/compare${query}`;
}

test.describe("compare shell (step 12)", () => {
  test("capture: shell", async ({ page, context }) => {
    test.setTimeout(120_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    for (const [name, width, height] of [
      ["shell-1440", 1440, 900],
      ["shell-390", 390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto(compareUrl(versionId));
      await page.waitForSelector("#compare-calendar");
      await capture(page, name);
    }

    for (const [name, width, height] of [
      ["shell-loading-1440", 1440, 900],
      ["shell-loading-390", 390, 844],
    ]) {
      const loading = await context.newPage();

      await loading.route("**/live/websocket**", () => new Promise(() => {}));
      await stubTiles(loading);
      await loading.setViewportSize({ width, height });
      await loading.goto(compareUrl(versionId));
      await loading.waitForSelector("#compare-loading");
      await capture(loading, name);
      await loading.close();
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});

// ── Slot captures (step 13) ─────────────────────────────────────────────────
//
// The two slot cards and the swap in the prototype's states: the ideal pair,
// B on another route, an extension (B adds stops past A), the choose-B empty
// card and the unavailable B card. Every state waits on the part it adds.

test.describe("compare slots (step 13)", () => {
  test("capture: slots", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    const states = [
      ["ideal", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-SHORT", "#slot-a h3"],
      ["cross-route", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-OTHER", "#slot-b h3"],
      ["extension", "?a=BROWSER-CMP-SHORT&b=BROWSER-CMP-FULL", "#slot-b h3"],
      ["choose-b", "?a=BROWSER-CMP-FULL", "#slot-b-empty"],
      ["stale-selection", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-UNKNOWN", "#slot-b-unavailable"],
    ];

    for (const [name, query, selector] of states) {
      for (const [width, height] of [
        [1440, 900],
        [390, 844],
      ]) {
        await page.setViewportSize({ width, height });
        await page.goto(compareUrl(versionId, query));
        await page.waitForSelector(selector);
        await capture(page, `slots-${name}-${width}`);
      }
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});

// ── Relationship captures (step 14) ─────────────────────────────────────────
//
// The relationship callouts and the reverse toggle: the opposite-direction
// pair before and after the reverse patch, an identical pair and a pair with
// no shared stops. The seed has no two distinct patterns with the same stops
// in the same order, so the identical state compares BROWSER-CMP-FULL with
// itself; EV-12's fixture covers two distinct patterns. The no-shared B is on
// another seeded route, as the prototype's own no-shared state is.

test.describe("compare relation (step 14)", () => {
  test("capture: relation", async ({ page }) => {
    test.setTimeout(180_000);

    const problems = collectPageErrors(page);

    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    const states = [
      ["reverse", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-BACK", "#relation-opposite"],
      ["reverse-on", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-BACK&reverse=1", "#relation-reversed"],
      ["identical", "?a=BROWSER-CMP-FULL&b=BROWSER-CMP-FULL", "#relation-identical"],
      ["no-shared", "?a=BROWSER-CMP-FULL&b=BROWSER-P1", "#relation-none"],
    ];

    for (const [name, query, selector] of states) {
      for (const [width, height] of [
        [1440, 900],
        [390, 844],
      ]) {
        await page.setViewportSize({ width, height });
        await page.goto(compareUrl(versionId, query));
        await page.waitForSelector(selector);
        await capture(page, `relation-${name}-${width}`);
      }
    }

    expect(problems, problems.join("\n")).toEqual([]);
  });
});
