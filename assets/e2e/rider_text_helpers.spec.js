import { test, expect } from "@playwright/test";
import { logInAs } from "./browser_helpers";
import { mkdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

/**
 * Rider text and stop review helpers (AI-02): the Headsign helper on the pattern
 * page and the two stop helpers on the stops pages.
 *
 * Every case runs the ordinary routes through the normal login against the
 * seeded browser database (`test/support/browser_seed.exs`). Only the provider
 * HTTP boundary is scripted, through `GtfsPlanner.Agents.BrowserOpenRouter`; the
 * page, the panel, the session, the packs and the native editors are the shipped
 * ones. Captures land in the canonical spec evidence folder; override with
 * `AI02_CAPTURE_DIR`.
 *
 * The `headsigns panel` case is read-only on BROWSER-HS1. The `headsigns journey`
 * cases own BROWSER-HS6: the first saves and undoes, the second ends with the native
 * Undo so the pattern is restored, and the third saves nothing.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const CAPTURE_DIR =
  process.env.AI02_CAPTURE_DIR ||
  resolve(
    import.meta.dirname,
    "..",
    "test-results",
    "captures",
    "ai-02-rider-text-and-stop-review",
  );

const DESKTOP = { width: 1440, height: 1000 };
const PHONE = { width: 390, height: 844 };

async function capture(page, folder, name) {
  const dir = resolve(CAPTURE_DIR, folder);
  mkdirSync(dir, { recursive: true });
  await page.screenshot({ path: resolve(dir, `${name}.png`), fullPage: true });
}

// A drawer is a top-layer dialog anchored to the viewport, so a full-page shot
// leaves it half outside the frame; this captures what a person sees.
async function captureViewport(page, folder, name) {
  const dir = resolve(CAPTURE_DIR, folder);
  mkdirSync(dir, { recursive: true });
  await page.screenshot({ path: resolve(dir, `${name}.png`), animations: "disabled" });
}

// The drawer slides in over 300ms, so a capture or a coordinate taken at open
// time freezes it mid-flight; wait for it to sit at the viewport's right edge.
async function waitDrawerSettled(page, panelId = "headsign-review-drawer") {
  await expect
    .poll(() =>
      page.evaluate((id) => {
        const panel = document.querySelector(`#${id}`);
        const aside = panel && panel.closest("aside");
        return aside ? aside.getBoundingClientRect().right - window.innerWidth : Number.NaN;
      }, panelId),
    )
    .toBeLessThanOrEqual(1);
}

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

async function versionIdFor(page, versionName = "Browser E2E Version") {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

/** The element the browser currently has focus on, by its DOM id. */
function focusedId(page) {
  return page.evaluate(() => document.activeElement?.id ?? "");
}

/** The document fits the viewport: nothing makes the page scroll sideways. */
function fitsViewport(page) {
  return page.evaluate(
    () => document.documentElement.scrollWidth <= window.innerWidth,
  );
}

async function openPattern(page, versionId, routeId, patternId, task) {
  await page.goto(
    `/gtfs/${versionId}/routes/${routeId}/patterns/${patternId}?task=${task}`,
  );
  await page.waitForSelector("#pattern-editor-content", { timeout: 15000 });
  await waitForLiveView(page);
}

let versionId;

// The headsign cases sign in as the pattern editor of the Browser E2E version; the
// stop cases sign in as the stops-map editor of its own version. Each case signs in
// for itself, because one browser context cannot hold both users.
async function signInHeadsignEditor(page) {
  await logInAs(page, EDITOR_USER);
  versionId = await versionIdFor(page);
}

test("headsigns panel", async ({ page }) => {
  await signInHeadsignEditor(page);
  test.setTimeout(90_000);

  for (const [label, viewport] of [
    ["1440", DESKTOP],
    ["390", PHONE],
  ]) {
    await page.setViewportSize(viewport);
    await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "details");

    // The native Details form is live and the helper is offered, closed.
    await expect(page.locator("#pattern-details-form")).toBeVisible();
    await expect(page.locator("#pattern-details-headsign")).toBeEnabled();
    const open = page.locator("#agent-helper-open");
    await expect(open).toBeVisible();
    await expect(open).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator("#agent-panel")).toHaveCount(0);
    expect(await fitsViewport(page)).toBe(true);
    await capture(page, "headsigns-panel", `closed-${label}`);

    // Opening the panel moves focus to the composer and shows first-use copy.
    await open.click();
    const panel = page.locator("#agent-panel");
    await expect(panel).toBeVisible();
    await expect(open).toHaveAttribute("aria-expanded", "true");
    await expect(panel).toContainText("Headsign helper");
    await expect(panel).toContainText("Pattern Browser Headsign One · Details");
    await expect(panel.locator("#agent-example-1")).toBeVisible();
    await expect(panel.locator("#agent-example-2")).toBeVisible();
    expect(await focusedId(page)).toBe("agent-composer-input");
    expect(await fitsViewport(page)).toBe(true);

    // The native form is still usable with the panel open.
    await expect(page.locator("#pattern-details-headsign")).toBeEnabled();
    await capture(page, "headsigns-panel", `open-${label}`);

    // Closing returns focus to the button that opened it.
    await page.locator("#agent-panel-close").click();
    await expect(panel).toHaveCount(0);
    expect(await focusedId(page)).toBe("agent-helper-open");
  }

  // The helper is offered on Running times with a timing, not on Stops.
  await page.setViewportSize(DESKTOP);
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "timings");
  await expect(page.locator("#agent-helper-open")).toBeVisible();

  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "stops");
  await expect(page.locator("#agent-helper-open")).toHaveCount(0);
});

// -- headsigns journey ----------------------------------------------------------

const HS6 = ["BROWSER_HEADSIGNS", "BROWSER-HS6"];
const RENAME_REQUEST = "Rename the Lincoln City headsign to Central Station.";

/** Opens the panel on the pattern's Details task and starts an empty conversation. */
async function startConversation(page) {
  if ((await page.locator("#agent-panel").count()) === 0) {
    await page.locator("#agent-helper-open").click();
  }

  await expect(page.locator("#agent-panel")).toBeVisible();
  await page.locator("#agent-new-conversation").click();
  await expect(page.locator("#agent-composer-input")).toBeVisible();
}

async function ask(page, message) {
  await page.locator("#agent-composer-input").fill(message);
  await page.locator("#agent-send").click();
}

/** The prepared card of the current conversation, once the turn has settled. */
async function preparedCard(page) {
  const card = page.locator('section[id^="agent-prepared-"]');
  await expect(card).toBeVisible({ timeout: 20000 });
  return card;
}

// Prepares the rename on Details and presses the card's Review headsigns button.
async function prepareAndReview(page) {
  await openPattern(page, versionId, ...HS6, "details");
  await expect(page.locator("#headsign-usage")).toContainText("Used by 5 trips");
  await startConversation(page);
  await ask(page, RENAME_REQUEST);

  const card = await preparedCard(page);
  await expect(card).toContainText("3 trips change");
  await expect(card).toContainText("2 trips keep their own text");

  // Preparing wrote nothing: the field and the usage line are as stored.
  await expect(page.locator("#pattern-details-headsign")).toHaveValue("Lincoln City");
  await expect(page.locator("#headsign-usage")).toContainText("Used by 5 trips");

  return card;
}

test("headsigns journey: prepare, review, save and undo", async ({ page }) => {
  await signInHeadsignEditor(page);
  test.setTimeout(120_000);
  await page.setViewportSize(DESKTOP);

  const card = await prepareAndReview(page);
  await expect(card).toContainText("Stop-level headsigns are not changed");
  await expect(card).not.toContainText(/saved/i);
  await capture(page, "headsigns", "prepared-1440");

  await page.setViewportSize(PHONE);
  await expect(card).toBeVisible();
  expect(await fitsViewport(page)).toBe(true);
  await capture(page, "headsigns", "prepared-390");
  await page.setViewportSize(DESKTOP);

  // The handoff seeds the native field and opens the native drawer, nothing saved.
  await card.getByRole("button", { name: "Review headsigns" }).click();
  await expect(page.locator("#pattern-details-headsign")).toHaveValue("Central Station");
  const drawer = page.locator("#headsign-review-drawer");
  await expect(drawer).toBeVisible();
  await expect(page.locator("#headsign-review-drawer-status")).toContainText("3 trips selected");
  await waitDrawerSettled(page);
  await captureViewport(page, "headsigns", "drawer-1440");

  await page.setViewportSize(PHONE);
  await waitDrawerSettled(page);
  expect(await fitsViewport(page)).toBe(true);
  await captureViewport(page, "headsigns", "drawer-390");
  await page.setViewportSize(DESKTOP);

  // The editor's own Use selection and Save write exactly the prepared set.
  await page.locator("#headsign-review-drawer-use").click();
  await expect(drawer).toHaveCount(0);
  await expect(page.locator("#headsign-update-box")).toContainText("Also update 3 trips");
  await page.locator("#pattern-details-submit").click();

  await expect(page.locator("#headsign-result")).toContainText("Headsign saved · 3 trips updated");
  await expect(card).toContainText("Applied");
  await expect(card.getByRole("button", { name: "Review headsigns" })).toHaveCount(0);
  await expect(page.locator("#agent-notice")).toHaveCount(0);
  await capture(page, "headsigns", "applied-1440");

  // Native Undo restores the original text on all three trips.
  await page.locator("#headsign-undo").click();
  await expect(page.locator("#headsign-usage")).toContainText("Used by 5 trips");
  await expect(page.locator("#headsign-usage")).toContainText("2 show a different headsign");
  await expect(page.locator("#pattern-details-headsign")).toHaveValue("Lincoln City");
});

test("headsigns journey: an edited selection leaves the card unconfirmed", async ({ page }) => {
  await signInHeadsignEditor(page);
  test.setTimeout(120_000);
  await page.setViewportSize(DESKTOP);

  const card = await prepareAndReview(page);
  await card.getByRole("button", { name: "Review headsigns" }).click();
  await expect(page.locator("#headsign-review-drawer-status")).toContainText("3 trips selected");

  // The editor adds the likely-typo trip before saving.
  await page.locator("#headsign-review-drawer-select-typos").click();
  await expect(page.locator("#headsign-review-drawer-status")).toContainText("4 trips selected");
  await page.locator("#headsign-review-drawer-use").click();
  await page.locator("#pattern-details-submit").click();

  await expect(page.locator("#headsign-result")).toContainText("Headsign saved · 4 trips updated");
  await expect(page.locator("#agent-notice")).toContainText("You changed the request before saving");
  await expect(card.getByRole("button", { name: "Review headsigns" })).toBeVisible();
  await expect(card).not.toContainText("Applied");
  await capture(page, "headsigns", "unconfirmed-1440");

  // Restore BROWSER-HS6 with the native Undo.
  await page.locator("#headsign-undo").click();
  await expect(page.locator("#headsign-usage")).toContainText("Used by 5 trips");
  await expect(page.locator("#headsign-usage")).toContainText("2 show a different headsign");
});

test("headsigns journey: the keyboard reaches the handoff and focus returns to the card", async ({
  page,
}) => {
  await signInHeadsignEditor(page);
  test.setTimeout(120_000);
  await page.setViewportSize(DESKTOP);

  const card = await prepareAndReview(page);
  const cardId = await card.getAttribute("id");

  // Activate the card's button with Enter, then close the drawer with Escape.
  await card.getByRole("button", { name: "Review headsigns" }).focus();
  await page.keyboard.press("Enter");
  await expect(page.locator("#headsign-review-drawer")).toBeVisible();
  await waitDrawerSettled(page);

  await page.keyboard.press("Escape");
  await expect(page.locator("#headsign-review-drawer")).toHaveCount(0);
  await expect.poll(() => focusedId(page)).toBe(cardId);

  // Nothing was saved: the staged field is a draft and the stored usage is unchanged.
  await expect(page.locator("#headsign-usage, #headsign-update-box").first()).toBeVisible();
  await openPattern(page, versionId, ...HS6, "details");
  await expect(page.locator("#headsign-usage")).toContainText("2 show a different headsign");
  await expect(page.locator("#pattern-details-headsign")).toHaveValue("Lincoln City");
});

// -- stop helpers ---------------------------------------------------------------

const STOPS_EDITOR = {
  email: "stops-map@gtfs-planner.test",
  password: "StopsMapBrowser1",
};

const STOPS_VERSION = "Browser Stops Map Version";

// A 1x1 transparent PNG, so the map never depends on a tile plan or the network.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

let stopsVersionId;

async function signInStopsEditor(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
  await logInAs(page, STOPS_EDITOR);
  stopsVersionId = await versionIdFor(page, STOPS_VERSION);
}

async function openStopsMap(page, query = "") {
  await page.goto(`/gtfs/${stopsVersionId}/stops/map${query}`);
  await waitForLiveView(page);
  await expect(page.locator("#stops-map-page")).toBeAttached();
}

test("stop impact panel", async ({ page }) => {
  test.setTimeout(120_000);
  await signInStopsEditor(page);

  for (const [label, viewport] of [
    ["1440", DESKTOP],
    ["390", PHONE],
  ]) {
    await page.setViewportSize(viewport);

    // No stop is open, so there is no context and no helper.
    await openStopsMap(page);
    await expect(page.locator("#stops-map-panel")).toBeAttached();
    await expect(page.locator("#agent-helper-open")).toHaveCount(0);

    // An open stop offers the helper, closed.
    await openStopsMap(page, "?stop=1434");
    await expect(page.locator("#stops-map-edit-panel")).toBeAttached();
    const open = page.locator("#agent-helper-open");
    await expect(open).toBeVisible();
    await expect(open).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator("#agent-panel")).toHaveCount(0);
    expect(await fitsViewport(page)).toBe(true);
    await capture(page, "stop-impact-panel", `closed-${label}`);

    // Opening shows first-use copy and puts focus in the composer.
    await open.click();
    const panel = page.locator("#agent-panel");
    await expect(panel).toBeVisible();
    await expect(open).toHaveAttribute("aria-expanded", "true");
    await expect(panel).toContainText("Stop impact helper");
    await expect(panel).toContainText("Stop 1434");
    await expect(panel.locator("#agent-example-1")).toBeVisible();
    expect(await focusedId(page)).toBe("agent-composer-input");
    expect(await fitsViewport(page)).toBe(true);

    // The native edit form is still usable with the helper open.
    await expect(page.locator("#stops-map-edit-name")).toBeEnabled();
    await capture(page, "stop-impact-panel", `open-${label}`);

    // Closing returns focus to the button that opened it.
    await page.locator("#agent-panel-close").click();
    await expect(panel).toHaveCount(0);
    expect(await focusedId(page)).toBe("agent-helper-open");
  }
});

// -- stop set approval -----------------------------------------------------------

// The approval section sits above a 74-row catalog, so a full-page capture buries it;
// this captures the section the case is about.
async function captureSection(page, folder, name) {
  const dir = resolve(CAPTURE_DIR, folder);
  mkdirSync(dir, { recursive: true });
  await page
    .locator("#stop-set-section")
    .screenshot({ path: resolve(dir, `${name}.png`), animations: "disabled" });
}

/** Activates a control the way a keyboard user does: focus it, then press a key. */
async function activate(locator, key = "Enter") {
  await locator.focus();
  await locator.page().keyboard.press(key);
}

// Reads BROWSER_TXT_A1..A4 on the Browser E2E version and approves a set from them,
// by keyboard. Nothing is saved: the approval lives in the page.
test("stop set approval", async ({ page }) => {
  test.setTimeout(120_000);
  await signInHeadsignEditor(page);

  for (const [label, viewport] of [
    ["1440", DESKTOP],
    ["390", PHONE],
  ]) {
    await page.setViewportSize(viewport);
    await page.goto(`/gtfs/${versionId}/stops`);
    await waitForLiveView(page);

    // Empty: the section is a single closed row and nothing is approved.
    const toggle = page.locator("#stop-set-toggle");
    await expect(toggle).toBeVisible();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator("#stop-set-summary")).toContainText("No stops approved");
    await expect(page.locator("#stop-set-form")).toHaveCount(0);
    expect(await fitsViewport(page)).toBe(true);
    await captureSection(page, "stop-set-approval", `empty-${label}`);

    await activate(toggle);
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    await expect(page.locator("#stop-set-refs")).toBeVisible();
    expect(await fitsViewport(page)).toBe(true);
    await captureSection(page, "stop-set-approval", `form-${label}`);

    // Too many lines: an inline error, the text kept, focus on the field.
    const refs = page.locator("#stop-set-refs");
    const tooMany = Array.from({ length: 101 }, (_, i) => `NOPE${i + 1}`).join("\n");
    await refs.fill(tooMany);
    await activate(page.locator("#stop-set-find"));
    await expect(refs).toHaveAttribute("aria-invalid", "true");
    await expect(page.locator("#stop-set-form")).toContainText("Enter up to 100 lines");
    await expect(refs).toHaveValue(tooMany);
    await expect.poll(() => focusedId(page)).toBe("stop-set-refs");
    expect(await fitsViewport(page)).toBe(true);
    await captureSection(page, "stop-set-approval", `too-many-${label}`);

    // Resolved: a stop ID and a code, one ambiguous name and one unmatched line.
    await refs.fill("BROWSER_TXT_A4\nTXT-77\nTxt Main St @ Elm\nNo such stop");
    await activate(page.locator("#stop-set-find"));
    const resolution = page.locator("#stop-set-resolution");
    await expect(resolution).toBeVisible();
    await expect(page.locator("#stop-set-resolution-heading")).toContainText(
      "2 stops found, 1 line needs a choice, 1 line not found",
    );
    await expect(page.locator("#stop-set-resolved li")).toHaveCount(2);
    await expect(page.locator("#stop-set-resolved")).toContainText("Matched by stop ID");
    await expect(page.locator("#stop-set-resolved")).toContainText("Matched by code");
    await expect(page.locator("#stop-set-ambiguity-0 input[type=radio]")).toHaveCount(3);
    await expect(page.locator("#stop-set-unmatched")).toContainText("No such stop");
    await expect(page.locator("#stop-set-approve")).toBeDisabled();
    await expect(page.locator("#stop-set-approve-reason")).toContainText(
      "Choose a stop or skip 1 line first.",
    );
    await expect.poll(() => focusedId(page)).toBe("stop-set-resolution-heading");
    expect(await fitsViewport(page)).toBe(true);
    await captureSection(page, "stop-set-approval", `resolved-${label}`);

    // Choosing a candidate by keyboard enables approval.
    const candidate = page.locator("#stop-set-choice-0-BROWSER_TXT_A3");
    await candidate.focus();
    await page.keyboard.press("Space");
    await expect(candidate).toBeChecked();
    await expect(page.locator("#stop-set-approve")).toBeEnabled();

    // Approved: three stops in stop ID order, focus on the summary.
    await activate(page.locator("#stop-set-approve"));
    await expect(page.locator("#stop-set-summary")).toContainText("3 stops approved");
    await expect(page.locator("#stop-set-resolution")).toHaveCount(0);
    expect(
      await page
        .locator("#stop-set-list li")
        .evaluateAll((items) => items.map((item) => item.dataset.stopId)),
    ).toEqual(["BROWSER_TXT_A1", "BROWSER_TXT_A3", "BROWSER_TXT_A4"]);
    await expect.poll(() => focusedId(page)).toBe("stop-set-summary");
    expect(await fitsViewport(page)).toBe(true);
    await captureSection(page, "stop-set-approval", `approved-${label}`);

    // Clear stops empties the set and returns focus to the section's toggle.
    await activate(page.locator("#stop-set-clear"));
    await expect(page.locator("#stop-set-summary")).toContainText("No stops approved");
    await expect(page.locator("#stop-set-list")).toHaveCount(0);
    await expect.poll(() => focusedId(page)).toBe("stop-set-toggle");
  }
});

// -- stop text panel -----------------------------------------------------------

// Opens the stop text helper on an approved set of BROWSER_TXT_A1 and A4. Nothing is
// sent to the provider and nothing is saved.
test("stop text panel", async ({ page }) => {
  test.setTimeout(120_000);
  await signInHeadsignEditor(page);

  for (const [label, viewport] of [
    ["1440", DESKTOP],
    ["390", PHONE],
  ]) {
    await page.setViewportSize(viewport);
    await page.goto(`/gtfs/${versionId}/stops`);
    await waitForLiveView(page);

    // No approved set, so no helper.
    await expect(page.locator("#agent-helper-open")).toHaveCount(0);
    await expect(page.locator("#agent-panel")).toHaveCount(0);

    await activate(page.locator("#stop-set-toggle"));
    await page.locator("#stop-set-refs").fill("BROWSER_TXT_A1\nBROWSER_TXT_A4");
    await activate(page.locator("#stop-set-find"));
    await activate(page.locator("#stop-set-approve"));
    await expect(page.locator("#stop-set-summary")).toContainText("2 stops approved");

    // An approved set offers the helper, closed.
    const open = page.locator("#agent-helper-open");
    await expect(open).toBeVisible();
    await expect(open).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator("#agent-panel")).toHaveCount(0);
    expect(await fitsViewport(page)).toBe(true);
    await page.evaluate(() => window.scrollTo(0, 0));
    await captureViewport(page, "stop-text-panel", `closed-${label}`);

    // Opening shows first-use copy and puts focus in the composer.
    await activate(open);
    const panel = page.locator("#agent-panel");
    await expect(panel).toBeVisible();
    await expect(open).toHaveAttribute("aria-expanded", "true");
    await expect(panel).toContainText("Stop text helper");
    await expect(panel).toContainText("2 approved stops");
    await expect(panel.locator("#agent-example-1")).toBeVisible();
    await expect.poll(() => focusedId(page)).toBe("agent-composer-input");
    expect(await fitsViewport(page)).toBe(true);

    // The catalog and the approval form stay usable beside the helper.
    await expect(page.locator("#stop-search-form input")).toBeEnabled();
    await expect(page.locator("#stop-set-clear")).toBeVisible();
    await page.evaluate(() => window.scrollTo(0, 0));
    await captureViewport(page, "stop-text-panel", `open-${label}`);

    // Closing returns focus to the button that opened it.
    await page.locator("#agent-panel-close").click();
    await expect(panel).toHaveCount(0);
    await expect.poll(() => focusedId(page)).toBe("agent-helper-open");

    // Clearing the set removes the helper with the context it belongs to.
    await activate(page.locator("#stop-set-clear"));
    await expect(page.locator("#agent-helper-open")).toHaveCount(0);
  }
});

// -- stop review table -----------------------------------------------------------

/** Approves `stopIds` on the Browser E2E version's stops catalog, by keyboard. */
async function approveStops(page, stopIds) {
  await page.goto(`/gtfs/${versionId}/stops`);
  await waitForLiveView(page);
  await activate(page.locator("#stop-set-toggle"));
  await page.locator("#stop-set-refs").fill(stopIds.join("\n"));
  await activate(page.locator("#stop-set-find"));
  await activate(page.locator("#stop-set-approve"));
  await expect(page.locator("#stop-set-summary")).toContainText(
    `${stopIds.length} stops approved`,
  );
}

/** Opens the helper, sends `message` and returns the prepared card's review button. */
async function prepareStopChanges(page, message) {
  await activate(page.locator("#agent-helper-open"));
  await expect(page.locator("#agent-panel")).toBeVisible();
  // The same approved set under the same editor is the same conversation across page
  // loads, so each case starts a fresh one rather than reading an earlier card.
  await page.locator("#agent-new-conversation").click();
  await expect(page.locator("#agent-composer-input")).toBeVisible();
  await ask(page, message);
  const card = await preparedCard(page);
  return card.locator('button[id^="agent-review-prepared-"]');
}

// Reviews a prepared batch of BROWSER_TXT_B1..B3 and saves nothing: a name change, a
// code change and a rename that duplicates BROWSER_TXT_A4's name.
test("stop review table", async ({ page }) => {
  test.setTimeout(120_000);
  await signInHeadsignEditor(page);

  for (const [label, viewport] of [
    ["1440", DESKTOP],
    ["390", PHONE],
  ]) {
    await page.setViewportSize(viewport);
    await approveStops(page, ["BROWSER_TXT_B1", "BROWSER_TXT_B2", "BROWSER_TXT_B3"]);

    const review = await prepareStopChanges(
      page,
      "Prepare stop changes: BROWSER_TXT_B1 stop_name=Txt Rail Depot North; " +
        "BROWSER_TXT_B2 stop_code=TXT-B2N; BROWSER_TXT_B3 stop_name=Txt Oak Court",
    );
    await expect(review).toHaveText("Review stop changes");

    // Keyboard open: the drawer shows one row per changed field with both values.
    const card = page.locator('section[id^="agent-prepared-"]');
    const cardId = await card.getAttribute("id");
    await activate(review);
    const drawer = page.locator("#stop-review");
    await expect(drawer).toBeVisible();
    await waitDrawerSettled(page, "stop-review");

    const table = page.locator("#stop-review-table");
    await expect(table).toBeVisible();
    await expect(table.locator("tbody tr").filter({ has: page.locator('td[data-label="Field"]') })).toHaveCount(3);
    await expect(table).toContainText("Txt Rail Depot");
    await expect(table).toContainText("Txt Rail Depot North");
    await expect(table).toContainText("TXT-B2N");

    // The duplicate name is a warning that names the other stop, not an error.
    await expect(page.locator("#stop-review-warnings")).toContainText("BROWSER_TXT_B3");
    await expect(page.locator("#stop-review-warnings")).toContainText("BROWSER_TXT_A4");
    await expect(page.locator("#stop-review-invalid")).toHaveCount(0);
    expect(await fitsViewport(page)).toBe(true);

    if (label === "390") {
      // Stacked at phone width: the column headers are hidden and every cell is labelled.
      await expect(table.locator("thead")).toHaveCSS("position", "absolute");
      await expect(table.locator('td[data-label="Current"]').first()).toBeVisible();
    } else {
      await expect(table.locator("thead")).toBeVisible();
    }

    await captureViewport(page, "stop-review-table", `review-${label}`);

    // Escape closes the drawer and returns focus to the prepared card.
    await page.keyboard.press("Escape");
    await expect(drawer).toHaveCount(0);
    await expect.poll(() => focusedId(page)).toBe(cardId);
  }
});

// -- stop review save ------------------------------------------------------------

// Saves reviewed batches of BROWSER_TXT_C1..C3, the only stops any case writes. The
// 1440 pass first stages a stale review: a second page renames C2 through the native
// map editor after the review opened, so the first Save is refused, the drawer shows
// that stop's current name, and the second Save writes.
test("stop review save", async ({ page }) => {
  test.setTimeout(180_000);
  await signInHeadsignEditor(page);
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );

  for (const [label, viewport] of [
    ["1440", DESKTOP],
    ["390", PHONE],
  ]) {
    await page.setViewportSize(viewport);
    await approveStops(page, ["BROWSER_TXT_C1", "BROWSER_TXT_C2", "BROWSER_TXT_C3"]);

    const changes =
      label === "1440"
        ? `BROWSER_TXT_C1 stop_name=Txt Harbor Gate ${label}; BROWSER_TXT_C2 stop_name=Txt Quarry Road ${label}`
        : `BROWSER_TXT_C1 stop_name=Txt Harbor Gate ${label}; BROWSER_TXT_C3 stop_code=TXT-C3-${label}`;
    const review = await prepareStopChanges(page, `Prepare stop changes: ${changes}`);
    const card = page.locator('section[id^="agent-prepared-"]');
    await activate(review);
    await expect(page.locator("#stop-review")).toBeVisible();
    await waitDrawerSettled(page, "stop-review");

    const save = page.locator("#stop-review-save");
    await expect(save).toHaveText("Save stop changes");
    await expect(save).toBeEnabled();
    await expect(save).toHaveAttribute("phx-disable-with", "Saving…");
    expect(await fitsViewport(page)).toBe(true);

    if (label === "1440") {
      // Another session renames C2 after the review opened.
      const other = await page.context().newPage();
      await other.route("**/map/tiles/**", (route) =>
        route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
      );
      await other.goto(`/gtfs/${versionId}/stops/map?stop=BROWSER_TXT_C2`);
      await waitForLiveView(other);
      await expect(other.locator("#stops-map-edit-panel")).toBeAttached();
      await other.locator("#stops-map-edit-name").fill("Txt Quarry Rd");
      await other.locator("#stops-map-edit-save").click();
      await expect(other.locator("#stops-map-edit-status")).toHaveText("No changes yet");
      await other.close();

      await activate(save);
      await expect(page.locator("#stop-review-notice")).toContainText(
        "changed since you reviewed them",
      );
      await expect(page.locator("#stop-review-table")).toContainText("Txt Quarry Rd");
      await expect(page.locator("#stop-review")).toBeVisible();
      expect(await fitsViewport(page)).toBe(true);
      await captureViewport(page, "stop-review-save", `stale-${label}`);
    } else {
      await captureViewport(page, "stop-review-save", `review-${label}`);
    }

    await activate(save);
    await expect(page.locator("#stop-review")).toHaveCount(0);
    await expect(page.locator("#flash-info")).toContainText(/Saved \d stops?/);
    await expect(card).toContainText("Applied");
    await expect(page.locator("#agent-notice")).toHaveCount(0);

    // The catalog and the approved list show the saved names.
    await expect(page.locator(`#stop-set-list li[data-stop-id="BROWSER_TXT_C1"]`)).toContainText(
      `Txt Harbor Gate ${label}`,
    );
    await page.locator("#stop-search-form input").fill(`Txt Harbor Gate ${label}`);
    await expect(page.locator("#stops-count")).toContainText("1 stop or station matches");
    expect(await fitsViewport(page)).toBe(true);
    await page.evaluate(() => window.scrollTo(0, 0));
    await captureViewport(page, "stop-review-save", `saved-${label}`);
  }
});

// -- stops journey: impact ---------------------------------------------------------

// The street-routing stand-in appends one line per request to a log named by the run's
// port (`GtfsPlanner.BrowserStreetRouting.request_log_path/0`), so a journey can show
// that the helper's answer routed nothing and the native review routed.
function routingRequests() {
  const port = process.env.PLAYWRIGHT_PORT || "4002";
  try {
    const log = readFileSync(resolve(tmpdir(), `gtfs-planner-street-routing-${port}.log`), "utf8");
    return log.split("\n").filter(Boolean).length;
  } catch {
    return 0;
  }
}

// Reads stop 1434, previews a move to a pin typed 13.7 m north, prepares the pointer on
// an explicit request and opens the native move review from the card, saving nothing.
test("stops journey: impact", async ({ page }) => {
  test.setTimeout(240_000);
  await signInStopsEditor(page);

  for (const [label, viewport] of [
    ["1440", DESKTOP],
    ["390", PHONE],
  ]) {
    await page.setViewportSize(viewport);
    await openStopsMap(page, "?stop=1434");
    await expect(page.locator("#stops-map-edit-panel")).toBeAttached();
    const savedLat = await page.locator("#stops-map-edit-lat").inputValue();
    const savedLon = await page.locator("#stops-map-edit-lon").inputValue();
    const routedBefore = routingRequests();

    // The pin is typed, not dragged: 13.7 m north of the saved point.
    await page.locator("#stops-map-edit-lat").fill("44.635733");
    await expect(page.locator("#stops-map-edit-moved")).toContainText(/Moved \d+ ft/);

    // Keyboard path: the helper button, then the composer.
    await activate(page.locator("#agent-helper-open"));
    await expect(page.locator("#agent-panel")).toBeVisible();
    await page.locator("#agent-new-conversation").click();
    await expect(page.locator("#agent-composer-input")).toBeVisible();
    await ask(page, "What would moving this stop affect?");

    // The answer: the server's cards, and the reply built from what the tools returned.
    const entries = page.locator("#agent-entries");
    await expect(entries).toContainText("Moving this stop 13.7 m is a review move.", {
      timeout: 20000,
    });
    await expect(entries).toContainText(
      "Patterns: 1 · Lincoln City (0 weekday trips); 3 · Nye Beach (0 weekday trips).",
    );
    await expect(entries).toContainText(
      "Transfers: Newport Transit Center, Bay B 111.9 m before and 125.5 m after.",
    );
    await expect(entries).toContainText("Relief points: Relief at 1434.");
    await expect(entries).toContainText("The street path is decided by the native move review");
    await expect(page.locator('[id^="agent-evidence-"]')).toHaveCount(2);
    await expect(entries).toContainText("Distance");
    await expect(entries).toContainText("13.7 m");
    await expect(entries.locator(`a[href="/gtfs/${stopsVersionId}/stops/1434"]`).first()).toBeVisible();

    // Reading and previewing routed nothing.
    expect(routingRequests()).toBe(routedBefore);
    expect(await fitsViewport(page)).toBe(true);
    await page.locator("#agent-panel").scrollIntoViewIfNeeded();
    await entries.getByText(/Relief points: Relief at 1434\./).scrollIntoViewIfNeeded();
    await captureViewport(page, "stops-impact-journey", `answer-${label}`);

    // Only the explicit request prepares the pointer.
    await ask(page, "Keep the stop's ID and prepare the move.");
    const card = await preparedCard(page);
    const cardId = await card.getAttribute("id");
    const review = card.locator('button[id^="agent-review-prepared-"]');
    await expect(review).toHaveText("Review move");
    expect(routingRequests()).toBe(routedBefore);

    // Review move opens the native panel, whose own routing request is the only one.
    await activate(review);
    await expect(page.locator("#stops-map-move-panel")).toBeAttached();
    await expect(page.locator("#stops-map-move-heading")).toHaveText("Review move");
    await expect(page.locator("#stops-map-move-patterns li")).not.toHaveCount(0);
    await expect.poll(routingRequests).toBe(routedBefore + 1);
    expect(await fitsViewport(page)).toBe(true);
    await page.locator("#stops-map-move-panel").scrollIntoViewIfNeeded();
    await captureViewport(page, "stops-impact-journey", `native-review-${label}`);

    // Back to editing returns focus to the card; nothing was saved.
    await activate(page.locator("#stops-map-move-back"));
    await expect(page.locator("#stops-map-move-panel")).toHaveCount(0);
    await expect.poll(() => focusedId(page)).toBe(cardId);

    // Moving the pin starts a new conversation and leaves no stale card.
    await page.locator("#stops-map-edit-lat").fill("44.635800");
    await expect(page.locator("#agent-notice")).toContainText(
      "The pin moved, so the helper started a new conversation.",
    );
    await expect(page.locator('[id^="agent-prepared-"]')).toHaveCount(0);

    // The stop is where it was: a fresh load shows the saved point.
    await openStopsMap(page, "?stop=1434");
    await expect(page.locator("#stops-map-edit-lat")).toHaveValue(savedLat);
    await expect(page.locator("#stops-map-edit-lon")).toHaveValue(savedLon);
  }
});

// -- stops journey: text -----------------------------------------------------------

// The stop text helper from approval to a saved batch, by keyboard: the approval form
// resolves a stop ID, a code and an ambiguous name (settled by choosing a candidate),
// the helper prepares a naming convention for the two directional twins, and the review
// and save write it. The only stops written are BROWSER_TXT_D1 and D2; the ambiguous
// name's candidates, BROWSER_TXT_A2 and A3, are read and never changed.
test("stops journey: text", async ({ page }) => {
  test.setTimeout(240_000);
  await signInHeadsignEditor(page);

  for (const [label, viewport] of [
    ["1440", DESKTOP],
    ["390", PHONE],
  ]) {
    await page.setViewportSize(viewport);
    await page.goto(`/gtfs/${versionId}/stops`);
    await waitForLiveView(page);

    // Approval: a stop ID, a code and a name two stops share.
    await activate(page.locator("#stop-set-toggle"));
    await page
      .locator("#stop-set-refs")
      .fill("BROWSER_TXT_D1\nBROWSER_TXT_D2\nTXT-D3\nTxt Main St @ Elm");
    await activate(page.locator("#stop-set-find"));
    await expect(page.locator("#stop-set-resolution-heading")).toContainText(
      "3 stops found, 1 line needs a choice",
    );
    await expect(page.locator("#stop-set-resolved")).toContainText("Matched by code: TXT-D3");
    await expect(page.locator("#stop-set-approve")).toBeDisabled();
    const candidate = page.locator("#stop-set-choice-0-BROWSER_TXT_A3");
    await candidate.focus();
    await page.keyboard.press("Space");
    await expect(candidate).toBeChecked();
    await activate(page.locator("#stop-set-approve"));
    await expect(page.locator("#stop-set-summary")).toContainText("4 stops approved");

    // The helper opens with the approved count in its scope line.
    await activate(page.locator("#agent-helper-open"));
    await expect(page.locator("#agent-panel")).toContainText("4 approved stops");
    await page.locator("#agent-new-conversation").click();
    await expect(page.locator("#agent-composer-input")).toBeVisible();

    const twin = (side) =>
      `Txt Main Street @ Elm ${side}${label === "390" ? " (390)" : ""}`;
    await ask(
      page,
      `Prepare stop changes: BROWSER_TXT_D1 stop_name=${twin("EB")}; BROWSER_TXT_D2 stop_name=${twin("WB")}`,
    );
    const card = await preparedCard(page);
    const cardId = await card.getAttribute("id");
    // The reply says prepared and never saved; the card's own "Nothing is saved" is not it.
    const reply = page.locator("#agent-entries").getByText("I prepared the stop changes");
    await expect(reply).toBeVisible();
    await expect(reply).not.toContainText(/saved/i);
    await expect(
      page.locator(`#agent-entries a[href="/gtfs/${versionId}/stops/BROWSER_TXT_D1"]`).first(),
    ).toBeVisible();
    expect(await fitsViewport(page)).toBe(true);

    // Review: both renames with their stored current names.
    const review = card.locator('button[id^="agent-review-prepared-"]');
    await expect(review).toHaveText("Review stop changes");
    await activate(review);
    const drawer = page.locator("#stop-review");
    await expect(drawer).toBeVisible();
    await waitDrawerSettled(page, "stop-review");
    const table = page.locator("#stop-review-table");
    await expect(
      table.locator("tbody tr").filter({ has: page.locator('td[data-label="Field"]') }),
    ).toHaveCount(2);
    await expect(table).toContainText("BROWSER_TXT_D1");
    await expect(table).toContainText(twin("EB"));
    await expect(table).toContainText(twin("WB"));
    await expect(page.locator("#stop-review-invalid")).toHaveCount(0);
    expect(await fitsViewport(page)).toBe(true);
    await captureViewport(page, "stops-text-journey", `review-${label}`);

    // Save: the drawer closes, the catalog shows the new names and the card is applied.
    await activate(page.locator("#stop-review-save"));
    await expect(drawer).toHaveCount(0);
    await expect(page.locator("#flash-info")).toContainText("Saved 2 stops");
    await expect(card).toContainText("Applied");
    await expect(page.locator("#agent-notice")).toHaveCount(0);
    await expect.poll(() => focusedId(page)).toBe(cardId);

    await page.locator("#stop-search-form input").fill(twin("EB"));
    await expect(page.locator("#stops-count")).toContainText("1 stop or station matches");
    await expect(page.locator("#stops")).toContainText(twin("EB"));
    expect(await fitsViewport(page)).toBe(true);
    await page.evaluate(() => window.scrollTo(0, 0));
    await captureViewport(page, "stops-text-journey", `saved-${label}`);
  }
});
