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

// ── link offer (step 21) ────────────────────────────────────────────────────
//
// A pattern made by hand is offered the left-out trips whose stop order is
// exactly its own, and the review that precedes a link is captured beside the
// prototype's `?state=link-offer` and `?state=link-review`. Nothing is linked:
// the 24 trips are the grouping review's own fixture, and spending them here
// would leave that review with nothing to apply.
//
// This block runs before `grouping review` because it needs those 24 trips to
// still be left out, and it leaves them that way. The suite shares one seeded
// database with `workers: 1`, so the order is the file's order.
//
// ────────────────────────────────────────────────────────────────────────────

test.describe("link offer", () => {
  test("offers the matching left-out trips and reviews them before linking", async ({
    page,
  }, testInfo) => {
    testInfo.setTimeout(180_000);

    const problems = collectPageErrors(page);
    await page.setViewportSize({ width: 1440, height: 900 });
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    const createUrl = `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/new?task=stops`;

    // The same 13 stops the 18-trip group serves, taken through the editor's own
    // stop picker, so the offer is reached the way an operator reaches it.
    await page.goto(createUrl);
    await waitForLiveView(page);

    for (let index = 1; index <= 13; index += 1) {
      const stopId = `BROWSER_SHAPES_STOP_${index}`;
      await page.fill("#stop_search_stop_id_text_input", stopId);
      await page
        .locator(`#pattern-stop-option-${stopId}`)
        .waitFor({ state: "visible", timeout: 15000 });
      await page.locator(`#pattern-stop-option-${stopId}`).click();
      await expect(page.locator("#pattern-stops-total")).toContainText(
        `${index} ${index === 1 ? "stop" : "stops"}`,
      );
    }

    // The Details tab, not a fresh load: a load would remount the LiveView and
    // the staged stops with it.
    await page.locator("#pattern-task-details").click();
    await expect(page.locator("#pattern-details-form")).toBeVisible();

    await page.fill("#pattern-details-name", "US 101 Coast Highway");
    await page.locator("#pattern-details-submit").click();

    // The create navigates to the new pattern with the link marker, and the
    // offer is what that remount renders.
    await page.waitForURL(/\/patterns\/[^/]+\?task=timings&link=/, {
      timeout: 30000,
    });
    await waitForLiveView(page);

    const productionUrl = page.url();

    const offer = page.locator("#link-offer");
    await expect(offer).toBeVisible();
    await expect(offer).toContainText("18 trips");
    await expect(offer).toContainText("13 stops");
    await expect(page.locator("#link-open")).toHaveText("Link 18 trips");
    await expect(page.locator("#link-dismiss")).toHaveText("Not now");

    await capture(page, "link-offer-production-desktop");

    const offerReference = await captureReference(
      page,
      "?state=link-offer",
      "link-offer-reference-desktop",
    );

    testInfo.annotations.push({
      type: "reference-captured",
      description: offerReference
        ? "link-offer-reference-desktop.png"
        : "prototype absent from this checkout",
    });

    // `captureReference` left the browser on the prototype, which carries its own
    // `#link-open`, so the production page is returned to before anything is
    // pressed on it.
    await page.goto(
      page.url().startsWith("file://") ? productionUrl : page.url(),
    );

    // The review is what the offer opens, and it is where the write is decided.
    await page.locator("#link-open").click();

    const review = page.locator("#link-review");
    await expect(review).toBeVisible();
    await expect(review).toContainText(
      "Link 18 trips to US 101 Coast Highway?",
    );
    await expect(review).toContainText("Trips linked");
    await expect(review).toContainText("New timings");
    await expect(review).toContainText("New problems");
    await expect(review).toContainText("They keep their own times");
    // Focus lands on the answer that writes nothing.
    await expect(page.locator("#link-review-cancel")).toBeFocused();
    await expect(page.locator("#link-review-confirm")).toHaveText(
      "Link 18 trips",
    );

    await capture(page, "link-review-production-desktop");

    // Cancelling writes nothing and closes the review, leaving the offer where
    // it was rather than spending it. This is the last thing pressed on the
    // production page, so the reference capture below can leave the browser on
    // the prototype without anything after it to return from.
    await page.locator("#link-review-cancel").click();
    await expect(page.locator("#link-review")).toBeHidden();
    await expect(page.locator("#link-offer")).toBeVisible();
    await expect(page.locator("#pattern-title")).toHaveText(
      "US 101 Coast Highway",
    );

    const reviewReference = await captureReference(
      page,
      "?state=link-review",
      "link-review-reference-desktop",
    );

    testInfo.annotations.push({
      type: "reference-captured",
      description: reviewReference
        ? "link-review-reference-desktop.png"
        : "prototype absent from this checkout",
    });

    expect(problems).toEqual([]);
  });
});

// ── labels (step 22) ────────────────────────────────────────────────────────
//
// `BROWSER_SHAPES` seeds one supplied label pair: `BROWSER-LABEL-A` carries the
// ID and `BROWSER-LABEL-X` is labelled with it, which is the grouping the
// Patterns list draws. Nothing is removed here: the child's label is what the
// next step's review and export read, and the pair is the seeded scenario's own.
//
// This block runs before `grouping review` because that review's apply changes
// the list it draws. The suite shares one seeded database with `workers: 1`, so
// the file's order is the run's order.
// ────────────────────────────────────────────────────────────────────────────

test.describe("labels", () => {
  for (const viewport of VIEWPORTS) {
    test(`groups the labelled patterns at ${viewport.width}×${viewport.height}`, async ({
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

      const group = page.locator("#pattern-label-BROWSER-LABEL-A");
      await expect(group).toBeVisible();
      await expect(group).toContainText(
        "Exported as route pattern BROWSER-LABEL-A",
      );
      await expect(group).toContainText("2 stop orders, exported as one");
      await expect(
        group.locator("#pattern-label-details-BROWSER-LABEL-A"),
      ).toHaveText("Label details");

      // The owner and the child are the two rows under that one heading, and the
      // child says what the label does with its own name.
      await expect(
        page.locator(
          "tr[data-label='BROWSER-LABEL-A'][data-label-role='owner']",
        ),
      ).toHaveCount(1);
      await expect(
        page.locator(
          "tr[data-label='BROWSER-LABEL-A'][data-label-role='child']",
        ),
      ).toHaveCount(1);
      await expect(
        page.locator("#pattern-label-note-BROWSER-LABEL-X"),
      ).toContainText("its own name isn’t exported");

      // The drawer reads the label; it takes nothing away in this block.
      await capture(page, `label-group-production-${viewport.label}`);
      await page.locator("#pattern-label-details-BROWSER-LABEL-A").click();
      const drawer = page.locator("#label-drawer");
      await expect(drawer).toBeVisible();
      await expect(page.locator("#label-drawer-summary")).toContainText(
        "Exported as one route pattern for 2 stop orders",
      );
      await expect(page.locator("#label-owner-name")).toHaveText(
        "Coast Limited",
      );
      await expect(page.locator("#label-owner-details")).toContainText(
        "BROWSER-LABEL-A",
      );
      await expect(page.locator("#label-edit-owner")).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/BROWSER-LABEL-A?task=details`,
      );
      // A label ID is never edited: there is nothing in the drawer to type into.
      await expect(drawer.locator("input")).toHaveCount(0);
      await expect(page.locator("#label-remove-BROWSER-LABEL-X")).toBeVisible();
      await expect(page.locator("#label-remove-BROWSER-LABEL-A")).toHaveCount(
        0,
      );

      await capture(page, `label-drawer-production-${viewport.label}`);

      const referenceCaptured = await captureReference(
        page,
        "?state=label-drawer",
        `label-drawer-reference-${viewport.label}`,
      );

      testInfo.annotations.push({
        type: "reference-captured",
        description: referenceCaptured
          ? `label-drawer-reference-${viewport.label}.png`
          : "prototype absent from this checkout",
      });

      expect(problems).toEqual([]);
    });
  }

  test("captures the prototype's grouped list beside the production one", async ({
    page,
  }, testInfo) => {
    testInfo.setTimeout(120_000);

    await page.setViewportSize({ width: 1440, height: 900 });
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.goto(`/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns`);
    await waitForLiveView(page);
    await expect(page.locator("#pattern-label-BROWSER-LABEL-A")).toBeVisible();

    const referenceCaptured = await captureReference(
      page,
      "?state=labels",
      "label-group-reference-1440",
    );

    testInfo.annotations.push({
      type: "reference-captured",
      description: referenceCaptured
        ? "label-group-reference-1440.png"
        : "prototype absent from this checkout",
    });
  });
});

// ── map lines (step 23) ────────────────────────────────────────────────────
//
// Every imported line the Details map draws carries one next step. On
// `BROWSER_SHAPES` the only imported line is the one the 18 direction-less
// trips share, so the production half captures that line's `Group 18 trips`
// action. The chooser and the no-patterns route are the prototype's other two
// states; the seed carries neither, so they are captured as reference halves
// only and the test says so instead of implying it compared them.
//
// This block runs before `grouping review` because that review's apply groups
// the 18 trips this line counts. The suite shares one seeded database with
// `workers: 1`, so the file's order is the run's order.
// ────────────────────────────────────────────────────────────────────────────

test.describe("map lines", () => {
  test("offers the grouping action on the imported line", async ({
    page,
  }, testInfo) => {
    testInfo.setTimeout(120_000);

    const problems = collectPageErrors(page);
    await page.setViewportSize({ width: 1440, height: 900 });
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.goto(`/gtfs/${versionId}/routes/${SHAPES_ROUTE}`);
    await waitForLiveView(page);

    // The line keeps its highlight control and gains the one next step.
    await expect(
      page.locator(
        "#route-map-variant-list [data-map-highlight='BROWSER_SHAPE_N']",
      ),
    ).toBeVisible();

    const group = page.locator("#route-map-line-BROWSER_SHAPE_N-group");
    await expect(group).toHaveText("Group 18 trips");
    await expect(group).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns?review=group`,
    );

    // Neither of the other two actions belongs on this line.
    await expect(
      page.locator("#route-map-line-BROWSER_SHAPE_N-edit"),
    ).toHaveCount(0);
    await expect(
      page.locator("#route-map-line-BROWSER_SHAPE_N-choose"),
    ).toHaveCount(0);

    // The route has patterns, so the panel is not the empty card.
    await expect(page.locator("#route-map-pattern-list")).toBeVisible();
    await expect(page.locator("#route-map-first-pattern")).toHaveCount(0);

    await capture(page, "map-lines-production-1440");

    const states = [
      ["?state=map", "map-lines-reference-map-1440"],
      ["?state=map-choose", "map-lines-reference-map-choose-1440"],
      ["?state=map-nopatterns", "map-lines-reference-map-nopatterns-1440"],
    ];
    const captured = [];

    for (const [query, name] of states) {
      if (await captureReference(page, query, name)) captured.push(name);
    }

    testInfo.annotations.push({
      type: "reference-captured",
      description:
        captured.length === states.length
          ? captured.join(", ")
          : "prototype absent from this checkout",
    });

    expect(problems).toEqual([]);
  });
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

// ── import result ───────────────────────────────────────────────────────────

// A finished import reports the trips it could not group, grouped by route, in
// the same words the route's Patterns tab uses. `shapes_again_nodirection.zip`
// is a feed whose `trips.txt` has no `direction_id` column at all, so every trip
// is left out for the same reason and the block leads with the one reason that
// can be fixed from here: the grouping review.
//
// The fixture's literal GTFS rows live beside it in
// `assets/e2e/fixtures/shapes_again_nodirection/`, so the counts the block
// reports can be read without running anything.
const NO_DIRECTION_FIXTURE = resolve(
  REPO_ROOT,
  "assets",
  "e2e",
  "fixtures",
  "shapes_again_nodirection.zip",
);

// The upload channel joins asynchronously, so a file chosen before it is ready is
// dropped. Retry the way `import_export.spec.js` does until the entry is listed.
async function setImportFile(page, file) {
  const input = page.locator("#gtfs-import-upload-input input");
  const entries = page.locator("#gtfs-import-upload-entries");
  let lastError;

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await waitForLiveView(page);
    await expect(input).toHaveAttribute("data-phx-upload-ref", /.+/);
    await input.setInputFiles(file);

    try {
      await expect(entries).toContainText("shapes_again_nodirection.zip", {
        timeout: 5_000,
      });
      return;
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError;
}

test.describe("import result", () => {
  test("reports the trips left outside patterns, grouped by route", async ({
    page,
  }, testInfo) => {
    testInfo.setTimeout(180_000);

    const problems = collectPageErrors(page);
    await page.setViewportSize({ width: 1440, height: 900 });
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.goto(`/gtfs/${versionId}/import`);
    await waitForLiveView(page);

    await page
      .locator("#gtfs-import-version-name")
      .fill("Shapes Again No Direction");
    await setImportFile(page, NO_DIRECTION_FIXTURE);

    await expect(page.locator("#gtfs-import-submit")).toBeEnabled();
    await page.locator("#gtfs-import-submit").click();

    // The result is the success card, and the new block sits inside it, below
    // the counts and the agency findings.
    await expect(page.locator("#gtfs-import-result")).toBeVisible();

    const block = page.locator("#import-left-out");
    await expect(block).toBeVisible();

    // Six trips on route 1 and two on route 6, all for the same reason.
    await expect(page.locator("#import-patterns-title")).toHaveText(
      "8 trips aren’t in a pattern",
    );
    await expect(block).toContainText("Coast Highway");
    await expect(block).toContainText("Depoe Bay Shuttle");
    await expect(
      page.locator("#import-left-out-1-missing_direction"),
    ).toContainText("6 trips have no direction");
    await expect(
      page.locator("#import-left-out-6-missing_direction"),
    ).toContainText("2 trips have no direction");

    // The grouping review is the one fix offered here, and each route's link
    // opens the version this import published, not the one the page was on.
    const publishedId = await page
      .locator("#gtfs-import-view-version")
      .getAttribute("href")
      .then((href) => href.split("/")[2]);

    const group = page.locator("#import-left-out-group-1");
    await expect(group).toHaveText("Group 6 trips");
    await expect(group).toHaveAttribute(
      "href",
      `/gtfs/${publishedId}/routes/1/patterns?review=group`,
    );
    await expect(page.locator("#import-left-out-group-6")).toHaveText(
      "Group 2 trips",
    );

    // The raw codes stay in the disclosure under the table.
    await expect(page.locator("#import-left-out-codes")).toContainText(
      "missing_direction",
    );

    await capture(page, "import-result-production-1440");

    // The block's layout and its grouping by route are what this capture is
    // compared against, so the reference half is the prototype's attention
    // state, which draws the same table. The totals are the fixture's own.
    const referenceCaptured = await captureReference(
      page,
      "?state=import-attention",
      "import-result-reference-1440",
    );

    testInfo.annotations.push({
      type: "reference-captured",
      description: referenceCaptured
        ? "import-result-reference-1440.png"
        : "prototype absent from this checkout",
    });

    expect(problems).toEqual([]);
  });
});

// ── file import (step 29) ───────────────────────────────────────────────────
//
// The Map line tab's "Import a path file" panel, reached through the real
// upload: a two-line KML whose pieces do not meet offers the pick, and a
// latitude-first GeoJSON gets the swapped message. The files are buffers
// written by this block, so nothing on disk is read and the seeded pattern's
// saved line is untouched — this panel only reads a file, and choosing a line
// is step 30's preview, not a save.
//
// The reference half is the path prototype, which is a different file from the
// grouping prototype the earlier blocks capture, so it gets its own path.
// ────────────────────────────────────────────────────────────────────────────

const PATTERN_REFERENCE_PATH =
  process.env.SHAPES_PATTERN_REFERENCE_PATH ??
  resolve(
    REPO_ROOT,
    ".specs",
    "27-shapes-again",
    "references",
    "pattern-path-prototype.html",
  );

// Two legs of one route: the first ends 2 km south of where the second begins,
// so the file offers two lines and the pick is reached.
const TWO_LINE_KML = `<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>Walking Route</name>
      <LineString><coordinates>-124.0490,44.6485 -124.0480,44.6600</coordinates></LineString>
    </Placemark>
    <Placemark>
      <name>Walk to the bus</name>
      <LineString><coordinates>-124.0480,44.6900 -124.0470,44.7000</coordinates></LineString>
    </Placemark>
  </Document>
</kml>
`;

// Oregon written latitude-first: the second slot carries a latitude no
// longitude could hold, which is the reversal the parser reports.
const SWAPPED_GEOJSON = JSON.stringify({
  type: "FeatureCollection",
  features: [
    {
      type: "Feature",
      properties: { name: "Coast Highway" },
      geometry: {
        type: "LineString",
        coordinates: [
          [44.61, -124.05],
          [44.63, -122.33],
        ],
      },
    },
  ],
});

// One line along the seeded corridor's meridian (test/support/browser_seed.exs),
// written longitude-first, so the single-line path skips the picker and goes
// straight to the fit preview.
const SINGLE_LINE_GEOJSON = JSON.stringify({
  type: "FeatureCollection",
  features: [
    {
      type: "Feature",
      properties: { name: "Coast Highway" },
      geometry: {
        type: "LineString",
        coordinates: [
          [-124.049, 44.64],
          [-124.049, 44.7],
          [-124.049, 44.76],
          [-124.049, 44.82],
          [-124.049, 44.88],
          [-124.049, 44.93],
        ],
      },
    },
  ],
});

// The seeded corridor's own meridian run from its last stop to its first, so
// every stop sits on the line and the line runs the other way from the
// pattern: the state the review blocks on.
const REVERSED_LINE_GEOJSON = JSON.stringify({
  type: "FeatureCollection",
  features: [
    {
      type: "Feature",
      properties: { name: "Coast Highway, drawn north to south" },
      geometry: {
        type: "LineString",
        coordinates: [
          [-124.049, 44.936],
          [-124.049, 44.911],
          [-124.049, 44.886],
          [-124.049, 44.861],
          [-124.049, 44.836],
          [-124.049, 44.811],
          [-124.049, 44.786],
          [-124.049, 44.761],
          [-124.049, 44.736],
          [-124.049, 44.711],
          [-124.049, 44.686],
          [-124.049, 44.661],
          [-124.049, 44.636],
        ],
      },
    },
  ],
});

// The same corridor the pattern itself runs, first stop to last, so every
// stop is on the line and in order.
const GOOD_LINE_GEOJSON = JSON.stringify({
  type: "FeatureCollection",
  features: [
    {
      type: "Feature",
      properties: { name: "Coast Highway, first stop to last" },
      geometry: {
        type: "LineString",
        coordinates: [
          [-124.049, 44.636],
          [-124.049, 44.661],
          [-124.049, 44.686],
          [-124.049, 44.711],
          [-124.049, 44.736],
          [-124.049, 44.761],
          [-124.049, 44.786],
          [-124.049, 44.811],
          [-124.049, 44.836],
          [-124.049, 44.861],
          [-124.049, 44.886],
          [-124.049, 44.911],
          [-124.049, 44.936],
        ],
      },
    },
  ],
});

test.describe("file import", () => {
  for (const viewport of VIEWPORTS) {
    test(`reads a path file and names its problems at ${viewport.width}×${viewport.height}`, async ({
      page,
    }, testInfo) => {
      testInfo.setTimeout(180_000);

      const problems = collectPageErrors(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await stubTiles(page);
      await logIn(page);
      const versionId = await getVersionId(page);

      await page.goto(
        `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/BROWSER-SHAPES-A?task=alignment`,
      );
      await waitForLiveView(page);

      await page.locator("#alignment-open-file-import").click();

      const panel = page.locator("#file-import-panel");
      await expect(panel).toBeVisible();
      await expect(page.locator("#file-import-title")).toHaveText(
        "Import a path file",
      );
      await expect(page.locator("#file-import-panel")).toContainText(
        "Choose a file",
      );
      await expect(page.locator("#file-import-panel")).toContainText(
        "Pick the line",
      );
      await expect(page.locator("#file-import-panel")).toContainText(
        "Check the fit",
      );
      await expect(page.locator("#file-import-read")).toHaveCount(0);

      await capture(page, `file-import-choose-production-${viewport.label}`);

      const chooseReference = existsSync(PATTERN_REFERENCE_PATH);
      if (chooseReference) {
        await page.goto(`file://${PATTERN_REFERENCE_PATH}?state=import-choose`);
        await page.waitForLoadState("networkidle");
        await capture(page, `file-import-choose-reference-${viewport.label}`);
      }

      testInfo.annotations.push({
        type: "reference-captured",
        description: chooseReference
          ? `file-import-choose-reference-${viewport.label}.png`
          : "path prototype absent from this checkout",
      });

      // Back to the production panel, which the reference capture left behind.
      await page.goto(
        `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/BROWSER-SHAPES-A?task=alignment`,
      );
      await waitForLiveView(page);
      await page.locator("#alignment-open-file-import").click();

      const input = page.locator(
        "#map-line-file-upload-input input[type=file]",
      );
      await input.setInputFiles({
        name: "my-maps.kml",
        mimeType: "application/vnd.google-earth.kml+xml",
        buffer: Buffer.from(TWO_LINE_KML, "utf8"),
      });

      // The file is read when the editor asks for it, so the button appears
      // once the upload has finished arriving.
      await page.locator("#file-import-read").click();

      await expect(page.locator("#file-line-0")).toBeVisible();
      await expect(page.locator("#file-line-1")).toBeVisible();
      await expect(page.locator("label[for='file-line-0']")).toContainText(
        "Walking Route",
      );
      // The second leg's own piece carries no name, so the panel names it by
      // its position rather than showing a blank.
      await expect(page.locator("label[for='file-line-1']")).toContainText(
        "Line 2",
      );
      await expect(page.locator("#file-import-file-row")).toContainText(
        "my-maps.kml",
      );
      await expect(page.locator("#file-import-restart")).toHaveText(
        "Choose another file",
      );

      await capture(page, `file-import-pick-production-${viewport.label}`);

      // The second file replaces the first through the panel's own restart, so
      // the error state is reached the way an editor reaches it.
      await page.locator("#file-import-restart").click();
      await expect(page.locator("#file-line-form")).toHaveCount(0);
      await expect(page.locator("#file-import-read")).toHaveCount(0);

      await input.setInputFiles({
        name: "swapped.geojson",
        mimeType: "application/geo+json",
        buffer: Buffer.from(SWAPPED_GEOJSON, "utf8"),
      });
      await page.locator("#file-import-read").click();

      await expect(page.locator("#file-error-swapped")).toBeVisible();
      await expect(page.locator("#file-error-swapped")).toContainText(
        "the wrong way round",
      );
      await expect(page.locator("#file-line-form")).toHaveCount(0);
      await expect(page.locator("#file-import-restart")).toHaveCount(0);
      // The chooser is the way out of a file problem, so it says so.
      await expect(page.locator("#map-line-file-upload")).toContainText(
        "Choose another file",
      );

      await capture(
        page,
        `file-import-err-swapped-production-${viewport.label}`,
      );

      if (existsSync(PATTERN_REFERENCE_PATH)) {
        await page.goto(`file://${PATTERN_REFERENCE_PATH}?state=err-swapped`);
        await page.waitForLoadState("networkidle");
        await capture(
          page,
          `file-import-err-swapped-reference-${viewport.label}`,
        );
      }

      // Step 30: one line in the file skips the picker, so the map previews
      // it with direction arrows. The line runs the seeded corridor's own
      // meridian, so it lands inside the view the editor already has.
      await page.goto(
        `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/BROWSER-SHAPES-A?task=alignment`,
      );
      await waitForLiveView(page);
      await page.locator("#alignment-open-file-import").click();

      await input.setInputFiles({
        name: "coast-highway.geojson",
        mimeType: "application/geo+json",
        buffer: Buffer.from(SINGLE_LINE_GEOJSON, "utf8"),
      });
      await page.locator("#file-import-read").click();

      await expect(page.locator("#file-line-form")).toHaveCount(0);
      const arrows = page.locator("#alignment-map-root .pa-file-arrow");
      await expect(arrows.first()).toBeVisible();
      expect(await arrows.count()).toBeGreaterThan(0);

      await capture(page, `file-import-review-production-${viewport.label}`);

      if (existsSync(PATTERN_REFERENCE_PATH)) {
        await page.goto(`file://${PATTERN_REFERENCE_PATH}?state=import-review`);
        await page.waitForLoadState("networkidle");
        await capture(page, `file-import-review-reference-${viewport.label}`);
      }

      // Step 31: the fit review the hook's report renders. The partial line
      // above stops short of the pattern's last stop, which is a finding, not
      // a block: the draft stays enabled.
      await page.goto(
        `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/BROWSER-SHAPES-A?task=alignment`,
      );
      await waitForLiveView(page);
      await page.locator("#alignment-open-file-import").click();
      await page
        .locator("#map-line-file-upload-input input[type=file]")
        .setInputFiles({
          name: "coast-highway.geojson",
          mimeType: "application/geo+json",
          buffer: Buffer.from(SINGLE_LINE_GEOJSON, "utf8"),
        });
      await page.locator("#file-import-read").click();

      await expect(page.locator("#file-fit-headline")).toContainText(
        "stops within 330 ft",
      );
      await expect(page.locator("#fit-end")).toContainText("File Stop 13");
      await expect(page.locator("#fit-create-draft")).toBeEnabled();
      await expect(page.locator("#file-import-restart")).toHaveText(
        "Choose another file",
      );

      // A line that runs the other way is blocked, and the reason is on
      // screen beside the button that is disabled because of it.
      await page.locator("#file-import-restart").click();
      await page
        .locator("#map-line-file-upload-input input[type=file]")
        .setInputFiles({
          name: "coast-highway-reversed.geojson",
          mimeType: "application/geo+json",
          buffer: Buffer.from(REVERSED_LINE_GEOJSON, "utf8"),
        });
      await page.locator("#file-import-read").click();

      await expect(page.locator("#fit-direction-reversed")).toContainText(
        "This line runs the other way",
      );
      await expect(page.locator("#fit-reverse")).toHaveText("Reverse line");
      await expect(page.locator("#fit-create-draft")).toBeDisabled();
      await expect(page.locator("#fit-footer-note")).toContainText(
        "Reverse the line to continue",
      );

      await capture(page, `file-fit-review-production-${viewport.label}`);

      if (existsSync(PATTERN_REFERENCE_PATH)) {
        await page.goto(`file://${PATTERN_REFERENCE_PATH}?state=import-review`);
        await page.waitForLoadState("networkidle");
        await capture(page, `file-fit-review-reference-${viewport.label}`);
      }

      // Reversing is the hook's geometry: the review clears the block as soon
      // as the fresh report comes back.
      await page.goto(
        `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/BROWSER-SHAPES-A?task=alignment`,
      );
      await waitForLiveView(page);
      await page.locator("#alignment-open-file-import").click();
      await page
        .locator("#map-line-file-upload-input input[type=file]")
        .setInputFiles({
          name: "coast-highway-reversed.geojson",
          mimeType: "application/geo+json",
          buffer: Buffer.from(REVERSED_LINE_GEOJSON, "utf8"),
        });
      await page.locator("#file-import-read").click();
      await page.locator("#fit-reverse").click();

      await expect(page.locator("#fit-direction-reversed")).toHaveCount(0);
      await expect(page.locator("#fit-create-draft")).toBeEnabled();

      await capture(page, `file-fit-reversed-production-${viewport.label}`);

      if (existsSync(PATTERN_REFERENCE_PATH)) {
        await page.goto(
          `file://${PATTERN_REFERENCE_PATH}?state=import-review-reversed`,
        );
        await page.waitForLoadState("networkidle");
        await capture(page, `file-fit-reversed-reference-${viewport.label}`);
      }

      // A line drawn first stop to last puts every stop on it, in order.
      await page.goto(
        `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/BROWSER-SHAPES-A?task=alignment`,
      );
      await waitForLiveView(page);
      await page.locator("#alignment-open-file-import").click();
      await page
        .locator("#map-line-file-upload-input input[type=file]")
        .setInputFiles({
          name: "coast-highway-good.geojson",
          mimeType: "application/geo+json",
          buffer: Buffer.from(GOOD_LINE_GEOJSON, "utf8"),
        });
      await page.locator("#file-import-read").click();

      await expect(page.locator("#file-fit-headline")).toContainText(
        "13 of 13",
      );
      await expect(page.locator("#fit-ok")).toContainText(
        "Every stop is on the line",
      );
      await expect(page.locator("#fit-far")).toHaveCount(0);
      await expect(page.locator("#fit-create-draft")).toBeEnabled();

      await capture(page, `file-fit-good-production-${viewport.label}`);

      if (existsSync(PATTERN_REFERENCE_PATH)) {
        await page.goto(`file://${PATTERN_REFERENCE_PATH}?state=import-good`);
        await page.waitForLoadState("networkidle");
        await capture(page, `file-fit-good-reference-${viewport.label}`);
      }

      expect(problems).toEqual([]);
    });
  }
});

// ── Imported line card (step 32) ─────────────────────────────────────────────
//
// A pattern still on an imported shape reviews that line in the panel, not
// behind a dialog: the card names the shape, the hook's fit of it is the
// review, and the draft action splits it into editable sections. The seed
// carries BROWSER_IMPORTED for this, whose shape bows east of the corridor
// so the fit names the stop it runs wide of.

const IMPORTED_ROUTE = "BROWSER_IMPORTED";
const IMPORTED_PATTERN = "BROWSER-IMPORTED-A";

test.describe("imported shape", () => {
  test("reviews the imported shape in the panel and drafts it", async ({
    page,
  }, testInfo) => {
    testInfo.setTimeout(180_000);

    const problems = collectPageErrors(page);
    await page.setViewportSize({ width: 1440, height: 900 });
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.goto(
      `/gtfs/${versionId}/routes/${IMPORTED_ROUTE}/patterns/${IMPORTED_PATTERN}?task=alignment`,
    );
    await waitForLiveView(page);

    await expect(page.locator("#alignment-review-import")).toHaveText(
      "Review imported path",
    );

    await page.locator("#alignment-review-import").click();

    const card = page.locator("#imported-line-card");
    await expect(card).toBeVisible();
    // The dialog is gone: the review is in the panel.
    await expect(page.locator("#alignment-import-dialog")).toHaveCount(0);
    await expect(card).toContainText("Imported shape BROWSER_IMPORTED_SHAPE");
    await expect(card).toContainText("5 points");
    await expect(card).toContainText("used by the 3 trips on this pattern");
    await expect(card).toContainText("5 visits");
    await expect(card).toContainText("Nothing changes until you save");

    // The hook measured the shape it was given, so the review is its answer.
    await expect(page.locator("#file-fit-headline")).toContainText("4 of 5");
    await expect(page.locator("#fit-far")).toContainText("Import Stop 3");
    await expect(page.locator("#fit-ok")).toHaveCount(0);
    await expect(page.locator("#imported-line-draft")).toBeEnabled();

    await capture(page, "imported-line-card-production-1440");

    if (existsSync(PATTERN_REFERENCE_PATH)) {
      await page.goto(`file://${PATTERN_REFERENCE_PATH}?state=imported-shape`);
      await page.waitForLoadState("networkidle");
      await capture(page, "imported-line-card-reference-1440");
    }

    // The draft splits the shape into editable sections: the card closes, the
    // sections carry unsaved drafts, and nothing is written until Save.
    await page.goto(
      `/gtfs/${versionId}/routes/${IMPORTED_ROUTE}/patterns/${IMPORTED_PATTERN}?task=alignment`,
    );
    await waitForLiveView(page);
    await page.locator("#alignment-review-import").click();
    await page.locator("#imported-line-draft").click();

    await expect(page.locator("#imported-line-card")).toHaveCount(0);
    await expect(page.locator("#alignment-sections")).toContainText("Unsaved");
    await expect(page.locator("#alignment-save")).toBeEnabled();

    await capture(page, "imported-line-draft-production-1440");

    if (existsSync(PATTERN_REFERENCE_PATH)) {
      await page.goto(`file://${PATTERN_REFERENCE_PATH}?state=imported-draft`);
      await page.waitForLoadState("networkidle");
      await capture(page, "imported-line-draft-reference-1440");
    }

    expect(problems).toEqual([]);
  });
});

// Step 35: the two map-line download menus. The prototype's `?state=export-menu`
// (the Map line tab's Import or export disclosure), `?state=export-partial` (a
// pattern with gaps) and `?state=export-route` (the Patterns list's Download map
// lines) at 1440×900. Each menu item is a real `<a download>`, so the block also
// asserts the file the browser actually saves.
test.describe("downloads", () => {
  test("offers this pattern's map line and the route's from the two menus", async ({
    page,
  }, testInfo) => {
    testInfo.setTimeout(180_000);

    const problems = collectPageErrors(page);
    await page.setViewportSize({ width: 1440, height: 900 });
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    // `export-menu`: the Map line tab's disclosure, on a pattern whose every
    // section has a saved path, so the note promises one line and its stops.
    await page.goto(
      `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/BROWSER-SHAPES-A?task=alignment`,
    );
    await waitForLiveView(page);

    await expect(page.locator("#map-line-files-toggle")).toHaveText(
      "Import or export",
    );

    await page.locator("#map-line-files-toggle").click();

    const menu = page.locator("#map-line-files");
    await expect(menu).toBeVisible();
    await expect(page.locator("#map-line-download-kml")).toBeVisible();
    await expect(page.locator("#map-line-download-geojson")).toBeVisible();
    await expect(page.locator("#map-line-download-note")).toContainText(
      "The file has the saved map line",
    );

    await expect(page.locator("#map-line-download-kml")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/map-lines?format=kml&pattern=BROWSER-SHAPES-A`,
    );

    await capture(page, "downloads-export-menu-production-1440");

    // The KML link is a real download of this pattern's line and its stops.
    const [kml] = await Promise.all([
      page.waitForEvent("download"),
      page.locator("#map-line-download-kml").click(),
    ]);

    expect(kml.suggestedFilename()).toBe("BROWSER_SHAPES-BROWSER-SHAPES-A.kml");

    const [geojson] = await Promise.all([
      page.waitForEvent("download"),
      page.locator("#map-line-download-geojson").click(),
    ]);

    expect(geojson.suggestedFilename()).toBe(
      "BROWSER_SHAPES-BROWSER-SHAPES-A.geojson",
    );

    // `export-partial`: the same menu on a pattern whose only line is the
    // imported shape, so the note names the shape the file will carry.
    await page.goto(
      `/gtfs/${versionId}/routes/${IMPORTED_ROUTE}/patterns/${IMPORTED_PATTERN}?task=alignment`,
    );
    await waitForLiveView(page);
    await page.locator("#map-line-files-toggle").click();

    await expect(page.locator("#map-line-download-note")).toContainText(
      "The file has the imported line (shape BROWSER_IMPORTED_SHAPE)",
    );

    await capture(page, "downloads-export-partial-production-1440");

    if (existsSync(PATTERN_REFERENCE_PATH)) {
      await page.goto(`file://${PATTERN_REFERENCE_PATH}?state=export-partial`);
      await page.waitForLoadState("networkidle");
      await capture(page, "downloads-export-partial-reference-1440");
    }

    // `export-route`: the Patterns list's toolbar menu, one file for the route.
    await page.goto(`/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns`);
    await waitForLiveView(page);

    await page.locator("#patterns-download-map-lines-toggle").click();

    await expect(
      page.locator("#patterns-download-map-lines-kml"),
    ).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/map-lines?format=kml&pattern=all`,
    );

    await expect(
      page.locator("#patterns-download-map-lines-geojson"),
    ).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/map-lines?format=geojson&pattern=all`,
    );

    await capture(page, "downloads-export-route-production-1440");

    const [routeKml] = await Promise.all([
      page.waitForEvent("download"),
      page.locator("#patterns-download-map-lines-kml").click(),
    ]);

    expect(routeKml.suggestedFilename()).toBe("BROWSER_SHAPES-all.kml");

    if (existsSync(PATTERN_REFERENCE_PATH)) {
      await page.goto(`file://${PATTERN_REFERENCE_PATH}?state=export-route`);
      await page.waitForLoadState("networkidle");
      await capture(page, "downloads-export-route-reference-1440");
    }

    testInfo.annotations.push({
      type: "reference-captured",
      description: existsSync(PATTERN_REFERENCE_PATH)
        ? "downloads-export-partial-reference-1440.png, downloads-export-route-reference-1440.png"
        : "path prototype absent from this checkout",
    });

    expect(problems).toEqual([]);
  });
});

// ── map line copy ───────────────────────────────────────────────────────────

// Step 36: the workspace says "Map line" where it used to say "Alignment",
// while `task=alignment`, the element ids and the events keep their names.
// The reference half is the path prototype's Map line tab at 1440×900.
test.describe("map line copy", () => {
  test("names the alignment task Map line and still routes on task=alignment", async ({
    page,
  }, testInfo) => {
    testInfo.setTimeout(180_000);

    const problems = collectPageErrors(page);
    await page.setViewportSize({ width: 1440, height: 900 });
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.goto(
      `/gtfs/${versionId}/routes/${SHAPES_ROUTE}/patterns/BROWSER-SHAPES-A?task=alignment`,
    );
    await waitForLiveView(page);

    // The tab keeps its id and phx-value-task; only its text changed.
    const tab = page.locator("#pattern-task-alignment");

    await expect(tab).toHaveText("Map line");
    await expect(tab).toHaveAttribute("phx-value-task", "alignment");
    await expect(tab).toHaveAttribute("aria-current", "page");
    await expect(page.locator("#alignment-task")).toBeVisible();
    await expect(page.locator("#pattern-save-bar #alignment-save")).toContainText(
      "Save map line",
    );

    await capture(page, "map-line-copy-tab-production-1440");

    // No user-visible "Alignment" survives anywhere on the task.
    await expect(page.locator("body")).not.toContainText("Alignment");

    // The tab still switches tasks and the Map line task still responds to its
    // own ids.
    await tab.click();
    await expect(page.locator("#alignment-task")).toBeVisible();

    await page.locator("#pattern-task-stops").click();
    await expect(page.locator("#alignment-task")).toHaveCount(0);
    await expect(page.locator("#pattern-task-stops")).toHaveAttribute(
      "aria-current",
      "page",
    );

    await page.locator("#pattern-task-alignment").click();
    await expect(page.locator("#alignment-task")).toBeVisible();
    await expect(page.locator("#alignment-sections")).toBeVisible();

    if (existsSync(PATTERN_REFERENCE_PATH)) {
      await page.goto(`file://${PATTERN_REFERENCE_PATH}`);
      await page.waitForLoadState("networkidle");
      await capture(page, "map-line-copy-tab-reference-1440");
    }

    testInfo.annotations.push({
      type: "reference-captured",
      description: existsSync(PATTERN_REFERENCE_PATH)
        ? "map-line-copy-tab-reference-1440.png"
        : "path prototype absent from this checkout",
    });

    expect(problems).toEqual([]);
  });
});
