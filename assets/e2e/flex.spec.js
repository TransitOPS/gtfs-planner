// Flex workspace browser journey.
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0)
// with `BROWSER_E2E=true`. The seeded "Browser Flex Version" is resolved by name
// through the version panel, so every case reads the flex fixture it names
// instead of whichever version is the organization's default.
//
// Step 17 owns this shell (login, version selection, blank tiles and the capture
// helpers); each of the following UI steps adds one case to it and captures the
// desktop and narrow views for comparison with the prototypes in
// `.specs/22-gtfs-flex/references/`.
import { test, expect } from "@playwright/test";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// The Playwright runner starts in `assets/`, so repository-relative inputs are
// resolved from the checkout root the way `playwright.config.js` does.
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Flex Version";

const DESKTOP = { width: 1440, height: 900, label: "desktop" };
const NARROW = { width: 320, height: 800, label: "narrow" };

// A 1×1 transparent PNG. Every tile request is answered locally so the
// workspace never depends on the Geoapify plan or on network access.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

// The spec package lives in the gitignored `.specs/` workspace, which a worktree
// checkout does not carry; FLEX_SPEC_ROOT points the captures and the prototype
// lookups at the checkout that holds it.
const SPEC_ROOT =
  process.env.FLEX_SPEC_ROOT || resolve(REPO_ROOT, ".specs", "22-gtfs-flex");
const CAPTURE_DIR = resolve(SPEC_ROOT, "evidence", "captures");
const REFERENCE_DIR = resolve(SPEC_ROOT, "references");

// ── shared helpers ────────────────────────────────────────────────────────

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
      main && !main.hasAttribute("data-phx-pending") && window.liveSocket?.isConnected(),
    );
  });
}

// Every map tile request is answered with the blank tile, so the journey never
// depends on the Geoapify plan. Register it before the first navigation.
async function routeBlankTiles(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
}

// Resolves any seeded version by its exact name through the version panel, so a
// journey reads the fixture it names instead of whichever version is the default.
async function versionIdByName(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function flexVersionId(page) {
  const versionId = await versionIdByName(page, VERSION_NAME);
  if (!versionId) throw new Error(`${VERSION_NAME} is missing its version ID`);
  return versionId;
}

// Opens the flex workspace and returns the version ID it selected. `path` is
// appended to `/gtfs/<version>/flex`, which is how later cases open a service
// page or the area editor.
async function openFlex(page, path = "") {
  await logIn(page);

  const versionId = await flexVersionId(page);
  await page.goto(`/gtfs/${versionId}/flex${path}`);
  await waitForLiveView(page);

  return versionId;
}

// The capture name carries the viewport the case set, so one case covers the
// desktop and narrow sizes without repeating the label.
function viewportLabel(page) {
  const size = page.viewportSize();
  const viewport = [DESKTOP, NARROW].find(
    (candidate) => candidate.width === size.width && candidate.height === size.height,
  );

  if (!viewport) {
    throw new Error(`Declare the ${size.width}×${size.height} viewport before capturing it`);
  }

  return viewport.label;
}

async function capture(page, name) {
  mkdirSync(CAPTURE_DIR, { recursive: true });

  const path = resolve(CAPTURE_DIR, `${name}-${viewportLabel(page)}.png`);
  await page.screenshot({ path, fullPage: true });

  return path;
}

// Captures a prototype state at the current viewport for the side-by-side
// comparison. The reference lives in the gitignored `.specs/` workspace, so the
// capture is skipped in a checkout that does not carry it.
async function captureReference(page, file, state, name) {
  const reference = resolve(REFERENCE_DIR, file);
  if (!existsSync(reference)) return null;

  await page.goto(`file://${reference}?state=${state}`);
  await page.waitForLoadState("networkidle");

  mkdirSync(CAPTURE_DIR, { recursive: true });

  const path = resolve(CAPTURE_DIR, `ref-${name}.png`);
  await page.screenshot({ path, fullPage: false });

  return path;
}

// ── placeholder ───────────────────────────────────────────────────────────

// The shell holds no cases yet: each visual step below adds its own case and
// captures it through `capture`. The skipped placeholder keeps
// `playwright test e2e/flex.spec.js` green while the page is still the Coming
// soon placeholder.
test.skip("placeholder", async () => {});
