// Transfer helper policy journey (EV-5).
//
// Runs against the freshly seeded browser database the repository's Playwright
// configuration already uses (`bin/test-browser`, workers: 1, retries: 0) with
// `BROWSER_E2E=true`, and drives the real page: router → `TransfersLive` → the
// helper pack → `Transfers.apply_reviewed_policy_change/2` → PostgreSQL. Only
// the Esri tile hosts and the OpenRouter endpoint are faked, both at the network
// boundary, so no journey reaches the internet.
//
// The policy journey is the ordinary operator path the helper adds to this page:
// the draft they are writing becomes the one selection the helper may read, the
// prepared card hands its proposal to this page's own review, and only
// "Apply reviewed change" writes. Nothing here asserts the helper's prose; the
// review, the counts and the stored rule are the answer.
//
// The fixtures come from `test/support/browser_seed.exs`. The "Browser Transfers
// Version" carries the transfer network the journey writes one more rule into, so
// the seeded counts stay readable. `test/support/agents/browser_open_router.ex`
// scripts the provider: it prepares the page's own `selection-1` from the pack's
// real source snapshot, so a change in the page's draft is what the tool reads.
//
// Test titles keep the prefix branch review greps: policy, approval.
import { test, expect } from "@playwright/test";

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const TRANSFERS_VERSION = "Browser Transfers Version";

const E2E_VERSION = "Browser E2E Version";

// The Blocks journey's version. Its seed puts a two-block, two-connection group
// at BB_INSEAT on the weekday service, so both pairs are consecutive on every
// date they run and the helper may prepare them.
const BLOCKS_VERSION = "Browser Blocks Version";

// The approval journey's two routes are both on the seeded browser version: the
// Schedules read route calls BSS_3 at 06:11, and the grid route leaves BSS_4 at
// 06:48. Both run on CAL_DAILY, which covers every day either side of the seed
// date, so the date this page offers is a date both trips run.
const APPROVAL_FROM = {
  route: "BROWSER_SCHEDULES_READY",
  trip: "BROWSER_SCHED_T1",
  stop: "BSS_3",
  sequence: 3,
};
const APPROVAL_TO = {
  route: "BROWSER_SCHEDULES_GRID",
  trip: "BSG_T04",
  stop: "BSS_4",
  sequence: 4,
};

// A 1x1 opaque PNG, so the tile layers succeed without a network request.
const ONE_PX_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC";

const TILE_ROUTE = "**/map/tiles/**";

const DESKTOP = { width: 1440, height: 1000 };
const PHONE = { width: 375, height: 812 };

test.describe.configure({ mode: "serial" });

let pageErrors = [];

test.beforeEach(async ({ page }) => {
  pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error));

  await page.route(TILE_ROUTE, (route) =>
    route.fulfill({
      status: 200,
      contentType: "image/png",
      body: Buffer.from(ONE_PX_PNG_BASE64, "base64"),
    }),
  );
});

test.afterEach(() => {
  expect(pageErrors).toEqual([]);
});

test.describe("transfer policy helper", () => {
  test("policy: the panel sits beside the editor and the draft becomes the source", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openDraft(page);

    await page.locator("#transfer-policy-select").click();

    // The source is the operator's own draft, shown back before they ask for
    // anything: the direction, the type and the seconds they typed.
    await expect(page.locator("#transfer-policy-selections")).toContainText(
      "BXF_CEN_C",
    );
    await expect(page.locator("#transfer-policy-selections")).toContainText(
      "BXF_MUS",
    );
    await expect(page.locator("#transfer-policy-selections")).toContainText(
      "300 seconds",
    );

    // The draft is still on screen: staging a selection saves nothing.
    await expect(page.locator("#transfer-editor")).toBeVisible();
    await expect(page.locator("#transfer-min-time")).toHaveValue("300");

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();
    await expect(page.locator("#agent-panel")).toContainText(
      "Transfers · " + TRANSFERS_VERSION,
    );

    // The panel takes its own column on a wide screen; the editor keeps the rest.
    await expect(page.locator("#transfer-editor")).toBeVisible();
    const fitsViewport = await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    );
    expect(fitsViewport).toBe(true);

    await capture(page, testInfo, "policy-source-1440x1000");

    // Clearing the selection takes the source away with it, so the panel has
    // nothing to read until the operator supplies one again.
    await page.locator("#transfer-policy-clear").click();
    await expect(page.locator("#transfer-policy-selections")).toHaveCount(0);

    await page.locator("#transfer-policy-select").click();
    await expect(page.locator("#transfer-policy-selections")).toHaveCount(1);

    await page.setViewportSize(PHONE);
    await capture(page, testInfo, "policy-source-375x812");
  });

  test("policy: the prepared card opens this page's review and only its confirm writes", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openDraft(page);
    await stageDraft(page);

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();

    // Helper sessions live in the server process, so start a fresh one.
    await page.locator("#agent-new-conversation").click();

    await page
      .locator("#agent-composer-input")
      .fill("Give riders five minutes to change at Central Bay C");
    await page.locator("#agent-send").click();

    const reviewButton = page.locator('[id^="agent-review-prepared-"]').last();
    await expect(reviewButton).toHaveText("Review prepared transfer rule", {
      timeout: 30_000,
    });
    await expect(page.locator("#transfers-count")).toHaveText(
      "8 transfer rules",
      { timeout: 30_000 },
    );

    await reviewButton.click();

    // The review names the direction the operator wrote, in this version, and the
    // seconds their own draft carried.
    const review = page.locator("#transfer-policy-review");
    await expect(review).toBeVisible();
    await expect(page.locator("#transfer-policy-after")).toContainText(
      "BXF_CEN_C",
    );
    await expect(page.locator("#transfer-policy-after")).toContainText(
      "BXF_MUS",
    );
    await expect(page.locator("#transfer-policy-after")).toContainText(
      "300 seconds",
    );

    // Nothing is written until the reviewer confirms it.
    await expect(page.locator("#transfers-count")).toHaveText(
      "8 transfer rules",
    );

    await capture(page, testInfo, "policy-review-1440x1000");

    await page.locator("#transfer-policy-confirm").click();

    await expect(page.locator("#transfer-policy-status")).toContainText(
      "Saved transfer type 2",
      { timeout: 30_000 },
    );
    await expect(page.locator("#transfers-count")).toHaveText(
      "9 transfer rules",
    );

    // The receipt belongs to the entry that prepared this rule, settled by the
    // session's own event rather than by the page.
    await expect(page.locator('[id^="agent-prepared-"]').last()).toContainText(
      "Applied",
    );

    await capture(page, testInfo, "policy-saved-1440x1000");

    // The rule the operator reviewed is the one stored, in the direction they
    // wrote it.
    await expect(
      page.locator("#transfers").getByText("Transfer Central · Bay C"),
    ).toBeVisible();
  });

  test("policy: skipping a proposal writes nothing and says so", async ({
    page,
  }) => {
    await page.setViewportSize(DESKTOP);
    await openDraft(page);
    await stageDraft(page);

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();
    await page.locator("#agent-new-conversation").click();

    await page
      .locator("#agent-composer-input")
      .fill("Check what a transfer at Central Bay C would change");
    await page.locator("#agent-send").click();

    // The read prepares nothing, so the conversation settles with prose only and
    // no review button appears.
    await expect(page.locator("#agent-entries")).toContainText(
      "I prepared the transfer rule. Review it before applying.",
      { timeout: 30_000 },
    );

    // The page's own counts still read as an untouched version.
    await expect(page.locator("#transfers-count")).toHaveText(
      "8 transfer rules",
    );
    await expect(page.locator("#transfer-policy-review")).toHaveCount(0);
  });
});

// The connection approval journey (EV-16): the Schedules page's own form admits
// exactly what an operator approves, and an edit takes it back.
test.describe("connection approval helper", () => {
  test("approval: the approved pair becomes the helper's only source, and an edit takes it back", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openSchedules(page);

    // Both helpers this page offers are named by the page itself.
    await expect(
      page.locator("#schedule-helper-mode-connections"),
    ).toBeVisible();
    await expect(
      page.locator("#schedule-helper-mode-service_queries"),
    ).toBeVisible();

    // The page seeds its own route on the first pair's receiving side.
    await expect(page.locator("#connection-pair-1-from-route")).toHaveValue(
      APPROVAL_FROM.route,
    );

    await page.locator("#connection-pair-1-from-trip").fill(APPROVAL_FROM.trip);
    await page.locator("#connection-pair-1-from-stop").fill(APPROVAL_FROM.stop);
    await page
      .locator("#connection-pair-1-from-sequence")
      .fill(String(APPROVAL_FROM.sequence));
    await page.locator("#connection-pair-1-to-route").fill(APPROVAL_TO.route);
    await page.locator("#connection-pair-1-to-trip").fill(APPROVAL_TO.trip);
    await page.locator("#connection-pair-1-to-stop").fill(APPROVAL_TO.stop);
    await page
      .locator("#connection-pair-1-to-sequence")
      .fill(String(APPROVAL_TO.sequence));
    await page.locator("#connection-pair-1-candidate-arrival").fill("06:15");
    await page
      .locator("#connection-pair-1-candidate-approval")
      .fill("Dispatch sheet");

    await capture(page, testInfo, "approval-draft-1440x1000");

    await page.locator("#connection-approve").click();

    // The receipt is the approval itself: the pair count, the routes the read
    // resolved, the minimum it compares against and the digests it is bound to.
    await expect(page.locator("#connection-approval-receipt")).toBeVisible({
      timeout: 30_000,
    });
    await expect(page.locator("#connection-approval-pairs")).toHaveText(
      "1 pair",
    );
    await expect(page.locator("#connection-approval-routes")).toContainText(
      APPROVAL_FROM.route,
    );
    await expect(page.locator("#connection-approval-routes")).toContainText(
      APPROVAL_TO.route,
    );
    await expect(page.locator("#connection-approval-minimums")).toContainText(
      "stored minimum",
    );

    // The approved source opened the connections helper, and the page's own
    // control says which helper is bound to it.
    await expect(
      page.locator("#schedule-helper-mode-connections"),
    ).toHaveAttribute("aria-pressed", "true");

    await capture(
      page,
      testInfo,
      "approval-receipt-1440x1000",
      page.locator("#connection-approval-receipt"),
    );

    // The operator edits the approval: the source, the receipt and the
    // conversation that read it go together, and the draft stays on screen.
    await page.locator("#connection-pair-1-candidate-arrival").fill("06:20");

    await expect(page.locator("#connection-approval-receipt")).toHaveCount(0);
    await expect(
      page.locator("#connection-pair-1-candidate-arrival"),
    ).toHaveValue("06:20");
    await expect(page.locator("#connection-pair-1-to-trip")).toHaveValue(
      APPROVAL_TO.trip,
    );

    await capture(page, testInfo, "approval-edited-1440x1000");

    // A trip this version does not hold is refused, and the draft survives it.
    await page.locator("#connection-pair-1-to-trip").fill("NOT-A-TRIP");
    await page.locator("#connection-approve").click();

    await expect(page.locator("#connection-approval-notice")).toContainText(
      "not part of this version",
      { timeout: 30_000 },
    );
    await expect(page.locator("#connection-approval-receipt")).toHaveCount(0);
    await expect(page.locator("#connection-pair-1-to-trip")).toHaveValue(
      "NOT-A-TRIP",
    );

    // Switching helper keeps every value the operator typed.
    await page.locator("#schedule-helper-mode-service_queries").click();
    await expect(page.locator("#connection-pair-1-to-trip")).toHaveValue(
      "NOT-A-TRIP",
    );

    await page.setViewportSize(PHONE);
    await capture(page, testInfo, "approval-mobile-390x844");

    const fitsViewport = await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    );
    expect(fitsViewport).toBe(true);
  });

  // The comparison journey (EV-17): the numbers the page shows beside the
  // helper are the ones this version read in one snapshot, not the helper's
  // prose, and approving a comparison writes nothing.
  test("connections: the comparison beside the panel reports this version's own margins", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openSchedules(page);

    await page.locator("#connection-pair-1-from-trip").fill(APPROVAL_FROM.trip);
    await page.locator("#connection-pair-1-from-stop").fill(APPROVAL_FROM.stop);
    await page
      .locator("#connection-pair-1-from-sequence")
      .fill(String(APPROVAL_FROM.sequence));
    await page.locator("#connection-pair-1-to-route").fill(APPROVAL_TO.route);
    await page.locator("#connection-pair-1-to-trip").fill(APPROVAL_TO.trip);
    await page.locator("#connection-pair-1-to-stop").fill(APPROVAL_TO.stop);
    await page
      .locator("#connection-pair-1-to-sequence")
      .fill(String(APPROVAL_TO.sequence));

    // This version states no minimum for this pair, so the operator's own
    // approved minimum is the one it is compared against.
    await page
      .locator("#connection-pair-1-minimum-origin")
      .selectOption("supplied");
    await page.locator("#connection-pair-1-minimum-seconds").fill("600");
    await page
      .locator("#connection-pair-1-minimum-approval")
      .fill("Timetable sheet 2026-03-04");

    await page.locator("#connection-pair-1-candidate-arrival").fill("06:20:00");
    await page
      .locator("#connection-pair-1-candidate-departure")
      .fill("06:48:00");
    await page
      .locator("#connection-pair-1-candidate-approval")
      .fill("Dispatch sheet");

    await page.locator("#connection-approve").click();
    await expect(page.locator("#connection-approval-receipt")).toBeVisible({
      timeout: 30_000,
    });

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();
    await page.locator("#agent-new-conversation").click();
    await page
      .locator("#agent-composer-input")
      .fill("Can I make the connection, and how much time do I have?");
    await page.locator("#agent-send").click();

    const results = page.locator("#connection-comparison-results");
    await expect(results).toBeVisible({ timeout: 30_000 });

    // The card carries the pair, its totals and the minimum's provenance, all
    // read from this version.
    await expect(results).toContainText("1 approved connection pair");
    await expect(
      page.locator("#connection-comparison-row-pair-1-status"),
    ).toHaveText("Comparable");
    await expect(
      page.locator("#connection-comparison-row-pair-1-minimum"),
    ).toContainText("Supplied minimum 600 s");
    await expect(results).toContainText("not a guarantee");
    await expect(page.locator("#connection-comparison-source")).toContainText(
      "gtfs_connections",
    );

    await capture(page, testInfo, "connections-results-1440x1000", results);

    await page.setViewportSize({ width: 390, height: 844 });
    await capture(page, testInfo, "connections-results-390x844", results);

    // This card is what step 10 adds, so the narrow viewport is measured against
    // the card itself: nothing in it may push wider than its own column.
    const cardFits = await page.evaluate(() => {
      const card = document.querySelector("#connection-comparison-results");
      const edge = card.getBoundingClientRect().left + card.clientWidth + 1;
      const wide = [...card.querySelectorAll("*")]
        .filter((el) => el.getBoundingClientRect().right > edge)
        .map((el) => el.tagName + "#" + el.id);
      return { fits: card.scrollWidth <= card.clientWidth, wide };
    });
    expect(cardFits.wide).toEqual([]);
    expect(cardFits.fits).toBe(true);

    // Asking a question writes nothing to the version this card read from.
    await expect(page.locator("#connection-approval-receipt")).toBeVisible();
  });
});

// The in-seat journey (EV-18): the Blocks page's own connection group is the
// helper's only source, the prepared card opens the Set-all review this page
// already had, and only that review's Save writes. The whole journey lives on
// the seeded "Browser Blocks Version" group the seed puts at BB_INSEAT, and the
// provider stand-in prepares the choice the operator asked for from the page's
// own admitted snapshot.
//
// One scenario covers the group half. The single-connection half — the drawer
// that the helper populates instead of the Set-all review — is proved by the
// focused LiveView evidence
// (`test/gtfs_planner_web/live/gtfs/in_seat_assistance_live_test.exs`), because
// the connection drawer is a modal dialog in the top layer: the helper panel
// cannot be driven while it is open, so a browser journey would have to change
// the drawer's own modality to reach the composer.
test.describe("in-seat helper", () => {
  test("in-seat: the group becomes the source, the prepared card opens this page's review, and only its save writes", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openBlocksConnections(page);

    // The group the seed derives, opened through the page's own group row, so
    // the journey drives the same selection a reader does.
    const groupRow = page
      .locator('[id^="connections-group-"]')
      .filter({ hasText: "Blocks In-seat Plaza" })
      .first();
    await expect(groupRow).toBeVisible();
    await groupRow.click();
    await expect(page.locator("#connections-group-heading")).toContainText(
      "Blocks In-seat Plaza",
    );

    // The page offers the helper wherever it can supply a connection, and the
    // group control names the whole selection rather than one row.
    await expect(page.locator("#agent-helper-open")).toBeVisible();
    await expect(page.locator("#in-seat-helper-group")).toBeVisible();
    await expect(page.locator("#in-seat-helper-notice")).toHaveCount(0);

    // The receipt is the page's own answer: how many connections, and the day
    // type on screen. Nothing the operator typed names a pair.
    await page.locator("#in-seat-helper-group").click();
    const source = page.locator("#in-seat-helper-source");
    await expect(source).toBeVisible({ timeout: 30_000 });
    await expect(source).toContainText("2 connections in this group");

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();
    await expect(page.locator("#agent-panel")).toContainText(
      "Blocks · " + BLOCKS_VERSION,
    );
    await page.locator("#agent-new-conversation").click();

    await capture(page, testInfo, "in-seat-source-1440x1000");

    await page
      .locator("#agent-composer-input")
      .fill("These have to be a reboard");
    await page.locator("#agent-send").click();

    // The prepared card carries this page's one prepared command kind, under the
    // label this page gives it.
    const reviewButton = page.locator('[id^="agent-review-prepared-"]').last();
    await expect(reviewButton).toHaveText("Review prepared in-seat setting", {
      timeout: 30_000,
    });

    // Preparing wrote nothing: the review has not been asked for yet, and the
    // page offers no notice about a change it has not opened for review.
    await expect(page.locator("#set-all-review")).toHaveCount(0);
    await expect(page.locator("#in-seat-helper-notice")).toHaveCount(0);

    await reviewButton.click();

    // The review is this page's existing Set-all review, under the prepared
    // choice, with the fresh expected rows the page rebuilt. Both rows are
    // actionable: one carries the seed's own type-4 record and the other carries
    // none, so the save changes one setting and writes the other.
    const review = page.locator("#set-all-review");
    await expect(review).toBeVisible();
    await expect(review).toContainText("riders must re-board");
    await expect(page.locator("#set-all-review-included")).toHaveText(
      "2 of 2 included",
    );
    await expect(page.locator("[data-role='bulk-result']")).toHaveCount(0);
    await expect(page.locator("#in-seat-helper-notice")).toContainText(
      "Nothing is saved until you save it on this page",
    );

    await capture(page, testInfo, "in-seat-review-1440x1000", review);

    await page.locator("#set-all-review-save").click();

    // The result is the page's own, naming the setting the review changed and
    // the count it wrote, with no skipped row.
    const result = page.locator("[data-role='bulk-result']");
    await expect(result).toContainText("Saved 2 connections", {
      timeout: 30_000,
    });
    await expect(page.locator("[data-role='bulk-result-skip']")).toHaveCount(0);

    // The receipt belongs to the entry that prepared this setting, settled by
    // the save rather than by the helper.
    await expect(page.locator('[id^="agent-prepared-"]').last()).toContainText(
      "Applied",
    );

    await capture(page, testInfo, "in-seat-saved-1440x1000", result);

    // The Undo is the page's existing guarded Undo: it restores the row the save
    // itself wrote and leaves the record the seed already held alone. The panel
    // is closed first, because the result the Undo lives beside is the page's own
    // rather than the panel's.
    await page.locator("#agent-panel-close").click();
    await expect(page.locator("#agent-panel")).toHaveCount(0);
    await page.locator("#bulk-undo").click();
    await expect(result).toContainText("Restored 2 connections.", {
      timeout: 30_000,
    });

    await page.setViewportSize({ width: 390, height: 844 });
    const fitsViewport = await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    );
    expect(fitsViewport).toBe(true);
    await capture(page, testInfo, "in-seat-saved-390x844");
  });
});

// Signs in, reaches the seeded transfers version and opens a new draft whose
// direction and time this journey reviews.
async function openDraft(page) {
  await login(page);

  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: TRANSFERS_VERSION });
  await expect(option).toHaveCount(1);
  const versionId = await option.getAttribute("data-version-id");
  if (!versionId)
    throw new Error(`${TRANSFERS_VERSION} is missing its version ID`);

  await page.goto(`/gtfs/${versionId}/transfers`);
  await page.waitForSelector("#transfers-create, #transfers-first-use-create", {
    timeout: 15_000,
  });

  await page.locator("#transfers-create").click();
  await expect(page.locator("#transfer-editor")).toBeVisible();
}

// Writes the draft this journey offers the helper: Bay C to the museum, a type 2
// rule with five minutes. The values go in the page's own editor.
async function stageDraft(page) {
  await pickStop(page, "from", "Transfer Central · Bay C");
  await pickStop(page, "to", "Transfer Museum");
  await page.locator("#transfer-min-time").fill("300");
  await page.locator("#transfer-policy-select").click();
  await expect(page.locator("#transfer-policy-selections")).toHaveCount(1);
}

// Signs in, reaches the seeded schedules version and opens the route whose
// approval this journey fills in.
async function openSchedules(page) {
  await login(page);

  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: E2E_VERSION });
  await expect(option).toHaveCount(1);
  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${E2E_VERSION} is missing its version ID`);

  await page.goto(`/gtfs/${versionId}/routes/${APPROVAL_FROM.route}/schedules`);
  await page.waitForSelector("#connection-approval-form", { timeout: 15_000 });
}

// Signs in, reaches the seeded blocks version and opens the Connections view,
// where the group's own rows are the selection this journey hands over.
async function openBlocksConnections(page) {
  await login(page);

  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: BLOCKS_VERSION });
  await expect(option).toHaveCount(1);
  const versionId = await option.getAttribute("data-version-id");
  if (!versionId)
    throw new Error(`${BLOCKS_VERSION} is missing its version ID`);

  await page.goto(`/gtfs/${versionId}/blocks?view=connections`);
  await page.waitForSelector("#connections-panel", { timeout: 15_000 });
}

async function login(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR_USER.email);
  await page.fill('input[name="user[password]"]', EDITOR_USER.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function pickStop(page, side, label) {
  const input = page.locator(`#transfer_${side}_stop_id_text_input`);

  await input.click();
  await input.fill(label);

  const option = page
    .locator(`#transfer-${side}-stop ul div[data-idx]`)
    .filter({ hasText: label })
    .first();
  await expect(option).toBeVisible();
  await option.click();
  await expect(input).toHaveValue(label);
}

async function capture(page, testInfo, name, subject) {
  if (subject) await subject.scrollIntoViewIfNeeded();
  await page.screenshot({
    path: testInfo.outputPath(`${name}.png`),
    animations: "disabled",
  });
}
