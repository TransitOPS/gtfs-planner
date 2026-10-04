import { test, expect } from "@playwright/test";
import { logInAs } from "./browser_helpers";
import { mkdirSync } from "node:fs";
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
  "/Users/ryanmahoney/Documents/gtfs-planner/.specs/ai-02-rider-text-and-stop-review/evidence/screenshots";

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
