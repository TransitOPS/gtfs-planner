import { test, expect } from "@playwright/test";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync, mkdirSync } from "node:fs";

/**
 * Visual slice of spec 27 (shapes again), step 19.
 *
 * This file owns the shared sign-in, the blank map tile stub and the
 * side-by-side capture helper: every later step of this spec adds its own
 * `test.describe` block here and step 37 adds the journey.
 *
 * Step 19's `left-out list` block opens `BROWSER_SHAPES`, whose seed holds 27
 * trips outside patterns (24 with no direction, 2 with times out of order, 1
 * serving a station), and captures the Patterns tab beside the reference
 * prototype's `?state=patterns` at 1440×900 and 390×844.
 */

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const SHAPES_ROUTE = "BROWSER_SHAPES";

// The reference prototype lives in the gitignored `.specs` workspace, so the
// reference half of a side-by-side is skipped when it is absent. The override
// points at the checkout that carries it when this worktree does not.
const REFERENCE_PATH =
  process.env.SHAPES_REFERENCE_PATH ??
  resolve(
    REPO_ROOT,
    ".specs",
    "27-shapes-again",
    "references",
    "trip-grouping-prototype.html",
  );

const CAPTURE_DIR =
  process.env.SHAPES_CAPTURE_DIR ??
  resolve(REPO_ROOT, ".specs", "27-shapes-again", "evidence", "captures");

const VIEWPORTS = [
  { label: "1440", width: 1440, height: 900 },
  { label: "390", width: 390, height: 844 },
];

// A verified-transparent 1×1 PNG served for every tile request, so captures
// never depend on the network or on Geoapify credits.
const BLANK_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=",
  "base64",
);

// ── shared helpers ──────────────────────────────────────────────────────────

// An already authenticated session is redirected away from the login page, so
// the form is only filled when it is actually rendered.
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

async function stubTiles(page) {
  await page.route("**/map/tiles/**", async (route) => {
    await route.fulfill({ contentType: "image/png", body: BLANK_PNG });
  });
}

// Waits for the LiveView root to report itself connected, so a capture is
// never taken of a server-rendered page that has not hydrated yet.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });

  await page.waitForFunction(
    () => {
      const main = document.querySelector("[data-phx-main]");
      return (
        Boolean(main) &&
        main.classList.contains("phx-connected") &&
        window.liveSocket?.isConnected()
      );
    },
    { timeout: 20000 },
  );
}

function collectPageErrors(page) {
  const problems = [];
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  return problems;
}

async function capture(page, name) {
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(CAPTURE_DIR, `${name}.png`),
    fullPage: true,
    animations: "disabled",
  });
}

// Renders the prototype state beside the production page at the current
// viewport. Returns whether the reference half was captured, so a run without
// the gitignored `.specs` workspace says so instead of implying it compared.
async function captureReference(page, query, name) {
  if (!existsSync(REFERENCE_PATH)) return false;

  await page.goto(`file://${REFERENCE_PATH}${query}`);
  await page.waitForLoadState("networkidle");
  await capture(page, name);
  return true;
}

// ── left-out list ───────────────────────────────────────────────────────────

test.describe("left-out list", () => {
  for (const viewport of VIEWPORTS) {
    test(`lists the trips outside patterns at ${viewport.width}×${viewport.height}`, async ({
      page,
    }, testInfo) => {
      testInfo.setTimeout(120_000);

      const problems = collectPageErrors(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await stubTiles(page);
      await logIn(page);
      const versionId = await getVersionId(page);

      await page.goto(`/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns`);
      await waitForLiveView(page);

      const card = page.locator("#patterns-left-out");
      await expect(card).toBeVisible();
      await expect(card.locator("#patterns-left-out-title")).toHaveText(
        "27 trips aren’t in a pattern",
      );
      await expect(
        card.locator("#patterns-left-out-missing_direction"),
      ).toContainText("24 trips have no direction");
      await expect(
        card.locator("#patterns-left-out-invalid_chronology"),
      ).toContainText("2 trips have times out of order");
      await expect(
        card.locator("#patterns-left-out-unusable_stops"),
      ).toContainText("1 trip serves a station, not a boarding stop");

      // The grouping review is the view's only primary action and points at the
      // review step 20 builds.
      const group = card.locator("#patterns-left-out-group");
      await expect(group).toHaveClass(/btn-primary/);
      await expect(group).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns?review=group`,
      );
      await expect(
        page.locator("#route-patterns-page a.btn-primary"),
      ).toHaveCount(1);

      // The raw derivation codes stay behind the collapsed disclosure.
      await expect(card.locator("#patterns-left-out-codes")).toContainText(
        "missing_direction",
      );
      await expect(card.locator("#patterns-left-out-codes[open]")).toHaveCount(
        0,
      );

      // The pending-trip build states are untouched by this view.
      await expect(page.locator("#patterns-list-container")).toBeVisible();
      await expect(page.locator("#patterns-unlinked")).toHaveCount(0);

      await capture(page, `left-out-list-production-${viewport.label}`);

      const referenceCaptured = await captureReference(
        page,
        "?state=patterns",
        `left-out-list-reference-${viewport.label}`,
      );

      testInfo.annotations.push({
        type: "reference-captured",
        description: referenceCaptured
          ? `left-out-list-reference-${viewport.label}.png`
          : "prototype absent from this checkout",
      });

      expect(problems).toEqual([]);
    });
  }
});
