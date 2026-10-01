// Stops Map browser journeys (28-stop-add-edit, step 22 onward; EV-23..EV-38).
//
// Every state this file measures is the committed browser seed
// (`test/support/browser_seed.exs`, user 8) rendered through the real routes:
//
//   stops-map@gtfs-planner.test   # Stops Map Org → "Browser Stops Map Version"
//
// The version is resolved by name through the version panel, so a journey reads
// the stops-map fixture instead of whichever version the organization opens by
// default.
//
// The `@seed` case is the gate for the seed itself: it signs in, opens the
// Stops & stations list and proves the seeded stops are there with the names and
// types the later steps' fixtures name. It depends only on routes that already
// exist, so a failure here is a seed failure and not a Map view failure.
//
// Captures are written only when `STOPS_MAP_CAPTURE_DIR` is set, resolved
// against the assets working directory. They are the visual-loop and QA-tour
// inputs, not the gate's oracle.
import { test, expect } from "@playwright/test";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { bodyFitsViewport } from "./browser_helpers";

const EDITOR = {
  email: "stops-map@gtfs-planner.test",
  password: "StopsMapBrowser1",
};

const VERSION_NAME = "Browser Stops Map Version";

const DESKTOP = { width: 1440, height: 900, label: "desktop" };
const MOBILE = { width: 390, height: 844, label: "mobile" };

const CAPTURE_DIR = process.env.STOPS_MAP_CAPTURE_DIR;

// The spec package lives in the gitignored `.specs/` workspace, which a worktree
// checkout does not carry; STOPS_MAP_SPEC_ROOT points the reference lookups at
// the checkout that holds it. The reference captures are skipped without it.
const SPEC_ROOT = process.env.STOPS_MAP_SPEC_ROOT || "";
const REFERENCE_FILE = SPEC_ROOT
  ? resolve(SPEC_ROOT, "references", "stop-add-edit-prototype.html")
  : "";

// A 1×1 transparent PNG, so the workspace never depends on the Geoapify plan or
// on network access. The stops, the lines and the chrome are the subject of
// these captures; the streets under them are not.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

async function routeBlankTiles(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
}

async function logIn(page) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// A click that lands before the LiveView joins is dropped, so every navigation
// waits for the mounted view first.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return Boolean(
      main &&
      main.classList.contains("phx-connected") &&
      !main.hasAttribute("data-phx-pending") &&
      window.liveSocket?.isConnected(),
    );
  });
}

async function versionIdByName(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function capture(page, testInfo, name, { fullPage = true } = {}) {
  if (!CAPTURE_DIR) return testInfo.outputPath(`${name}.png`);

  mkdirSync(CAPTURE_DIR, { recursive: true });
  const path = resolve(CAPTURE_DIR, `${name}.png`);
  await page.screenshot({ path, fullPage });
  return path;
}

// The capture name carries the viewport, so one case covers both sizes without
// a second label.
function viewportLabel(page) {
  const size = page.viewportSize();
  const viewport = [DESKTOP, MOBILE].find((c) => c.width === size.width);

  if (!viewport) {
    throw new Error(
      `Declare the ${size.width}×${size.height} viewport before capturing it`,
    );
  }

  return viewport.label;
}

// One state at both viewports: 1440×900 for the comparison with the reference,
// and 390×844 for the stacked workspace and the no-horizontal-scroll gate.
async function captureBoth(page, testInfo, name) {
  await expectFits(page);
  await capture(page, testInfo, `shell-${name}-desktop`);

  await page.setViewportSize(MOBILE);
  await expectFits(page);
  await capture(page, testInfo, `shell-${name}-mobile`);

  await page.setViewportSize(DESKTOP);
}

// The same state from the prototype, at the current viewport, for the
// side-by-side inspection. Skipped in a checkout that does not carry the
// package, which is not a failure of this spec.
async function captureReference(page, testInfo, state, name) {
  if (!REFERENCE_FILE || !existsSync(REFERENCE_FILE)) return null;

  await page.setViewportSize(DESKTOP);
  await page.goto(`file://${REFERENCE_FILE}?state=${state}`);
  await page.waitForLoadState("load");

  await capture(page, testInfo, `shell-ref-${name}-${state}-desktop`, {
    fullPage: false,
  });

  await page.setViewportSize(MOBILE);
  await page.goto(`file://${REFERENCE_FILE}?state=${state}`);
  await page.waitForLoadState("load");

  await capture(page, testInfo, `shell-ref-${name}-${state}-mobile`, {
    fullPage: false,
  });

  await page.setViewportSize(DESKTOP);
  return true;
}

async function expectFits(page) {
  const { width } = page.viewportSize();

  expect(
    await bodyFitsViewport(page),
    `the map workspace scrolls horizontally at ${width} px`,
  ).toBe(true);
}

// The Map view of the seeded version, past the read and with the hook's view
// reported. The bounds are the seed's own extent with a margin, so the panel
// lists the stops the map is showing.
async function openMap(page, versionId) {
  await page.goto(`/gtfs/${versionId}/stops/map`);
  await waitForLiveView(page);

  await expect(page.locator("#stops-map-page")).toBeAttached();
  await expect(page.locator("#stops-map-panel")).toBeAttached();
  await expect(page.locator("#stops-map-loading-caption")).toBeAttached();

  return page;
}

// ── seed ──────────────────────────────────────────────────────────────────

// The seed gate. The stop names, the duplicate pair and the station are the
// fixture the Map view steps build on, so they are asserted here as literals
// rather than read back from the surface's own counts.
test("the seeded stops map organization @seed", async ({ page }, testInfo) => {
  await page.setViewportSize(DESKTOP);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSION_NAME);
  await page.goto(`/gtfs/${versionId}/stops`);
  await waitForLiveView(page);

  await expect(page.locator("#stops-page")).toBeAttached();
  await expect(page.locator("h1")).toHaveText("Stops & stations");

  // The stop the journey edits, the possible duplicate beside it, the unserved
  // stop and the station. Literal names, so a renamed fixture fails here.
  for (const name of [
    "US 101 & SE 1st St",
    "SE Bay Blvd & SE Moore Dr",
    "Newport Transit Center",
  ]) {
    await expect(
      page
        .locator("#stops-workbench")
        .getByText(name, { exact: false })
        .first(),
    ).toBeAttached();
  }

  // The list is paginated; the two SE 1st St rows are the duplicate pair, so
  // both IDs are on the first page only if the seed really wrote both.
  await expect(page.getByText("1434", { exact: true }).first()).toBeAttached();
  await expect(page.getByText("1433", { exact: true }).first()).toBeAttached();

  await capture(page, testInfo, "seed-stops-list");
});

// ── shell (step 23) ───────────────────────────────────────────────────────

// The Map view's shell: the header with its List | Map switch, the map stage,
// and the browse panel holding the stops inside the current view. This is the
// state every later capture starts from, so its assertions are the ones a
// regression in the shell would break first.
//
// The hook is not registered yet (step 24 owns it), so the stage is captured in
// its loading state — which is one of the four states this shell must show, and
// is captured as such below.
test("the map view shell @shell", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);

  await expect(page.locator("h1")).toHaveText("Stops & stations");
  await expect(page.locator("#stops-map-view-list")).toHaveText("List");
  await expect(page.locator("#stops-map-view-map")).toHaveText("Map");
  await expect(page.locator("#stops-map-add-stop")).toContainText("Add stop");

  // The stage is the hook's container and nothing else: the hook owns every
  // child, so the page renders it empty.
  await expect(
    page.locator("#stop-map[phx-hook=StopMap][phx-update=ignore]"),
  ).toBeAttached();
  await expect(page.locator("#stops-map-loading-caption")).toHaveText(
    "Loading map…",
  );

  // The panel says what it holds, and its count is the header's count: one
  // sentence, two places, so the page never contradicts itself.
  await expect(page.locator("#stops-map-panel")).toContainText(
    "Stops in this area",
  );
  await expect(page.locator("#stops-map-panel")).toContainText(
    "16 stops and 1 station in Browser Stops Map Version",
  );
  await expect(page.locator("#stops-map-scope-note")).toHaveText(
    "16 stops and 1 station in Browser Stops Map Version",
  );
  await expect(page.locator("#stops-map-row-1434")).toContainText(
    "US 101 & SE 1st St",
  );
  await expect(page.locator("#stops-map-row-ST-NTC")).toContainText("Station");

  await captureBoth(page, testInfo, "map");
  await captureReference(page, testInfo, "map", "map");
});

test("the shell at both viewports @shell", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await page.setViewportSize(DESKTOP);
  await routeBlankTiles(page);

  await logIn(page);
  const versionId = await versionIdByName(page, VERSION_NAME);
  await openMap(page, versionId);

  // 1440 px puts the map and the 408 px panel side by side; 390 px stacks them.
  // Neither may scroll sideways.
  await page.setViewportSize(DESKTOP);
  expect(
    await page.evaluate(() => {
      const stage = document.querySelector("#stops-map-stage");
      const panel = document.querySelector("#stops-map-panel");
      return {
        stage: stage?.getBoundingClientRect(),
        panel: panel?.getBoundingClientRect(),
      };
    }),
  ).toMatchObject({ panel: expect.anything() });

  await captureBoth(page, testInfo, "workspace");
});
