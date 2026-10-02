import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { bodyFitsViewport, readPendingStates } from "./browser_helpers";

/**
 * Station assistance browser journeys (step 11).
 *
 * Three ordinary journeys, entered through the routes an editor already uses:
 * the station report, one recorded reachability result, and the import review.
 * Nothing here injects an assign, registers a pack or writes a status: the
 * pages, the panel, the session, the turn loop, the packs and the domain reads
 * are the shipped ones, and only the final OpenRouter HTTP request is doubled
 * (`test/support/agents/browser_open_router.ex`, selected under `BROWSER_E2E`).
 *
 * Fixtures come from `test/support/browser_seed.exs`, run by `bin/test-browser`:
 * `BROWSER_STATION` with an elevator, a same-level and a cross-level pathway,
 * a completed router run that recorded its input digest (…901), a completed
 * legacy run that did not (…902), and `BROWSER_EVO/PW LIFT 1`, which carries a
 * saved closure.
 *
 * The import journey uploads one `pathways.txt` that changes the minimum width
 * of the three seeded pathways and the traversal time of the cross-level one,
 * and omits the closure-backed lift so its removal is proposed too. That gives
 * one width change an accepted measurement supports, one the same measurement is
 * disputed for, one decision that changes two fields, one natively approved row
 * and one removal Apply will genuinely refuse.
 */

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser E2E Version";
const STATION = "BROWSER_STATION";
// The run the seed recorded with `input_provenance`, and the legacy run that
// recorded no digest at all.
const ROUTER_RUN_ID = "00000000-0000-4000-8000-000000000901";
const LEGACY_RUN_ID = "00000000-0000-4000-8000-000000000902";
const CLOSURE_PATHWAY = "BROWSER_EVO/PW LIFT 1";

const VIEWPORTS = [
  { label: "1280", width: 1280, height: 900 },
  { label: "320", width: 320, height: 900 },
];

// The upload omits the closure-backed lift on purpose, so its removal is
// proposed and Apply has a row it will genuinely refuse. Every other pathway in
// the version is repeated exactly as seeded, so the only other decisions are the
// three width changes and one traversal-time change.
const PATHWAYS_UPLOAD = [
  "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,traversal_time,length,min_width",
  "BROWSER_PW_ELEVATOR,BROWSER_STOP_C,BROWSER_STOP_A,5,1,45,12.5,1.05",
  "BROWSER_PW_SAME_LEVEL,BROWSER_STOP_A,BROWSER_STOP_B,1,1,20,8.0,1.20",
  // Two changed fields, so no measurement can make this one eligible.
  "BROWSER_PW_CROSS_LEVEL,BROWSER_STOP_A,BROWSER_STOP_D,5,0,30,25.0,0.90",
  "CATALOG_PW_FULL,CATALOG_PATHWAY_STATION,CATALOG_PATHWAY_TO_A,2,0,32,18.5,",
  "CATALOG_PW_PARTIAL,CATALOG_PATHWAY_STATION,CATALOG_PATHWAY_TO_B,1,1,,45.0,",
  "BROWSER_EVO_PW_WALK,BROWSER_EVO_ENTRANCE,BROWSER_EVO_MEZZANINE,1,1,30,18.0,",
  "BROWSER_EVO_PW_STAIR,BROWSER_EVO_MEZZANINE,BROWSER_EVO_PLATFORM,2,1,60,14.0,",
  "BROWSER_EVO_EMPTY_PW,BROWSER_EVO_EMPTY_A,BROWSER_EVO_EMPTY_B,1,1,,,",
].join("\n");

const W14_SOURCE_REF = "SURVEY-NOV-C";
const W12_SOURCE_REF = "SURVEY-NOV-D";

// The canonical feature package lives in the primary checkout; a checkout
// without it falls back to Playwright's own output folder rather than writing
// outside the project.
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const EVIDENCE_DIR = path.resolve(__dirname, "../../.specs/ai-07-station-assistance/evidence");

function capturePath(testInfo, name) {
  return fs.existsSync(EVIDENCE_DIR)
    ? path.join(EVIDENCE_DIR, name)
    : testInfo.outputPath(name);
}

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return (
      main &&
      main.classList.contains("phx-connected") &&
      !main.hasAttribute("data-phx-pending") &&
      window.liveSocket?.isConnected()
    );
  });
}

async function seededVersionId(page) {
  await page.waitForSelector("#gtfs-version-switcher");

  const id = await page.evaluate(() => {
    const option = Array.from(document.querySelectorAll("[data-version-option]")).find(
      (button) => button.textContent.trim().startsWith("Browser E2E Version"),
    );
    return option ? option.dataset.versionId : null;
  });

  if (!id) throw new Error("Browser E2E Version is missing from the version switcher");
  return id;
}

function focusedId(page) {
  return page.evaluate(() => document.activeElement?.id ?? "");
}

/** Opens the panel on the page and starts a fresh conversation on it. */
async function openPanel(page) {
  if ((await page.locator("#agent-panel").count()) === 0) {
    await page.locator("#station-helper-open").click();
  }
  await expect(page.locator("#agent-panel")).toBeVisible();
  await page.locator("#agent-new-conversation").click();
  await expect(page.locator("#agent-composer-input")).toBeVisible();
}

async function ask(page, message) {
  await page.locator("#agent-composer-input").fill(message);
  await page.locator("#agent-send").click();
}

/**
 * Waits for the assistant entry produced by `ask` and returns its evidence
 * cards, so a journey asserts on the server's own card rather than on prose.
 */
async function answerCards(page, entryIndex) {
  const prose = page.locator(`#agent-prose-${entryIndex}`);
  await expect(prose).toBeVisible({ timeout: 30_000 });
  return page.locator(`[id^="agent-evidence-${entryIndex}-"]`);
}

/** Tabs forward until `id` holds focus, so no selector ordering is assumed. */
async function tabUntilFocused(page, id, limit = 200) {
  for (let index = 0; index < limit; index += 1) {
    if ((await focusedId(page)) === id) return;
    await page.keyboard.press("Tab");
  }
  throw new Error(`never reached #${id} by keyboard`);
}

test.describe("station report result helper", () => {
  for (const viewport of VIEWPORTS) {
    test(`explains a recorded check and the current facts at ${viewport.width}`, async ({
      page,
    }, testInfo) => {
      test.setTimeout(120_000);
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await logIn(page);
      const versionId = await seededVersionId(page);

      await page.goto(`/gtfs/${versionId}/stops/${STATION}/report`);
      await waitForLiveView(page);

      // Nothing is selected on arrival, and the page says so rather than
      // guessing which check the helper would explain.
      await expect(page.locator("#station-helper-bar")).toBeVisible();
      await expect(page.locator("#station-helper-open")).toHaveAttribute(
        "aria-expanded",
        "false",
      );
      await expect(page.locator("#station-helper-freshness")).toContainText(
        "No recorded check is selected",
      );

      // The legacy run recorded no digest: unknown freshness, stated as unknown.
      await page
        .locator("#station-result-run-select-input")
        .selectOption(LEGACY_RUN_ID);
      await expect(page.locator("#station-helper-freshness")).toContainText(
        "recorded no input digest, so how current its input is, is unknown",
      );

      // The router run recorded one, and the page names it rather than
      // claiming it still matches.
      await page
        .locator("#station-result-run-select-input")
        .selectOption(ROUTER_RUN_ID);
      await expect(page.locator("#station-helper-freshness")).toContainText(
        "This check recorded its input (digest",
      );
      await page.screenshot({
        path: capturePath(testInfo, `step-011-report-selected-${viewport.label}.png`),
        animations: "disabled",
        fullPage: true,
      });

      await openPanel(page);
      await expect(page.locator("#station-helper-open")).toHaveAttribute(
        "aria-expanded",
        "true",
      );

      await ask(page, "What did the recorded check say?");

      const resultCards = await answerCards(page, 1);
      await expect(resultCards.locator('[data-evidence-kind="recorded_result"]')).toHaveCount(1);
      const resultCard = resultCards.locator('[data-evidence-kind="recorded_result"]');
      // The card is the answer: the recorded input and its data-equality
      // verdict come from the server, not from the stand-in's sentence.
      await expect(resultCard).toContainText("Recorded input digest");
      await expect(resultCard).toContainText("Data equality");
      await page.screenshot({
        path: capturePath(testInfo, `step-011-report-result-${viewport.label}.png`),
        animations: "disabled",
        fullPage: true,
      });

      await ask(page, "Which pairs did the recorded check store?");
      const pairCards = await answerCards(page, 3);
      await expect(
        pairCards.locator('[data-evidence-kind="recorded_result_pairs"]'),
      ).toHaveCount(1);

      await ask(page, "What is wrong with the station right now?");
      const factCards = await answerCards(page, 5);
      const factCard = factCards.locator('[data-evidence-kind="station_report_facts"]');
      await expect(factCard).toHaveCount(1);
      await expect(factCard).toContainText("Current station report facts");
      await expect(factCard).toContainText("Captured at");
      // Current facts stay their own source beside the recorded result.
      await expect(factCard).toContainText(
        "current facts, not an explanation of an earlier recorded result",
      );
      await page.screenshot({
        path: capturePath(testInfo, `step-011-report-facts-${viewport.label}.png`),
        animations: "disabled",
        fullPage: true,
      });

      // The read-only pack prepares nothing and offers no apply control.
      await expect(page.locator('[id^="agent-prepared-"]')).toHaveCount(0);
      await expect(page.locator("#agent-entries")).not.toContainText("Apply decisions");

      const overflow = await bodyFitsViewport(page);
      expect(overflow, "the report page must not scroll sideways").toBe(true);

      const pending = await readPendingStates(page);
      expect(pending, "no LiveView request may still be in flight").toEqual([]);
    });
  }
});

test.describe("recorded reachability result helper", () => {
  test("explains the recorded result the result page is showing", async ({ page }, testInfo) => {
    test.setTimeout(120_000);
    await page.setViewportSize({ width: 1280, height: 900 });
    await logIn(page);
    const versionId = await seededVersionId(page);

    await page.goto(
      `/gtfs/${versionId}/station-reachability/${ROUTER_RUN_ID}?stop_id=${STATION}`,
    );
    await waitForLiveView(page);
    await expect(page.locator("#station-reachability-results")).toBeVisible();

    await expect(page.locator("#station-result-helper-bar")).toBeVisible();
    await expect(page.locator("#station-helper-freshness")).toContainText(
      "This check recorded its input (digest",
    );

    await openPanel(page);
    await ask(page, "What did the recorded check say?");

    const cards = await answerCards(page, 1);
    const card = cards.locator('[data-evidence-kind="recorded_result"]');
    await expect(card).toHaveCount(1);
    // The result page's own envelope: the engine that produced it and the
    // station it is about.
    await expect(card).toContainText(ROUTER_RUN_ID);
    await page.screenshot({
      path: capturePath(testInfo, "step-011-result-helper-1280.png"),
      animations: "disabled",
      fullPage: true,
    });

    await ask(page, "Which pairs did the recorded check store?");
    const pairCards = await answerCards(page, 3);
    await expect(
      pairCards.locator('[data-evidence-kind="recorded_result_pairs"]'),
    ).toHaveCount(1);
    await expect(page.locator('[id^="agent-prepared-"]')).toHaveCount(0);
  });
});

test.describe("import station measurements", () => {
  test("maps, reviews, confirms and applies one measured width beside native approvals", async ({
    page,
  }, testInfo) => {
    test.setTimeout(180_000);
    await page.setViewportSize({ width: 1280, height: 900 });
    await logIn(page);
    const versionId = await seededVersionId(page);

    await page.goto(`/gtfs/${versionId}/import`);
    await waitForLiveView(page);
    await expect(page.locator("#import-page")).toBeVisible();

    // A review left over from another run opens on its own; start over so the
    // upload form is showing.
    const resetDiff = page.locator("#diff-reset-btn");
    if (await resetDiff.count()) {
      await resetDiff.click();
      await expect(resetDiff).toHaveCount(0);
    }

    await page.locator("#import-source-station").check();
    await expect(page.locator("#diff-upload-form")).toBeVisible();

    await page.locator("#diff-upload-input input").setInputFiles({
      name: "pathways.txt",
      mimeType: "text/plain",
      buffer: Buffer.from(PATHWAYS_UPLOAD),
    });
    await expect(page.locator("#diff-upload-entries")).toContainText("pathways.txt");
    await page.locator("#diff-compute-btn").click();
    await page.locator("#diff-decisions [data-review-row]").first().waitFor({ timeout: 60_000 });

    // Three width changes, one traversal-time change and one removal: nothing
    // else, because every other seeded pathway is repeated exactly.
    await expect(page.locator("#diff-decisions [data-review-row]")).toHaveCount(5);
    await expect(
      page.locator("#diff-decisions [data-review-row][data-action='remove']"),
    ).toHaveCount(1);

    // Only this station's pathways are measurable, so the scope selector offers
    // it and nothing else.
    await page.locator("#station-observation-scope-input").selectOption(STATION);
    await expect(page.locator("#station-observation-form")).toBeVisible();
    await page.screenshot({
      path: capturePath(testInfo, "step-011-import-mapping-1280.png"),
      animations: "disabled",
      fullPage: true,
    });

    // A refused measurement keeps the row and takes focus, so the person can
    // correct it rather than retype it.
    await captureMeasurement(page, {
      pathway: "BROWSER_PW_ELEVATOR",
      value: "wide",
      sourceRef: W14_SOURCE_REF,
    });
    const error = page.locator("#station-observation-error");
    await expect(error).toBeVisible();
    await expect(error).toBeFocused();
    await expect(page.locator("#station-observation-value")).toHaveValue("wide");
    await page.screenshot({
      path: capturePath(testInfo, "step-011-import-mapping-error-1280.png"),
      animations: "disabled",
      fullPage: true,
    });

    // The accepted width the uploaded file also carries: 105 cm is 1.05 m.
    await captureMeasurement(page, {
      pathway: "BROWSER_PW_ELEVATOR",
      value: "105",
      sourceRef: W14_SOURCE_REF,
    });
    await expect(error).toHaveCount(0);
    await expect(page.locator("#station-observation-list")).toContainText(
      "BROWSER_PW_ELEVATOR · 1.05 m",
    );
    await expect(page.locator("#station-observation-list")).toContainText(
      `Measured 105 cm on ${todayIso()} as the minimum clear width`,
    );

    // The same measurement for a second pathway, with the conflict staff
    // recorded against it: it stays listed, and it cannot support a decision.
    await captureMeasurement(page, {
      pathway: "BROWSER_PW_SAME_LEVEL",
      value: "120",
      sourceRef: W12_SOURCE_REF,
      conflict: true,
    });
    await expect(page.locator("#station-observation-list")).toContainText(
      "BROWSER_PW_SAME_LEVEL · 1.20 m",
    );
    await expect(page.locator("#station-observation-list")).toContainText(
      "a conflict is recorded against this measurement",
    );
    await page.screenshot({
      path: capturePath(testInfo, "step-011-import-captured-1280.png"),
      animations: "disabled",
      fullPage: true,
    });

    // Native approvals beside the measured one, so the apply scope has to name
    // both kinds. The cross-level decision changes two fields; approving it is
    // the editor's own call, not the helper's.
    await approveDecision(page, "pathway:BROWSER_PW_CROSS_LEVEL");
    await approveDecision(page, `pathway:${CLOSURE_PATHWAY}`);
    await expect(page.locator("#station-approved-apply-scope")).toContainText(
      "2 approved changes",
    );
    await expect(page.locator("#station-approved-apply-scope")).toContainText(
      "including 0 confirmed against a captured measurement",
    );

    await openPanel(page);
    await ask(page, "Which width changes do these measurements support?");

    // The evidence card carries the counts, so the refused rows are visible as
    // the domain's own reasons rather than as the model's prose.
    const preparedCard = page
      .locator('[data-evidence-kind="station_import_selection"]')
      .last();
    await expect(preparedCard).toBeVisible({ timeout: 30_000 });
    await expect(preparedCard).toContainText("Requested");
    await expect(preparedCard).toContainText("Prepared");
    await expect(preparedCard).toContainText("Unresolved");
    await expect(preparedCard).toContainText(
      "2 decisions unresolved as no_accepted_observation",
    );
    await expect(preparedCard).toContainText(
      "1 decisions unresolved as incomplete_field_coverage",
    );
    await expect(preparedCard).toContainText(
      "2 decisions in this station are already approved and are never selected implicitly",
    );

    // Reviewing writes nothing: the approved scope is unchanged, and the
    // proposed rows are the review's own projection.
    await page.locator('[id^="agent-review-prepared-"]').last().click();
    const review = page.locator("#station-suggestion-review");
    await expect(review).toBeVisible();
    await expect(review.locator("#station-suggestion-confirm")).toBeFocused();
    await expect(review.locator("#station-suggestion-row-pathway-BROWSER_PW_ELEVATOR")).toBeVisible();
    await expect(review).toContainText("→ 1.05");
    await expect(review).toContainText(`Measured 105 cm on ${todayIso()}`);
    await expect(review).toContainText(W14_SOURCE_REF);
    // Only the one supported row is proposed.
    await expect(review.locator("[data-suggestion-row]")).toHaveCount(1);
    await page.screenshot({
      path: capturePath(testInfo, "step-011-import-review-1280.png"),
      animations: "disabled",
      fullPage: true,
    });

    // Cancel reaches nothing: no approval, the proposal stays retrievable and
    // focus returns to the control the review was opened from.
    await review.locator("#station-suggestion-cancel").click();
    await expect(review).toHaveCount(0);
    await expect(page.locator("#station-approved-apply-scope")).toContainText(
      "2 approved changes",
    );
    await expect(page.locator("#station-helper-open")).toBeFocused();

    await page.locator('[id^="agent-review-prepared-"]').last().click();
    await expect(review).toBeVisible();

    // Confirming reaches the native writer from the keyboard.
    await tabUntilFocused(page, "station-suggestion-cancel");
    await tabUntilFocused(page, "station-suggestion-confirm");
    await page.keyboard.press("Enter");

    await expect(page.locator("#station-suggestion-status")).toBeVisible();
    await expect(page.locator("#station-suggestion-status")).toContainText(
      "Nothing has been applied yet.",
    );
    await expect(page.locator("#station-approved-apply-scope")).toBeFocused();
    await expect(page.locator("#station-approved-apply-scope")).toContainText(
      "3 approved changes",
    );
    await expect(page.locator("#station-approved-apply-scope")).toContainText(
      "including 1 confirmed against a captured measurement",
    );
    const scopeRows = page.locator("#station-approved-apply-scope-list [data-apply-scope-row]");
    await expect(scopeRows).toHaveCount(3);
    const reviewedRow = scopeRows.filter({ hasText: "BROWSER_PW_ELEVATOR" });
    await expect(reviewedRow).toHaveAttribute("data-reviewed", "true");
    await expect(reviewedRow).toContainText("confirmed against a captured measurement");
    await expect(scopeRows.filter({ hasText: "BROWSER_PW_CROSS_LEVEL" })).toHaveAttribute(
      "data-reviewed",
      "false",
    );
    await page.screenshot({
      path: capturePath(testInfo, "step-011-import-confirmed-1280.png"),
      animations: "disabled",
      fullPage: true,
    });

    // Apply is a separate step, and its outcome is the persisted result rather
    // than a claim: the measured width applies, the closure-backed removal
    // does not.
    await page.locator("#diff-apply-btn").click();
    await expect(page.locator("#diff-done")).toBeVisible({ timeout: 60_000 });
    await expect(page.locator("#diff-count-applied")).toContainText("2");
    await expect(page.locator("#diff-count-failed")).toContainText("1");

    const outcome = page.locator("#station-apply-outcome [data-apply-outcome-row]");
    await expect(outcome).toHaveCount(3);
    // The measured width applied, the two-field native change applied, and the
    // closure-backed removal is the one that did not.
    await expect(outcome.filter({ hasText: "BROWSER_PW_ELEVATOR" })).toHaveAttribute(
      "data-reviewed",
      "true",
    );
    await expect(outcome.filter({ hasText: "BROWSER_PW_ELEVATOR" })).toHaveAttribute(
      "data-outcome",
      "applied",
    );
    await expect(outcome.filter({ hasText: CLOSURE_PATHWAY })).toHaveAttribute(
      "data-outcome",
      "failed",
    );
    await page.screenshot({
      path: capturePath(testInfo, "step-011-import-partial-1280.png"),
      animations: "disabled",
      fullPage: true,
    });

    const overflow = await bodyFitsViewport(page);
    expect(overflow, "the import page must not scroll sideways").toBe(true);

    const pending = await readPendingStates(page);
    expect(pending, "no LiveView request may still be in flight").toEqual([]);
  });

  test("keeps the review and the mapping keyboard-operable at 320", async ({ page }, testInfo) => {
    test.setTimeout(180_000);
    await page.setViewportSize({ width: 320, height: 900 });
    await logIn(page);
    const versionId = await seededVersionId(page);

    await page.goto(`/gtfs/${versionId}/import`);
    await waitForLiveView(page);
    await expect(page.locator("#import-page")).toBeVisible();

    const resetDiff = page.locator("#diff-reset-btn");
    if (await resetDiff.count()) {
      await resetDiff.click();
      await expect(resetDiff).toHaveCount(0);
    }

    await page.locator("#import-source-station").check();
    await page.locator("#diff-upload-input input").setInputFiles({
      name: "pathways.txt",
      mimeType: "text/plain",
      buffer: Buffer.from(PATHWAYS_UPLOAD),
    });
    await expect(page.locator("#diff-upload-entries")).toContainText("pathways.txt");
    await page.locator("#diff-compute-btn").click();
    await page.locator("#diff-decisions [data-review-row]").first().waitFor({ timeout: 60_000 });

    await page.locator("#station-observation-scope-input").selectOption(STATION);
    await captureMeasurement(page, {
      pathway: "BROWSER_PW_ELEVATOR",
      value: "105",
      sourceRef: W14_SOURCE_REF,
    });
    await expect(page.locator("#station-observation-list")).toContainText(
      "BROWSER_PW_ELEVATOR · 1.05 m",
    );

    await openPanel(page);
    await ask(page, "Which width changes do these measurements support?");

    const preparedCard = page
      .locator('[data-evidence-kind="station_import_selection"]')
      .last();
    await expect(preparedCard).toBeVisible({ timeout: 30_000 });
    await page.locator('[id^="agent-review-prepared-"]').last().click();

    const review = page.locator("#station-suggestion-review");
    await expect(review).toBeVisible();
    await expect(review.locator("#station-suggestion-confirm")).toBeFocused();
    // Tab reaches Cancel and back to Confirm without leaving the review.
    await tabUntilFocused(page, "station-suggestion-cancel");
    await page.screenshot({
      path: capturePath(testInfo, "step-011-import-review-320.png"),
      animations: "disabled",
      fullPage: true,
    });

    await tabUntilFocused(page, "station-suggestion-confirm");
    await page.keyboard.press("Enter");
    await expect(page.locator("#station-approved-apply-scope")).toBeFocused();
    await expect(page.locator("#station-approved-apply-scope")).toContainText(
      "including 1 confirmed against a captured measurement",
    );
    await page.screenshot({
      path: capturePath(testInfo, "step-011-import-scope-320.png"),
      animations: "disabled",
      fullPage: true,
    });

    const overflow = await bodyFitsViewport(page);
    expect(overflow, "the import page must not scroll sideways at 320").toBe(true);
  });
});

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

/** Fills and submits the page's own measurement form, by its own controls. */
async function captureMeasurement(page, { pathway, value, sourceRef, conflict = false }) {
  await page.locator("#station-observation-pathway").selectOption(pathway);
  await page.locator("#station-observation-value").fill(value);
  await page.locator("#station-observation-meaning").selectOption("minimum_clear_width");
  await page.locator("#station-observation-source").fill(sourceRef);
  await page.locator("#station-observation-accepted").check();

  const conflictBox = page.locator("#station-observation-conflict");
  if (conflict) await conflictBox.check();
  else await conflictBox.uncheck();

  await page.locator("#station-observation-save").click();
}

async function approveDecision(page, decisionId) {
  await page
    .locator(
      `#diff-decisions button[phx-click='approve-decision'][phx-value-id='${decisionId}']`,
    )
    .click();
  await expect(
    page.locator(
      `#diff-decisions button[phx-click='approve-decision'][phx-value-id='${decisionId}']`,
    ),
  ).toHaveAttribute("aria-pressed", "true");
}