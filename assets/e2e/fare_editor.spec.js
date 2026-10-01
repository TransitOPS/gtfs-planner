// Fare editor browser journeys.
//
// Runs against the freshly seeded browser database the repository's Playwright
// configuration already uses (`bin/test-browser`, workers: 1, retries: 0) with
// `BROWSER_E2E=true`. Every seeded version is resolved by its exact name through
// the version panel, so a journey reads the fixture it names instead of
// whichever version is the organization's default.
//
// Step 31 seeds the five versions the editor's journeys draw. This file's `shell`
// block is step 32's: the Fares page shell, its five tabs and the routes between
// the two LiveViews. The following steps add one journey block each, the way
// `fare_zones.spec.js` grew alongside the zone workspace.
import { test, expect } from "@playwright/test";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bodyFitsViewport } from "./browser_helpers.js";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// The five versions `test/support/browser_seed.exs` creates for this package,
// each in the state the editor draws for it.
const VERSIONS = {
  managed: "Browser North Coast Fares Version",
  blank: "Browser Blank Fares Version",
  unmanaged: "Browser Unmanaged V1 Fares Version",
  mismatch: "Browser Fares Mismatch Version",
  gaps: "Browser Fares Gaps Version",
};

// The five tabs and the path each one names, in the order the strip shows them.
const TABS = [
  ["prices", ""],
  ["where", "/where"],
  ["transfers", "/transfers"],
  ["zones", "/zones"],
  ["checks", "/checks"],
];

const DESKTOP = { width: 1440, height: 900, label: "1440" };
const PHONE = { width: 390, height: 844, label: "390" };

// A 1×1 transparent PNG. The zone workspace's map requests tiles, and answering
// them locally keeps a shell journey from depending on the Geoapify plan or on
// network access — the same stub `fare_zones.spec.js` installs.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

// The prototype this shell follows. It lives in the gitignored .specs/ workspace,
// so the reference capture is skipped when the file is not present rather than
// depending on a path that is not checked in.
const REFERENCE_PATH = resolve(
  REPO_ROOT,
  ".specs",
  "29-fares-v1-v2-add-edit",
  "references",
  "fares-editor-prototype.html",
);

const CAPTURE_DIR = process.env.FARE_EDITOR_CAPTURE_DIR;

// ── shared helpers ────────────────────────────────────────────────────────

async function logIn(page) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.waitForSelector("[data-phx-main].phx-connected");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.locator('button:has-text("Log in")').click();
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

// Resolves any seeded version by its exact name through the version panel. The
// panel lists every published version of the organization, so a journey reads
// the fixture it names instead of whichever version is the default.
async function versionIdByName(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function routeBlankTiles(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
}

async function capture(page, testInfo, name) {
  let path = testInfo.outputPath(`${name}.png`);

  if (CAPTURE_DIR) {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    path = resolve(CAPTURE_DIR, `${name}.png`);
  }

  await page.screenshot({ path, fullPage: true });
  return path;
}

// Captures the prototype beside the production page, at the viewport the
// comparison is made at.
async function captureReference(page, testInfo, query, name) {
  if (!existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}${query}`);
  await page.waitForLoadState("networkidle");
  await page.screenshot({
    path: testInfo.outputPath(`${name}.png`),
    fullPage: false,
  });
}

// ── shell ─────────────────────────────────────────────────────────────────

// The Fares page shell. The seeded fare editor fixtures are each found by their
// own name and the page opens on each of them without error, the five tabs name
// their own paths, the Zones tab lands on the zone workspace's own LiveView, the
// retired Fare rules path redirects to Where fares apply, and the header carries
// exactly one primary per tab. Every later journey block builds on this.
test("shell", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const found = {};

  for (const [key, name] of Object.entries(VERSIONS)) {
    found[key] = await versionIdByName(page, name);
  }

  // Five distinct versions: a name resolving to another version's row would
  // silently give a journey the wrong fixture.
  expect(new Set(Object.values(found)).size).toBe(Object.keys(VERSIONS).length);

  const versionId = found.managed;

  for (const key of Object.keys(VERSIONS)) {
    await page.goto(`/gtfs/${found[key]}/settings/fares`);
    await waitForLiveView(page);

    await expect(page.locator("h1")).toHaveText("Fares");
    await expect(page).toHaveURL(
      new RegExp(`/gtfs/${found[key]}/settings/fares$`),
    );

    // The journey reached the version it named: the switcher marks it current.
    await expect(
      page.locator(`#gtfs-version-option-${found[key]}`),
    ).toHaveAttribute("aria-current", "true");
  }

  // The page frame: the back link, the lede and the one primary.
  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);

  await expect(page.locator("#fare-editor-page")).toBeAttached();
  await expect(page.locator("#settings-back")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings`,
  );
  await expect(page.locator("#fare-editor-page")).toContainText(
    "What riders pay and which fare each ride charges.",
  );

  // No Settings nav, and the loading skeleton is gone once the fares resolved.
  await expect(page.locator("#settings-nav")).toHaveCount(0);
  await expect(page.locator("#fare-editor-loading")).toHaveCount(0);

  // One primary per view, and it follows the tab.
  for (const [tab, suffix] of [
    ["prices", ""],
    ["where", "/where"],
    ["transfers", "/transfers"],
    ["checks", "/checks"],
  ]) {
    await page.goto(`/gtfs/${versionId}/settings/fares${suffix}`);
    await waitForLiveView(page);

    const primaries = page.locator("#fare-editor-page header button");
    const expected = tab === "checks" ? 0 : 1;

    await expect(primaries).toHaveCount(expected);
  }

  // Every tab names its own path, and exactly one of them is current.
  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);

  for (const [tab, suffix] of TABS) {
    await expect(page.locator(`#fares-tab-${tab}`)).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/settings/fares${suffix}`,
    );
  }

  await expect(page.locator("#fares-tab-prices")).toHaveAttribute(
    "aria-current",
    "page",
  );

  for (const [tab] of TABS.filter(([name]) => name !== "prices")) {
    await expect(page.locator(`#fares-tab-${tab}`)).not.toHaveAttribute(
      "aria-current",
      "page",
    );
  }

  // The Checks tab carries the version's result, so a setup problem stays
  // visible from the other tabs. The seeded managed version is clean, so the
  // mark is a check beside a zero.
  await expect(
    page.locator("#fares-tab-checks #fares-checks-count"),
  ).toHaveText("0");

  // Zones is the other LiveView: the tab lands on the zone workspace's panel.
  await page.locator("#fares-tab-zones").click();
  await expect(page).toHaveURL(
    new RegExp(`/gtfs/${versionId}/settings/fares/zones$`),
    {
      timeout: 15000,
    },
  );
  await waitForLiveView(page);

  await expect(page.locator("#fare-zones-panel")).toBeAttached();
  await expect(page.locator("#fares-tab-zones")).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.locator("#fare-editor-page")).toHaveCount(0);

  // The retired Fare rules path redirects to Where fares apply rather than
  // rendering a tab of its own or 404ing.
  await page.goto(`/gtfs/${versionId}/settings/fares/rules`);
  await waitForLiveView(page);

  await expect(page).toHaveURL(
    new RegExp(`/gtfs/${versionId}/settings/fares/where$`),
  );
  await expect(page.locator("#fares-tab-where")).toHaveAttribute(
    "aria-current",
    "page",
  );

  // A version with no fares at all still opens the shell.
  await page.goto(`/gtfs/${found.blank}/settings/fares`);
  await waitForLiveView(page);

  await expect(page.locator("h1")).toHaveText("Fares");
  await expect(page.locator("#fares-tab-prices")).toHaveAttribute(
    "aria-current",
    "page",
  );

  // ── captures ────────────────────────────────────────────────────────────
  // The shell at both prepared viewports, beside the prototype states it
  // follows, so branch review compares the same page at the same sizes.
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({
      width: viewport.width,
      height: viewport.height,
    });
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);

    await expect(page.locator("#fare-editor-page")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `shell-${viewport.label}`);
  }

  await captureReference(page, testInfo, "?state=prices", "ref-prices");
  await captureReference(page, testInfo, "?state=loading", "ref-loading");
  await captureReference(page, testInfo, "?state=load-error", "ref-load-error");
});
