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

// ── grouping review ─────────────────────────────────────────────────────────

// `BROWSER_SHAPES` seeds exactly what the review is built for: a saved 13-stop
// pattern in Direction 0, 18 direction-less trips over that same order and 6 over
// its first seven, 2 refused for chronology and 1 for a station-only stop. Rule 4
// therefore answers both groups from the saved pattern, so the review opens with
// both suggestions preselected and nothing to fill in.
//
// The apply is its own test, and it runs last on purpose: the suite shares one
// seeded database, and applying consumes the 24 trips for good. Both viewports
// therefore read the review while it still has something to offer, and one test
// after them is what spends it.
test.describe("grouping review", () => {
  for (const viewport of VIEWPORTS) {
    test(`reviews the left-out trips at ${viewport.width}×${viewport.height}`, async ({
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

      await page.goto(
        `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns?review=group`,
      );
      await waitForLiveView(page);

      const review = page.locator("#grouping-review");
      await expect(review).toBeVisible();
      await expect(review.locator("#grouping-title")).toHaveText(
        "Group 24 trips into patterns",
      );

      // One card per groupable stop order, and both carry the suggestion the
      // saved pattern already answers. The cards are in preview key order, which
      // is not stop-count order, so the ranges are asserted as a set.
      const cards = review.locator("article[id^='grouping-card-']");
      await expect(cards).toHaveCount(2);
      await expect(review.locator("[data-stop-range]")).toHaveCount(2);

      const ranges = await review
        .locator("[data-stop-range]")
        .allInnerTexts()
        .then((texts) => texts.map((text) => text.replace(/\s+/g, " ").trim()));

      expect(ranges.sort()).toEqual([
        "US 101 Stop 1 → US 101 Stop 13",
        "US 101 Stop 1 → US 101 Stop 7",
      ]);
      await expect(
        review.locator("input[id^='grouping-direction-'][value='0'][checked]"),
      ).toHaveCount(2);
      await expect(
        review.locator("[id^='grouping-direction-'][id$='-0-suggested']"),
      ).toHaveCount(2);

      // The trips the review is not offering are named with their reasons, and
      // the running state never promises a change that has not happened.
      await expect(review.locator("#grouping-blocked")).toContainText(
        "Not offered here: 3 trips with other problems (2 with times out of order and 1 that serves a station)",
      );
      await expect(review.locator("#grouping-submit")).toHaveText(
        "Group 24 trips",
      );
      await expect(review.locator("#grouping-cancel")).toHaveText(
        "Keep trips as they are",
      );

      await capture(page, `grouping-review-production-${viewport.label}`);

      // Overriding one card is what the radios are for, and it is kept on screen
      // rather than spent. The second group is asked to go the other way, so the
      // apply would have to build that direction rather than land on the saved
      // pattern.
      await cards.last().locator("input[type='radio'][value='1']").check();
      await expect(
        cards.last().locator("input[type='radio'][value='1']"),
      ).toBeChecked();
      await expect(review).toBeVisible();

      const referenceCaptured = await captureReference(
        page,
        "?state=group-review",
        `grouping-review-reference-${viewport.label}`,
      );

      testInfo.annotations.push({
        type: "reference-captured",
        description: referenceCaptured
          ? `grouping-review-reference-${viewport.label}.png`
          : "prototype absent from this checkout",
      });

      expect(problems).toEqual([]);
    });
  }

  test("applies the review and reports what it wrote", async ({
    page,
  }, testInfo) => {
    testInfo.setTimeout(120_000);

    const problems = collectPageErrors(page);
    await page.setViewportSize({ width: 1440, height: 900 });
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.goto(
      `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns?review=group`,
    );
    await waitForLiveView(page);

    const review = page.locator("#grouping-review");
    await expect(review.locator("#grouping-submit")).toBeEnabled();
    await review.locator("#grouping-submit").click();

    // The list is what the review hands back, and it names what was written in
    // the operator's own words, INV-2's promise included.
    await expect(page).toHaveURL(/\/patterns$/);
    await expect(page.locator("#patterns-grouped")).toContainText(
      "Grouped 24 trips into patterns",
    );
    await expect(page.locator("#patterns-grouped")).toContainText(
      "their times did not change",
    );
    await expect(page.locator("#patterns-left-out")).toContainText(
      "3 trips aren’t in a pattern",
    );

    await capture(page, "grouping-done-production-desktop");

    const referenceCaptured = await captureReference(
      page,
      "?state=group-done",
      "grouping-done-reference-desktop",
    );

    testInfo.annotations.push({
      type: "reference-captured",
      description: referenceCaptured
        ? "grouping-done-reference-desktop.png"
        : "prototype absent from this checkout",
    });

    expect(problems).toEqual([]);
  });
});
