// Blocks/Runs helper browser journey (EV-8, step 8).
//
// This spec drives the operations helper the way an editor does: it opens the
// helper from a real Blocks or Runs page, asks the questions a person would ask,
// and follows the prepared card into the page's own native drawer. Nothing here
// calls a pack directly or reads an assign: every assertion is made against the
// rendered surface after a real turn, through the production composition, with
// only the external provider stubbed (`test/support/agents/browser_open_router.ex`).
//
// Two facts about this journey are load-bearing and were established by running
// it, not assumed:
//
// 1. The helper's tools take an OPTIONAL `day_ref`. The ref is an opaque
//    server-generated digest (`"day_" <> sha256(section, day_key)`) that a model
//    can neither derive from the conversation nor retype, so the browser
//    stand-in deliberately sends its operations calls with NO `day_ref` at all.
//    That is what proves a real model can reach the first tool call; the ExUnit
//    cases cannot, because they read the ref out of the snapshot in test code.
//    The stand-in also has a foreign-ref branch, and the journeys assert the
//    refusal is unchanged for a ref that IS supplied.
//
// 2. The helper is available only for a day whose whole serialized context fits
//    the shared owner's 64 KiB admission cap. Of the seeded browser versions,
//    "Browser In-Seat Version" projects to 23,430 bytes and is admitted;
//    "Browser Blocks Version" (34 blocks, 204 trips) projects to 78,121 bytes
//    and is refused whole. Both are asserted here, because the refusal is the
//    product behaving correctly rather than a gap: an unadmitted day yields the
//    native page unchanged and says so. The journeys therefore use the in-seat
//    version, which is also the day that carries the `in_seat_stale` findings
//    this package's projection work is about.
//
// Layout is measured with bounding boxes and `bodyFitsViewport`, and captures are
// written at both required viewports, 1440x900 and 390x844.
import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import { copyFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

// Captures are copied here when the directory is named, so a run on another
// machine or in CI writes nothing outside its own results.
const EVIDENCE_DIR = process.env.OPERATIONS_HELPER_CAPTURE_DIR
  ? resolve(process.cwd(), process.env.OPERATIONS_HELPER_CAPTURE_DIR)
  : null;

// The seeded editor, who owns both helper journeys. The password is the one the
// browser seed already creates for this journey; nothing new is seeded here.
const EDITOR_EMAIL = "diagram-test@gtfs-planner.test";

const EDITOR_USER = {
  email: EDITOR_EMAIL,
  password: readEditorPassword(),
};

// The admitted day: 15 blocks, 36 trips, 23,430 bytes as seeded.
const IN_SEAT_VERSION = "Browser In-Seat Version";
// The over-cap day: 34 blocks, 204 trips, 78,121 bytes, refused whole.
const OVER_CAP_VERSION = "Browser Blocks Version";

function readEditorPassword() {
  const seed = readFileSync(resolve(REPO_ROOT, "test/support/browser_seed.exs"), "utf8");
  const lines = seed.split("\n");
  const at = lines.findIndex(
    (line) => line.includes(EDITOR_EMAIL) && !line.trim().startsWith("#"),
  );
  if (at < 0) throw new Error(`the browser seed no longer creates ${EDITOR_EMAIL}`);

  const password = lines
    .slice(at, at + 4)
    .join("\n")
    .match(/password:\s*"([^"]+)"/);

  if (!password) throw new Error("the seeded editor has no password to read");
  return password[1];
}

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.waitForSelector("[data-phx-main].phx-connected");
  await page.fill('input[name="user[email]"]', EDITOR_USER.email);
  await page.fill('input[name="user[password]"]', EDITOR_USER.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function versionIdFor(page, versionName) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

// The blocks page the helper reads, opened on the admitted day.
async function openBlocks(page, versionName = IN_SEAT_VERSION) {
  await logIn(page);
  const versionId = await versionIdFor(page, versionName);
  await page.goto(`/gtfs/${versionId}/blocks`);
  await page.waitForSelector("#blocks-summary, #blocks-timeline, #blocks-empty", {
    timeout: 30000,
  });
  return versionId;
}

async function openRuns(page) {
  await logIn(page);
  const versionId = await versionIdFor(page, IN_SEAT_VERSION);
  await page.goto(`/gtfs/${versionId}/runs`);
  await page.waitForSelector("#runs-scope-counts, #runs-empty, #runs-unavailable", {
    timeout: 30000,
  });
  return versionId;
}

// The helper's own control lives below the fold on a wide viewport, so it is
// scrolled to rather than forced: a forced click would prove nothing about
// whether the editor can actually reach it.
//
// A conversation is server-held and outlives a page load, so every journey
// starts a new one. Without this, one journey's turns are still on the page
// when the next opens the panel, and `last()` would be answering a stale
// transcript instead of this journey's question.
async function openHelper(page) {
  const opener = page.locator("#agent-helper-open");
  await opener.scrollIntoViewIfNeeded();
  await opener.click();
  await expect(page.locator("#agent-panel")).toBeVisible();

  // The panel's hook focuses the composer on mount, and the opener click above
  // mounts it, so the composer is focused here. The reset below does not
  // remount the panel, so the hook does not run again and the composer is left
  // inactive: journeys that assert focus do so before this reset, because that
  // is the only point the panel's own focus contract is observable.
  await expect(page.locator("#agent-composer-input")).toBeFocused();

  await page.locator("#agent-new-conversation").click();
}

// A second editor changing the day under a frozen configuration is what the
// stale refusal answers. The crew rules are the day's own constraints, so saving
// a different pull-out report from a second tab moves the day the first tab's
// card was prepared from without navigating that tab. The value is set relative
// to whatever it is now, so the journey does not depend on any other spec's
// state, and the caller puts it back.
async function setPullOutMinutes(browser, pick) {
  const other = await browser.newPage();
  try {
    await other.setViewportSize({ width: 1440, height: 900 });
    await openRuns(other);
    await other.locator("#runs-crew-rules-button").click();
    await expect(
      other.locator('#runs-crew-rules-drawer-overlay[data-open="true"]'),
    ).toBeVisible();

    const field = other.locator("#crew-report_pull_out_minutes");
    const before = await field.inputValue();
    await field.fill(String(pick(Number(before))));
    await other.locator("#crew-rules-save").click();
    await expect(
      other.locator("#runs-crew-rules-drawer-overlay"),
    ).toHaveAttribute("data-open", "false", { timeout: 30000 });

    return before;
  } finally {
    await other.close();
  }
}

// The prepared card's own review control lives inside the panel's scrolling
// transcript, so it can sit below the fold even when the page itself does not
// scroll. It is scrolled inside that container rather than clicked blindly, and
// the wait is for the drawer it opens rather than for a fixed delay, because a
// click that never lands would time out on a control the editor can reach.
async function openPreparedReview(page) {
  const review = page.locator('[id^="agent-review-prepared-"]').last();
  await review.scrollIntoViewIfNeeded();
  await review.click();
}

// A real turn through the panel: type, send, and wait for the domain's own
// answer rather than for a fixed delay.
//
// The panel's own body scrolls, so at a short viewport the send control sits
// below the visible area of that scroller even though it is on the page. It is
// scrolled into view inside its container rather than clicked blindly, because a
// click that never lands would time out on a control the editor can reach.
async function ask(page, question) {
  await page.fill("#agent-composer-input", question);

  const send = page.locator("#agent-send");
  await send.scrollIntoViewIfNeeded();
  await send.click();

  await expect(page.locator("#agent-entries article").last()).toBeVisible({
    timeout: 30000,
  });
  await expect(send).toBeEnabled({ timeout: 30000 });
}

function copyShot(source, name) {
  if (!EVIDENCE_DIR) return;
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  copyFileSync(source, resolve(EVIDENCE_DIR, `${name}.png`));
}

test.describe("operations helper: reading a day", () => {
  test("a real model turn reaches the first tool call with no day_ref", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openBlocks(page);
    await openHelper(page);

    // The panel offers the editor a way in before any question is asked.
    await expect(page.locator("#agent-panel")).toContainText("Blocks");

    await ask(page, "What is wrong with this day's blocks?");

    // The stand-in sent `get_blocking_issues` with no `day_ref`, so the day the
    // server attached is the one that answered. The card is the answer: its
    // count comes from the domain, not from the model's sentence.
    const evidence = page.locator("#agent-entries article").last();
    await expect(evidence).toContainText("Blocking issues");
    await expect(evidence).toContainText(/\d+ issue instances/);
    await expect(evidence).toContainText("Complete");

    // The frozen day's own findings, named by the codes the tool returned.
    await expect(evidence).toContainText("overlap");

    // The turn really used the tool rather than falling back to the generic
    // sentence the stand-in gives anything it does not script.
    await expect(evidence).not.toContainText(
      "I can answer questions about calendars",
    );
    await expect(evidence).toContainText("View activity");

    await expect(await bodyFitsViewport(page)).toBe(true);

    const shot = testInfo.outputPath("blocks-issues-1440.png");
    await page.screenshot({ path: shot, animations: "disabled" });
    copyShot(shot, "blocks-issues-1440");
  });

  test("the crew-rules branch reads the attached day too", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openRuns(page);
    await openHelper(page);

    await ask(page, "What are we judging these runs against?");

    const entry = page.locator("#agent-entries article").last();
    await expect(entry).toContainText("pull-out");
    await expect(entry).not.toContainText(
      "I can answer questions about calendars",
    );
  });

  test("a day_ref that disagrees with the attached day is still refused", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openBlocks(page);
    await openHelper(page);

    // The stand-in answers this question with a foreign `day_ref`, so the
    // refusal comes from the pack's own fence rather than from the stub.
    await ask(page, "What is wrong with yesterday's blocks?");

    const entry = page.locator("#agent-entries article").last();
    await expect(entry).toContainText(
      "That day is not the day attached to this conversation.",
    );

    // A refused call is not a silent success: no evidence card follows it.
    await expect(page.locator("#agent-entries article").last()).not.toContainText(
      "issue instances",
    );
  });
});

test.describe("operations helper: configuring without starting", () => {
  test("preparing a scope builds nothing and starts no job", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openBlocks(page);
    await openHelper(page);

    await ask(page, "Prepare a change to the unassigned trips.");

    // The prepared card names a configuration, not a change: nothing is built
    // and nothing is saved, and the review discloses the day and the scope.
    const prepared = page.locator('#agent-entries [id^="agent-prepared-"]');
    await expect(prepared).toHaveCount(1);
    await expect(prepared).toContainText("Nothing is suggested or saved yet");
    await expect(page.locator("#agent-composer-hint")).toContainText(
      "Start suggestions in the native drawer",
    );

    // The review the page builds beside its drawer is not on the page until
    // the configuration is opened, so the journey opens it the way an editor
    // does. Before that, only the drawer is closed.
    await expect(page.locator("#suggest-drawer-overlay")).toHaveAttribute(
      "data-open",
      "false",
    );
    await openPreparedReview(page);

    // The review is on the page now, and it discloses the day and the scope.
    await expect(page.locator("#blocks-helper-scope-details")).toBeVisible();
    await expect(page.locator("#blocks-helper-scope-details")).toContainText(
      "Service day",
    );
    await expect(page.locator("#blocks-helper-scope-details")).toContainText(
      "Scope",
    );

    const shot = testInfo.outputPath("blocks-prepared-1440.png");
    await page.screenshot({ path: shot, animations: "disabled" });
    copyShot(shot, "blocks-prepared-1440");
  });

  test("a scope that replaces the day warns before it is offered", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openBlocks(page);
    await openHelper(page);

    await ask(page, "Prepare a full rebuild of the whole day.");
    await expect(page.locator('#agent-entries [id^="agent-prepared-"]')).toHaveCount(1);

    // The review the page builds beside its drawer is not on the page until the
    // configuration is opened, so the journey opens it the way an editor does.
    await openPreparedReview(page);

    // The one scope that plans every trip again says so in the review, because
    // hand-tuned blocks may change and applying asks for a confirmation.
    const review = page.locator("#blocks-helper-scope-details");
    await expect(review).toBeVisible();
    await expect(review).toContainText("may change");
  });
});

test.describe("operations helper: handing off to the native drawer", () => {
  test("Preview builds a plan, Apply is the only write, and both are reachable", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openBlocks(page);
    await openHelper(page);

    await ask(page, "Prepare a change to the unassigned trips.");
    await expect(page.locator('#agent-entries [id^="agent-prepared-"]')).toHaveCount(1);

    // The prepared card hands its configuration to the page's own drawer.
    await openPreparedReview(page);

    // The page's own drawer is the surface the configuration is opened in, so
    // the editor can reach Preview and Apply through the same handoff.
    const drawer = page.locator("#suggest-drawer-overlay");
    await expect(drawer).toHaveAttribute("data-open", "true");
    await expect(page.locator("#suggest-drawer")).toContainText("Suggest blocks");

    // The drawer opened on the prepared scope, not the page's own default, and
    // only Preview is offered: opening a configuration started nothing.
    await expect(page.locator("#suggest-scope-unassigned_only")).toBeChecked();
    await expect(page.locator("#suggest-scope-replace_all")).not.toBeChecked();
    await expect(page.locator("#suggest-preview")).toBeEnabled();

    // No plan yet, so Apply is not a control the editor can reach.
    await expect(page.locator("#apply-suggestion")).toHaveCount(0);

    const openShot = testInfo.outputPath("blocks-drawer-open-1440.png");
    await page.screenshot({ path: openShot, animations: "disabled" });
    copyShot(openShot, "blocks-drawer-open-1440");

    // Preview builds the plan and stores it. It writes nothing.
    await page.locator("#suggest-preview").click();
    await expect(page.locator("#apply-suggestion")).toBeVisible({ timeout: 30000 });

    // The plan is on the page and it is the native drawer's own, not the
    // helper's: the helper offered configuration, the drawer does the work.
    // Completing a plan is an authoritative change, so the page republishes the
    // helper's context and the panel starts a fresh conversation about the day
    // as it now stands.
    await expect(page.locator("#suggest-drawer")).toContainText("block");
    await expect(page.locator("#agent-entries")).toContainText(
      "What needs to change?",
    );

    const previewShot = testInfo.outputPath("blocks-preview-1440.png");
    await page.screenshot({ path: previewShot, animations: "disabled" });
    copyShot(previewShot, "blocks-preview-1440");
  });

  test("the Runs drawer opens on its own prepared scope", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openRuns(page);
    await openHelper(page);

    await ask(page, "Prepare a rebuild of this day's runs.");
    await expect(page.locator('#agent-entries [id^="agent-prepared-"]')).toHaveCount(1);

    await openPreparedReview(page);

    const drawer = page.locator("#runs-suggest-drawer-overlay");
    await expect(drawer).toHaveAttribute("data-open", "true");
    await expect(page.locator("#runs-preview")).toBeVisible();
  });
});

test.describe("operations helper: a stale configuration is refused", () => {
  test("crew rules changed in another tab refuse the old prepared card and say why", async ({
    page,
    browser,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openRuns(page);
    await openHelper(page);

    await ask(page, "Prepare a rebuild of this day's runs.");
    await expect(page.locator('#agent-entries [id^="agent-prepared-"]')).toHaveCount(1);

    // A second editor changes the day this configuration was frozen from.
    // Nothing in the first tab navigated, so the card is still on screen and
    // the socket's assigns still describe the old day, which is exactly why
    // the handoff re-reads the day rather than trusting the assigns.
    const original = await setPullOutMinutes(browser, (minutes) => (minutes + 1) % 31);

    try {
      // Opening the old card is what the refusal answers: the page re-reads the
      // day and finds the configuration was prepared from a different one.
      await openPreparedReview(page);

      // The refusal names its own next action rather than failing silently or
      // opening a wrong drawer.
      await expect(page.locator("#runs-helper-notice")).toBeVisible({
        timeout: 30000,
      });
      await expect(page.locator("#runs-helper-notice")).toContainText(
        "Open the Suggest runs drawer and ask again",
      );
      await expect(page.locator("#runs-suggest-drawer-overlay")).toHaveAttribute(
        "data-open",
        "false",
      );
    } finally {
      await setPullOutMinutes(browser, () => original);
    }
  });
});

test.describe("operations helper: an unadmitted day is refused, not faked", () => {
  test("a day over the admission cap leaves the page unchanged and says so", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openBlocks(page, OVER_CAP_VERSION);

    // The over-cap day is refused whole. The page still opens its native
    // surface, and the helper says why it has no evidence rather than
    // answering from a truncated summary of the same day.
    await openHelper(page);
    await expect(page.locator("#blocks-helper-notice")).toContainText(
      "could not read this service day",
    );
    await expect(page.locator("#blocks-helper-notice")).toContainText(
      "Your blocks are unchanged",
    );

    // A refused day offers no review to approve: there is nothing prepared.
    await expect(page.locator("#blocks-helper-scope-details")).toHaveCount(0);
    await expect(page.locator('#agent-entries [id^="agent-prepared-"]')).toHaveCount(0);

    // And the native surface is untouched, so the editor can still work.
    await expect(page.locator("#blocks-suggest")).toBeVisible();
    await expect(await bodyFitsViewport(page)).toBe(true);

    const shot = testInfo.outputPath("blocks-over-cap-1440.png");
    await page.screenshot({ path: shot, animations: "disabled" });
    copyShot(shot, "blocks-over-cap-1440");
  });
});

test.describe("operations helper: layout and keyboard at 390x844", () => {
  test("the helper fits the narrow viewport and keeps its focus order", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await openBlocks(page);
    await openHelper(page);

    // Nothing overflows horizontally at the narrow width.
    await expect(await bodyFitsViewport(page)).toBe(true);

    // Closing the helper returns focus to the control that opened it, so the
    // editor is not dropped at the top of the document.
    await page.locator("#agent-panel-close").click();
    await expect(page.locator("#agent-helper-open")).toBeFocused();
    await expect(page.locator("#agent-panel")).toHaveCount(0);

    // Reopening restores the panel and its focus.
    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();
    await expect(page.locator("#agent-composer-input")).toBeFocused();
    await expect(await bodyFitsViewport(page)).toBe(true);

    // The same question answers at the narrow width, so the helper is not a
    // desktop-only surface.
    await ask(page, "What is wrong with this day's blocks?");
    await expect(page.locator("#agent-entries article").last()).toContainText(
      "issue instances",
    );
    await expect(await bodyFitsViewport(page)).toBe(true);

    const shot = testInfo.outputPath("blocks-issues-390.png");
    await page.screenshot({ path: shot, animations: "disabled" });
    copyShot(shot, "blocks-issues-390");
  });

  test("the Runs helper fits the narrow viewport", async ({ page }, testInfo) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await openRuns(page);
    await openHelper(page);

    await ask(page, "What is wrong with this day's runs?");
    await expect(page.locator("#agent-entries article").last()).toContainText(
      "run",
    );
    await expect(await bodyFitsViewport(page)).toBe(true);

    const shot = testInfo.outputPath("runs-issues-390.png");
    await page.screenshot({ path: shot, animations: "disabled" });
    copyShot(shot, "runs-issues-390");
  });
});

test.describe("operations helper: one panel, two helpers", () => {
  test("the mode switch moves the Blocks page's one panel between its helpers", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openBlocks(page);
    await openHelper(page);

    const blocksMode = page.locator("#blocks-helper-mode-blocks");
    const inSeatMode = page.locator("#blocks-helper-mode-in_seat");
    const panel = page.locator("#agent-panel");

    await expect(blocksMode).toHaveAttribute("aria-pressed", "true");
    await expect(panel).toContainText("Blocks helper");

    // The in-seat helper reads connections chosen in the Connections view, so
    // with none chosen the page says where to choose them.
    await inSeatMode.click();
    await expect(inSeatMode).toHaveAttribute("aria-pressed", "true");
    await expect(panel).toHaveCount(1);
    await expect(panel).toContainText("In-seat helper");
    await expect(page.locator("#blocks-helper-in-seat-note")).toBeVisible();

    // The page's own controls are untouched by the switch.
    await expect(page.locator("#blocks-suggest")).toBeVisible();

    await blocksMode.click();
    await expect(blocksMode).toHaveAttribute("aria-pressed", "true");
    await expect(panel).toHaveCount(1);
    await expect(panel).toContainText("Blocks helper");
    await expect(page.locator("#blocks-helper-in-seat-note")).toHaveCount(0);
    await expect(await bodyFitsViewport(page)).toBe(true);
  });
});
