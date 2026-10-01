import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";

// The Alerts list, as spec 30's step 13 renders it: the four tabs with their
// counts, the table, and the first-use panel an organization with no alerts
// gets (AC-14). Nothing here looks for a publication state or action, because
// saving an alert never publishes one in this package (R2, CR-1).

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// The browser journey signs in as the editor seeded by
// test/support/browser_seed.exs, whose organization also carries a Pathways
// Studio editor and no alerts of its own: the first-use panel's own subject.
const EMPTY_EDITOR = {
  email: "pathways-editor@gtfs-planner.test",
  password: "PathwaysEditor123!",
};

const ALERTS_VERSION = "Browser Alerts Version";

// The canonical feature package (with its reference and evidence folder) lives
// in the primary repository checkout; the `.specs/` workspace is gitignored, so
// a checkout without it falls back to Playwright's own output folder instead of
// writing outside the project.
const FEATURE_DIR =
  process.env.ALERTS_FEATURE_DIR ||
  "/Users/ryanmahoney/Documents/gtfs-planner/.specs/30-service-alerts";
const EVIDENCE_DIR = path.join(FEATURE_DIR, "evidence/captures/production");
const REFERENCE_PATH = path.join(FEATURE_DIR, "references/alerts-prototype.html");

const DESKTOP = { label: "1440", width: 1440, height: 900 };
const NARROW = { label: "320", width: 320, height: 740 };

function capturePath(testInfo, name) {
  return fs.existsSync(EVIDENCE_DIR)
    ? path.join(EVIDENCE_DIR, name)
    : testInfo.outputPath(name);
}

async function logIn(page, account = EDITOR) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', account.email);
  await page.fill('input[name="user[password]"]', account.password);
  await page.getByRole("button", { name: "Log in" }).click();
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

async function openAlerts(page, account = EDITOR) {
  await logIn(page, account);
  const versionId = await versionIdFor(page, ALERTS_VERSION);
  await page.goto(`/gtfs/${versionId}/alerts`);
  await page.waitForSelector(
    "#alerts-first-use, #alerts-list, #alerts-tab-empty-current",
    { timeout: 15000 },
  );
  return versionId;
}

async function openFirstUseAlerts(page) {
  await logIn(page, EMPTY_EDITOR);
  const versionId = await versionIdFor(page, "Browser Pathways Version");
  await page.goto(`/gtfs/${versionId}/alerts`);
  await page.waitForSelector("#alerts-first-use", { timeout: 15000 });
  return versionId;
}

async function fitsViewport(page) {
  return page.evaluate(
    () => document.documentElement.scrollWidth <= window.innerWidth,
  );
}

// The prototype state this view is compared against. The reference file lives
// in the gitignored `.specs/` workspace, so a checkout without it skips the
// reference capture rather than failing.
async function captureReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  const reference = `file://${REFERENCE_PATH}?state=${state}`;
  await page.goto(reference);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `list-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// The editor's own reference capture. The reference file lives in the gitignored
// `.specs/` workspace, so a checkout without it skips the reference rather than
// failing.
async function captureReferenceState(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `shell-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// The assistant states' reference capture, for the same side-by-side reading as
// the editor's own.
async function captureAssistantReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `assistant-start-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

test.describe("alerts list", () => {
  test("the seeded current tab lists alerts with counts at both widths @list", async ({
    page,
  }, testInfo) => {
    for (const viewport of [DESKTOP, NARROW]) {
      await page.setViewportSize(viewport);
      await openAlerts(page);

      await expect(page.locator("#alerts-page")).toBeVisible();
      await expect(page.locator("#alerts-tabs")).toBeVisible();

      for (const tab of ["current", "upcoming", "in_progress", "past"]) {
        await expect(page.locator(`#alerts-tab-${tab}`)).toBeVisible();
      }

      await expect(page.locator("#create-alert")).toBeVisible();

      const currentCount = Number(
        await page.locator("#alerts-tab-current").getAttribute("data-count"),
      );
      await expect(page.locator("#alerts-tab-current")).toHaveAttribute(
        "aria-selected",
        "true",
      );

      if (currentCount > 0) {
        await expect(page.locator("#alerts-list")).toBeVisible();
        await expect(
          page.locator("#alerts tbody tr[id^='alert-row-']").first(),
        ).toBeVisible();
      }

      // The publication states and actions this package removed must not appear.
      const body = await page.locator("#alerts-page").innerText();
      for (const word of ["Live", "Scheduled", "Ended", "End alert"]) {
        expect(body).not.toContain(word);
      }

      expect(await fitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, `list-live-${viewport.label}.png`),
        fullPage: false,
      });

      await captureReference(page, testInfo, "list-live", viewport.label);
    }
  });

  test("an empty tab says what belongs in it @list", async ({ page }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openAlerts(page);

    await page.locator("#alerts-tab-past").click();
    await page.waitForURL(/tab=past/);
    await page.waitForSelector("#alerts-tab-empty-past");

    await expect(page.locator("#alerts-tab-empty-past")).toContainText(
      "No earlier alerts",
    );
    await expect(page.locator("#alerts-first-use")).toHaveCount(0);

    expect(await fitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, `list-tab-empty-1440.png`),
      fullPage: false,
    });
  });

  test("an organization with no alerts gets the first-use panel @list", async ({
    page,
  }, testInfo) => {
    for (const viewport of [DESKTOP, NARROW]) {
      await page.setViewportSize(viewport);
      await openFirstUseAlerts(page);

      await expect(page.locator("#alerts-first-use")).toBeVisible();
      await expect(page.locator("#alerts-first-use")).toContainText(
        "No alerts yet",
      );
      await expect(page.locator("#create-alert-first-use")).toContainText(
        "Create alert",
      );
      await expect(page.locator("#alerts-list")).toHaveCount(0);
      await expect(page.locator("#main-navigation #nav-alerts")).toBeVisible();

      expect(await fitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, `list-empty-${viewport.label}.png`),
        fullPage: false,
      });

      await captureReference(page, testInfo, "list-empty", viewport.label);
    }
  });
});
// The editor shell, as spec 30's step 14 renders it: the frame, the URL state,
// creation on the first answer and the version check (AC-15, R1). Nothing here
// looks for a publication state or action, because saving an alert never
// publishes one in this package (R2, CR-1).

// The editor is reached without the list page, because the list page's own
// `@list` journey fails on a step-13 defect (step 30 step 13's stream error,
// fixed in its own step). Going straight to the editor keeps this step's
// journey about the editor.
// Signing in is idempotent: a journey that visits the editor more than once
// arrives already signed in, and asking for the log-in page again redirects to
// the app, which would leave this waiting for a form that is not there.
async function editorVersionId(page) {
  await page.goto("/users/log_in");
  // The form or the app: a journey that visits the editor more than once is
  // already signed in, and the log-in route then redirects to the app rather
  // than rendering a form. The version trigger is waited for rather than the
  // version panel, because the panel is a dropdown that stays hidden until it
  // is opened and its options are read from the DOM.
  await page.waitForSelector("#gtfs-version-trigger, input[name='user[email]']", {
    timeout: 30_000,
  });

  if (await page.locator('input[name="user[email]"]').count()) {
    await logIn(page);
    await page.waitForSelector("#gtfs-version-trigger", { timeout: 30_000 });
  }

  return versionIdFor(page, ALERTS_VERSION);
}

async function openNewAlert(page) {
  const versionId = await editorVersionId(page);
  await page.goto(`/gtfs/${versionId}/alerts/new`);
  await page.waitForSelector("#alert-question", { timeout: 15000 });
  return versionId;
}

// Creates a real alert through the editor's own first answer and returns its
// URL, so the journey follows the same path an editor would rather than
// inventing a row.
async function openCreatedAlert(page, step) {
  const versionId = await openNewAlert(page);

  await page.locator("#alert-urgency-now").click();
  await page.waitForURL(/\/alerts\/[0-9a-f-]+\?/, { timeout: 15000 });

  const url = page.url().split("?")[0];
  if (step) {
    await page.goto(`${url}?mode=form&step=${step}`);
    await page.waitForSelector("#alert-question", { timeout: 15000 });
  }

  return url;
}

test.describe("alert editor shell", () => {
  // The first journey signs in against a freshly booted server, which pays for
  // the asset digest and the route table on its first request.
  test.describe.configure({ timeout: 120_000 });
  test("a new alert shows the frame and writes no row @shell", async ({
    page,
  }, testInfo) => {
    for (const viewport of [DESKTOP, NARROW]) {
      await page.setViewportSize(viewport);
      await openNewAlert(page);

      await expect(page.locator("#alert-editor")).toBeVisible();
      await expect(page.locator("#alert-back-link")).toContainText("Alerts");
      await expect(page.locator("#alert-question-title")).toHaveText(
        "When are riders affected?",
      );
      await expect(page.locator("#alert-urgency-now")).toContainText(
        "Happening now",
      );
      await expect(page.locator("#alert-urgency-planned")).toContainText(
        "Starts later",
      );
      await expect(page.locator("#alert-progress")).toBeVisible();
      await expect(page.locator("#alert-mode")).toBeVisible();
      await expect(page.locator("#alert-preview")).toContainText("Rider preview");
      await expect(page.locator("#alert-save-bar")).toBeVisible();

      // The publication states this package removed must not appear.
      const body = await page.locator("#alert-editor").innerText();
      for (const word of ["Live", "Scheduled", "Ended", "End alert"]) {
        expect(body).not.toContain(word);
      }

      // The prototype's publishing-only preview copy is dropped too.
      expect(body).not.toContain("review before publishing");
      expect(body).not.toContain("Data sent to apps");

      expect(await fitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, `shell-new-${viewport.label}.png`),
        fullPage: false,
      });

      if (viewport === DESKTOP) {
        await captureReferenceState(page, testInfo, "form-start", viewport.label);
      }
    }
  });

  test("the first answer creates the alert and the URL becomes the row's own @shell", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openNewAlert(page);

    await page.locator("#alert-urgency-now").click();
    await page.waitForURL(/\/alerts\/[0-9a-f-]+\?mode=form&step=situation/, {
      timeout: 15000,
    });

    await expect(page.locator("#alert-question-title")).toHaveText(
        "What is happening?",
    );
    await expect(page.locator("#alert-step-urgency")).toContainText("Timing");
    await expect(page.locator("#alert-save-bar")).toContainText("Saved");

    // The same URL after a reload is the same question, which is what makes the
    // mode and step addressable.
    await page.reload();
    await expect(page.locator("#alert-question-title")).toHaveText(
      "What is happening?",
    );

    await page.screenshot({
      path: capturePath(testInfo, "shell-created-1440.png"),
      fullPage: false,
    });
  });

  test("a saved alert keeps its step in the URL and previews its answers @shell", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    const url = await openCreatedAlert(page, "situation");

    await expect(page.locator("#alert-question-title")).toBeVisible();
    await expect(page.locator("#alert-step-situation")).toHaveAttribute(
      "aria-current",
      "step",
    );
    await expect(page.locator("#alert-preview-facts")).toBeVisible();
    // An alert created here has only its timing answer, so the preview says so
    // in words rather than showing an empty panel.
    await expect(page.locator("#alert-preview-when")).toContainText(
      "Not chosen yet",
    );

    // Every step the alert asks is a link carrying its own question in the URL.
    // An alert with one answer asked two questions, so both are here.
    const steps = await page
      .locator("#alert-progress a[id^='alert-step-']")
      .evaluateAll((links) => links.map((link) => link.getAttribute("href")));
    expect(steps).toHaveLength(2);
    for (const href of steps) expect(href).toContain("step=");

    // Reloading that URL returns the same question.
    await page.goto(`${url}?mode=form&step=situation`);
    await page.waitForSelector("#alert-question");
    await expect(page.locator("#alert-step-situation")).toHaveAttribute(
      "aria-current",
      "step",
    );

    expect(await fitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "shell-saved-1440.png"),
      fullPage: false,
    });
  });

  test("Make default stores the mode the editor is in @shell", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openNewAlert(page);

    // The assistant mode is not the reader's stored default, so the editor
    // offers to store it.
    await page.goto(`${page.url().split("?")[0]}?mode=assistant`);
    await page.waitForSelector("#alert-assistant");
    await expect(page.locator("#make-default-mode")).toBeVisible();

    await page.locator("#make-default-mode").click();
    await expect(page.locator("#alert-mode-default")).toHaveText("Default");
    await expect(page.locator("#make-default-mode")).toHaveCount(0);

    // Storing assistant as the default means the form mode is now the one that
    // offers itself as the default.
    await page.goto(`${page.url().split("?")[0]}?mode=form`);
    await page.waitForSelector("#alert-question");
    await expect(page.locator("#make-default-mode")).toBeVisible();
    await page.locator("#make-default-mode").click();

    await expect(page.locator("#alert-mode-default")).toHaveText("Default");
    await expect(page.locator("#make-default-mode")).toHaveCount(0);

    await page.screenshot({
      path: capturePath(testInfo, "shell-make-default-1440.png"),
      fullPage: false,
    });
  });

  test("Delete alert asks before it removes anything @shell", async ({ page }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openCreatedAlert(page);

    await page.locator("#delete-alert").click();
    await expect(page.locator("#delete-alert-dialog")).toHaveAttribute(
      "data-open",
      "true",
    );
    await expect(page.locator("#delete-alert-dialog")).toContainText(
      "This cannot be undone",
    );

    await page.screenshot({
      path: capturePath(testInfo, "shell-delete-1440.png"),
      fullPage: false,
    });

    await page.locator("#delete-alert-dialog-cancel").click();
    await expect(page.locator("#delete-alert-dialog")).toHaveAttribute(
      "data-open",
      "false",
    );
    await expect(page.locator("#alert-editor")).toBeVisible();
  });
});

// Autosave, save status and conflicts, as spec 30's step 15 renders them: the
// bottom save bar's own words, the Retry a refused save offers, and the
// two-action conflict banner a stale save raises (AC-16, R6). Nothing here
// forces a save through anything but the form, because the form is the only
// path an editor has.

async function captureAutosaveReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `autosave-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// A saved alert that already answers enough questions to reach the message
// step, so the text inputs under test are the ones the editor itself uses.
// The list puts an alert under the tab its own window belongs to, so the tabs
// are opened in turn rather than assuming which one holds it.
async function openMessageAlert(page) {
  const versionId = await openAlerts(page);

  for (const tab of ["current", "upcoming", "in_progress", "past"]) {
    const tab_link = page.locator(`#alerts-tab-${tab}`);
    if (!(await tab_link.count())) continue;

    await tab_link.click();

    // The row's own link is what says the tab holds an alert. Waiting for the
    // stream's container instead would pass on a tab with no rows in it, and
    // the wait is bounded per tab so an empty one moves on to the next.
    const row_link = page.locator("a[id^='alert-link-']").first();

    if (await row_link.waitFor({ state: "visible", timeout: 5_000 }).then(() => true, () => false)) {
      await row_link.click();
      break;
    }
  }

  await page.waitForSelector("#alert-question", { timeout: 15_000 });

  const url = page.url().split("?")[0];
  await page.goto(`${url}?mode=form&step=message`);
  await page.waitForSelector("#alert_message_header", { timeout: 15_000 });

  return url;
}

test.describe("alert autosave", () => {
  test.describe.configure({ timeout: 120_000 });

  test("typing saves, and the bar reads the state it is in @autosave", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openMessageAlert(page);

    const header = page.locator("#alert_message_header");
    await header.fill("Route 12 detour: Harbor Hospital stop not served");

    // "Saved" only after the server acknowledged, never optimistically.
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    await expect(page.locator("#alert-save-retry")).toHaveCount(0);
    await expect(page.locator("#alert-save-close")).toBeVisible();

    // The same URL after a reload is the same question with the same answer:
    // the draft is on the server, not in the browser.
    await page.reload();
    await page.waitForSelector("#alert_message_header", { timeout: 15000 });
    await expect(page.locator("#alert_message_header")).toHaveValue(
      "Route 12 detour: Harbor Hospital stop not served",
    );

    expect(await fitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "autosave-saved-1440.png"),
      fullPage: false,
    });
  });

  test("typing then reloading within 2 s still shows the typed header @autosave", async ({
    page,
  }) => {
    await page.setViewportSize(DESKTOP);
    await openMessageAlert(page);

    await page.locator("#alert_message_header").fill("Reloaded quickly header");
    await page.waitForTimeout(2000);
    await page.reload();
    await page.waitForSelector("#alert_message_header", { timeout: 15000 });

    await expect(page.locator("#alert_message_header")).toHaveValue(
      "Reloaded quickly header",
    );
  });

  test("a refused save keeps the typed header and offers Retry @autosave", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openMessageAlert(page);

    const tooLong = "a".repeat(121);
    await page.locator("#alert_message_header").fill(tooLong);

    await expect(page.locator("#alert-save-status")).toHaveText("Not saved.");
    await expect(page.locator("#alert-save-retry")).toBeVisible();
    await expect(page.locator("#alert_message_header")).toHaveValue(tooLong);
    await expect(page.locator("#alert_message_header-error")).toContainText(
      "120 character",
    );

    await page.screenshot({
      path: capturePath(testInfo, "autosave-failure-1440.png"),
      fullPage: false,
    });
    await captureAutosaveReference(page, testInfo, "form-message", "1440");

    // Fixing the header saves it, which is what Retry's presence promised.
    await page.locator("#alert_message_header").fill("Short enough now");
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    await expect(page.locator("#alert-save-retry")).toHaveCount(0);
  });

  test("a stale save offers Load latest and Save as new alert, and nothing else @autosave", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    const url = await openMessageAlert(page);

    // A second tab holds the same alert at the same revision and saves first,
    // which is the interleaving AC-16 describes.
    const other = await page.context().newPage();
    await other.goto(`${url}?mode=form&step=message`);
    await other.waitForSelector("#alert_message_header", { timeout: 15000 });
    await other.locator("#alert_message_header").fill("Saved in the other tab");
    await expect(other.locator("#alert-save-status")).toHaveText("Saved");
    await other.close();

    await page.locator("#alert_message_header").fill("Typed in this tab");
    await expect(page.locator("#alert-conflict")).toBeVisible();
    await expect(page.locator("#alert-conflict")).toContainText(
      "another tab or by another editor",
    );
    await expect(page.locator("#conflict-load-latest")).toBeVisible();
    await expect(page.locator("#conflict-save-new")).toBeVisible();
    await expect(page.locator("#alert-save-status")).toHaveText("Not saved.");

    expect(await fitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "autosave-conflict-1440.png"),
      fullPage: false,
    });

    // Load latest takes the other side of the conflict.
    await page.locator("#conflict-load-latest").click();
    await expect(page.locator("#alert-conflict")).toHaveCount(0);
    await expect(page.locator("#alert_message_header")).toHaveValue(
      "Saved in the other tab",
    );
  });

  test("the save bar and conflict banner fit the narrow width @autosave", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(NARROW);
    const url = await openMessageAlert(page);

    const other = await page.context().newPage();
    await other.goto(`${url}?mode=form&step=message`);
    await other.waitForSelector("#alert_message_header", { timeout: 15000 });
    await other.locator("#alert_message_header").fill("Saved elsewhere");
    await expect(other.locator("#alert-save-status")).toHaveText("Saved");
    await other.close();

    await page.locator("#alert_message_header").fill("Typed here at 320 px");
    await expect(page.locator("#alert-conflict")).toBeVisible();
    expect(await fitsViewport(page)).toBe(true);

    await page.screenshot({
      path: capturePath(testInfo, "autosave-conflict-320.png"),
      fullPage: false,
    });

    await page.locator("#conflict-load-latest").click();
    await expect(page.locator("#alert_message_header")).toHaveValue(
      "Saved elsewhere",
    );
    await page.screenshot({
      path: capturePath(testInfo, "autosave-saved-320.png"),
      fullPage: false,
    });
  });

  test("Save and close saves and returns to the list @autosave", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openMessageAlert(page);

    await page.locator("#alert_message_header").fill("Typed then closed");
    await page.locator("#alert-save-close").click();

    await page.waitForURL(/\/alerts(\?|$)/, { timeout: 15000 });
    await page.screenshot({
      path: capturePath(testInfo, "autosave-closed-1440.png"),
      fullPage: false,
    });
  });
});

// The choice questions, as spec 30's step 16 renders them: a card that saves and
// advances by itself, the heading that takes the focus afterwards, Back that
// loses nothing, the mode question a single-mode version does not ask, and the
// one question in the sequence that needs Continue (AC-17).

async function captureChoicesReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `choices-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// `phx-mounted` runs on the client once the LiveView is connected and has
// rendered, so the question heading taking the focus is the editor's own
// readiness signal - and the behaviour the choice questions depend on.
async function waitForEditorMounted(page) {
  await expect(page.locator("#alert-question-title")).toBeFocused({ timeout: 15_000 });
}

// The heading the question card moves the focus to, read from the browser rather
// than from the server: `phx-mounted` fires once per element, so this asserts
// the behaviour an editor actually gets.
async function focusedHeading(page) {
  return page.evaluate(() => {
    const active = document.activeElement;
    return active && active.tagName === "H2" ? active.textContent.trim() : null;
  });
}

test.describe("alert choice questions", () => {
  test.describe.configure({ timeout: 120_000 });

  test("Enter on a focused choice advances and focus moves to the next heading @choices", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openNewAlert(page);

    await expect(page.locator("#situation-delay")).toHaveCount(0);

    // The first answer creates the draft and moves to the situation question.
    await waitForEditorMounted(page);
    await page.locator("#alert-urgency-now").focus();
    await page.keyboard.press("Enter");
    await page.waitForURL(/step=situation/, { timeout: 15_000 });
    await page.waitForSelector("#situation-detour");
    expect(await focusedHeading(page)).toBe("What is happening?");

    // A detour advances the same way from the keyboard.
    await page.locator("#situation-detour").focus();
    await page.keyboard.press("Enter");
    await page.waitForSelector("#mode-3", { timeout: 15_000 });
    expect(await focusedHeading(page)).toBe("Which service is affected?");

    await page.locator("#mode-3").focus();
    await page.keyboard.press("Enter");
    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    expect(await focusedHeading(page)).toBe("Which routes are affected?");

    expect(await fitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "choices-routes-1440.png"),
      fullPage: false,
    });
    await captureChoicesReference(page, testInfo, "form-where", "1440");
  });

  test("the situation cards fit the narrow width @choices", async ({ page }, testInfo) => {
    await page.setViewportSize(NARROW);
    await openNewAlert(page);

    await waitForEditorMounted(page);
    await page.locator("#alert-urgency-now").click();
    await page.waitForURL(/step=situation/, { timeout: 15_000 });
    await page.waitForSelector("#situation-service_change");

    for (const value of [
      "delay",
      "detour",
      "stop_moved",
      "stop_closed",
      "cancelled_trips",
      "suspension",
      "accessibility",
      "service_change",
    ]) {
      await expect(page.locator(`#situation-${value}`)).toBeVisible();
    }

    expect(await fitsViewport(page)).toBe(true);
    // The narrow viewport is shorter than the question, so this capture is the
    // whole page: a cropped one would show the header and none of the cards.
    await page.screenshot({
      path: capturePath(testInfo, "choices-situation-320.png"),
      fullPage: true,
    });
    await captureChoicesReference(page, testInfo, "form-effect", "320");
  });

  test("Back returns to the situation with the choice still pressed @choices", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    const url = await openCreatedAlert(page);

    await page.locator("#situation-detour").click();
    await page.waitForSelector("#mode-3", { timeout: 15_000 });

    await page.locator("#alert-question-back").click();
    await page.waitForSelector("#situation-detour", { timeout: 15_000 });
    await expect(page.locator("#situation-detour")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    await expect(page.locator("#situation-delay")).toHaveAttribute(
      "aria-pressed",
      "false",
    );

    // Back is navigation: the answer is still on the row behind it.
    await page.goto(`${url}?mode=form&step=situation`);
    await page.waitForSelector("#situation-detour", { timeout: 15_000 });
    await expect(page.locator("#situation-detour")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
  });

  test("a multimodal version asks which service, and a service change asks what changes @choices", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openNewAlert(page);

    await page.locator("#alert-urgency-planned").click();
    await page.waitForURL(/step=situation/, { timeout: 15_000 });

    // The seeded version runs bus and tram, so Mode follows Situation and the
    // other questions shift down with it.
    await expect(page.locator("#alert-step-mode")).toHaveCount(0);
    await page.locator("#situation-service_change").click();
    await page.waitForSelector("#mode-0", { timeout: 15_000 });
    await expect(page.locator("#alert-step-mode")).toBeVisible();

    await expect(page.locator("#mode-0")).toContainText("Tram/Light Rail");
    await expect(page.locator("#mode-3")).toContainText("Bus");
    await page.screenshot({
      path: capturePath(testInfo, "choices-mode-1440.png"),
      fullPage: false,
    });

    await page.locator("#mode-3").click();
    await page.waitForSelector("#change-fewer_trips", { timeout: 15_000 });
    await expect(page.locator("#change-fewer_trips")).toContainText("Fewer trips");
    await expect(page.locator("#change-extra_service")).toContainText(
      "Extra service",
    );
    await expect(page.locator("#change-information")).toContainText(
      "Information for riders",
    );

    // The reference capture navigates the page to the prototype, so it is the
    // last thing a journey does rather than a step in the middle of one.
    await captureChoicesReference(page, testInfo, "form-mode", "1440");
  });

  test("the route multi-select keeps its choices through Continue @choices", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openNewAlert(page);

    await waitForEditorMounted(page);
    await page.locator("#alert-urgency-now").click();
    await page.waitForURL(/step=situation/, { timeout: 15_000 });
    await page.locator("#situation-delay").click();
    await page.waitForSelector("#mode-3", { timeout: 15_000 });
    await page.locator("#mode-3").click();
    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });

    // Continue with nothing chosen says so and stays on the question.
    await page.locator("#alert-routes-continue").click();
    await expect(page.locator("#alert-routes-error")).toContainText(
      "Choose at least one route",
    );
    await expect(page.locator("#alert-question-title")).toHaveText(
      "Which routes are affected?",
    );
    await page.screenshot({
      path: capturePath(testInfo, "choices-routes-empty-1440.png"),
      fullPage: false,
    });

    // The search answers keystrokes, so the text is typed rather than filled.
    await page.locator("#alert-route-search").pressSequentially("Route");
    await page.waitForSelector("#alert-route-options button", { timeout: 15_000 });

    const first_route = page.locator("#alert-route-options button").first();
    await first_route.click();
    await expect(first_route).toHaveAttribute("aria-pressed", "true");

    // The choices are on the row before Continue, so Back never loses them.
    await page.locator("#alert-question-back").click();
    await page.waitForSelector("#mode-3", { timeout: 15_000 });
    await page.locator("#mode-3").click();
    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    await page.locator("#alert-route-search").pressSequentially("Route");
    await page.waitForSelector("#alert-route-options button[aria-pressed='true']", {
      timeout: 15_000,
    });

    await page.locator("#alert-routes-continue").click();
    await page.waitForSelector("#direction-both", { timeout: 15_000 });
    await expect(page.locator("#alert-question-title")).toHaveText(
      "Which direction is affected?",
    );

    // "Both directions" is a choice like any other: it saves and moves on.
    await expect(page.locator("#direction-both")).toContainText("Both directions");
    await page.locator("#direction-0").click();
    await page.waitForSelector("#alert-routes-continue, #alert-question-title", {
      timeout: 15_000,
    });
    await expect(page.locator("#alert-question-title")).toHaveText(
      "When should this alert end?",
    );
  });
});

// The stop questions, as spec 30's step 17 renders them: a place found by
// search, a detour's skipped stops and its stretch, the shared-stop question in
// the stop's own words, and a boarding alternative that never offers the stops
// the alert is already about (AC-18, R7).

async function captureStopsReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `stops-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// The seeded version runs Routes 1, 12 and 50, and Newport Transit Center is
// the stop Route 1 and Route 12 share, which is what raises the shared-stop
// question. The journey walks the editor's own flow rather than inventing a row.
async function openDetourStops(page) {
  await openNewAlert(page);
  await waitForEditorMounted(page);

  await page.locator("#alert-urgency-now").click();
  await page.waitForURL(/step=situation/, { timeout: 15_000 });
  await page.locator("#situation-detour").click();

  // The seeded version is multimodal, so the mode question sits between the
  // situation and the routes.
  await page.waitForSelector("#mode-3", { timeout: 15_000 });
  await page.locator("#mode-3").click();
  await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });

  await page.locator("#alert-route-search").pressSequentially("Route 1");
  await page.waitForSelector("#alert-route-options button", { timeout: 15_000 });
  // Match the label span, not the button's text content: the button wraps the
  // label in whitespace, and "Route 12" and "Route 50" both contain "Route 1".
  await page
    .locator("#alert-route-options button")
    .filter({ has: page.locator("span.font-semibold", { hasText: /^Route 1$/ }) })
    .first()
    .click();
  await page.locator("#alert-routes-continue").click();

  await page.waitForSelector("#alert-stops", { timeout: 15_000 });
  return page.url().split("?")[0];
}

test.describe("alert stop questions", () => {
  test.describe.configure({ timeout: 120_000 });

  test("a detour names the stops it skips and the stretch between two ends @stops", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openDetourStops(page);

    await expect(page.locator("#alert-question-title")).toHaveText(
      "Which stops will buses skip?",
    );
    await expect(page.locator("#alert-stops-list button")).toHaveCount(6);
    await expect(
      page.locator("#alert-stops-list button").first(),
    ).toContainText("Newport Transit Center");

    await page.screenshot({
      path: capturePath(testInfo, "stops-skipped-1440.png"),
      fullPage: false,
    });

    // A stretch is two ends on the route's own list, and the stops between them
    // are what the detour skips.
    await page.locator("#alert-stops-stretch summary").click();
    await page
      .locator("#alert-stretch-from")
      .selectOption({ label: "N Coast Hwy & NE 6th St" });
    await page
      .locator("#alert-stretch-to")
      .selectOption({ label: "N Coast Hwy & NE 20th St" });
    await page.locator("#alert-stretch-select").click();

    await expect(page.locator("#alert-stop-AL_CST6-shown")).toHaveCount(0);
    const pressed = page.locator("#alert-stops-list button[aria-pressed='true']");
    await expect(pressed).toHaveCount(3);
    await expect(pressed.first()).toContainText("N Coast Hwy & NE 6th St");

    await page.screenshot({
      path: capturePath(testInfo, "stops-stretch-1440.png"),
      fullPage: false,
    });

    await captureStopsReference(page, testInfo, "form-stops", "1440");
  });

  test("a shared stop asks about the other route by name @stops", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openDetourStops(page);

    // Newport Transit Center is the stop Route 1 and Route 12 share.
    await page
      .locator("#alert-stops-list button")
      .filter({ hasText: "Newport Transit Center" })
      .click();
    await page.locator("#alert-stops-continue").click();

    await page.waitForSelector("#alert-shared", { timeout: 15_000 });
    await expect(page.locator("#alert-question-title")).toHaveText(
      "Are other routes affected at these stops?",
    );
    await expect(page.locator("#alert-shared fieldset")).toContainText(
      "Route 12 also stops at Newport Transit Center. Is it affected too?",
    );

    await page.screenshot({
      path: capturePath(testInfo, "stops-shared-1440.png"),
      fullPage: false,
    });

    await page.locator("#alert-shared button[id$='-yes']").first().click();
    await page.waitForSelector("#alert-boarding", { timeout: 15_000 });

    await captureStopsReference(page, testInfo, "form-shared", "1440");
  });

  test("the boarding alternative excludes the affected stops and works by keyboard @stops", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openDetourStops(page);

    await page
      .locator("#alert-stops-list button")
      .filter({ hasText: "N Coast Hwy & NE 20th St" })
      .click();
    await page.locator("#alert-stops-continue").click();
    await page.waitForSelector("#alert-boarding", { timeout: 15_000 });

    // The combobox is a search: typing offers stops and stores nothing, which is
    // what R7 requires.
    const search = page.locator("#alternative_stop_id_text_input");
    await search.click();
    await search.pressSequentially("N Coast");
    await page.waitForSelector("#alert-boarding-stop ul li div[data-idx]", {
      timeout: 15_000,
    });

    await page.screenshot({
      path: capturePath(testInfo, "stops-boarding-1440.png"),
      fullPage: false,
    });

    // Escape closes the list without changing the answer...
    await search.press("Escape");
    await expect(page.locator("#alert-boarding-stop ul")).toHaveCount(0);
    await expect(page.locator("#alert-save-status")).not.toHaveText("Saving…");

    // ...and the keyboard picks from the same list a pointer does.
    await search.press("ArrowDown");
    await search.press("Enter");
    await expect(page.locator("#alternative_stop_id")).not.toHaveValue("");
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    // Written directions replace the chosen stop rather than joining it.
    await page.locator("#write-directions").click();
    await page.waitForSelector("#write-directions-field", { timeout: 15_000 });
    await page
      .locator("#write-directions-field")
      .fill("Board at the temporary stop on NE Main St.");
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    await page.screenshot({
      path: capturePath(testInfo, "stops-boarding-search-1440.png"),
      fullPage: false,
    });

    await captureStopsReference(page, testInfo, "form-access", "1440");
  });

  test("the stop questions fit the narrow width @stops", async ({ page }, testInfo) => {
    await page.setViewportSize(NARROW);
    await openDetourStops(page);

    await expect(page.locator("#alert-stops")).toBeVisible();
    expect(await fitsViewport(page)).toBe(true);
    // The narrow viewport is shorter than the stop list, so this capture is the
    // whole page: a cropped one would show the header and no stops.
    await page.screenshot({
      path: capturePath(testInfo, "stops-skipped-320.png"),
      fullPage: true,
    });
    await captureStopsReference(page, testInfo, "form-stops", "320");
  });
});

// The cancelled-departures question, as spec 30's step 18 renders it: a service
// date per checklist, the departures running on it, and a pair stored for each
// one chosen (AC-19). The seeded Route 1 runs weekday and weekend service today
// ± 60 days, so a dated cancellation has real departures to offer on any date
// this journey names.

async function captureDeparturesReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `departures-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// A cancelled trip names a route and a date rather than a schedule question, so
// the journey walks the editor's own flow: urgency, situation, mode, routes.
async function openDepartures(page) {
  await openNewAlert(page);
  await waitForEditorMounted(page);

  await page.locator("#alert-urgency-now").click();
  await page.waitForURL(/step=situation/, { timeout: 15_000 });
  await page.locator("#situation-cancelled_trips").click();

  // The seeded version is multimodal, so the mode question sits between the
  // situation and the routes.
  await page.waitForSelector("#mode-3", { timeout: 15_000 });
  await page.locator("#mode-3").click();
  await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });

  await page.locator("#alert-route-search").pressSequentially("Route 1");
  await page.waitForSelector("#alert-route-options button", { timeout: 15_000 });
  // Match the label span, not the button's text content: the button wraps the
  // label in whitespace, and "Route 12" and "Route 50" both contain "Route 1".
  await page
    .locator("#alert-route-options button")
    .filter({ has: page.locator("span.font-semibold", { hasText: /^Route 1$/ }) })
    .first()
    .click();
  await page.locator("#alert-routes-continue").click();

  await page.waitForSelector("#alert-departures", { timeout: 15_000 });
  return page.url().split("?")[0];
}

// The date the question opened on, read from the group it rendered rather than
// from the browser's clock, so a service date and the server's own today never
// disagree about which day it is.
async function firstDepartureGroup(page) {
  return page
    .locator("div[id^='alert-departures-']")
    .filter({ has: page.locator("fieldset[id^='alert-departure-list-']") })
    .first();
}

async function firstDepartureDate(page) {
  const group = await firstDepartureGroup(page);
  const id = await group.getAttribute("id");
  return id.replace("alert-departures-", "");
}

async function addDayAfter(page, iso) {
  const [year, month, day] = iso.split("-").map(Number);
  const next = new Date(Date.UTC(year, month - 1, day + 1)).toISOString().slice(0, 10);

  await page.locator("#service-date").fill(next);
  await page.locator("#add-service-date").click();
  await page.waitForSelector(`#alert-departures-${next}`, { timeout: 15_000 });
  return next;
}

test.describe("alert cancelled departures", () => {
  test.describe.configure({ timeout: 120_000 });

  test("a dated cancellation names two departures on two dates @departures", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openDepartures(page);

    await expect(page.locator("#alert-question-title")).toHaveText(
      "Which departures will not run?",
    );
    await expect(page.locator("#add-service-date")).toBeVisible();

    // The question opens on the agency's own date, listing that day's
    // departures in the order they leave.
    const first_date = await firstDepartureDate(page);
    const first_list = page.locator(`#alert-departure-list-${first_date}`);
    await expect(first_list.locator("input[type='checkbox']").first()).toBeVisible();
    // Each label is a rider's departure: its time and where it goes. The text
    // is matched without anchors, because the label wraps its own whitespace.
    await expect(first_list.locator("label").first()).toContainText(
      /\d{1,2}:\d{2} (AM|PM) to Lincoln City/,
    );

    // The seeded night trip leaves at 24:40, so on weekday service its own row
    // says the departure is the next day rather than reading as 12:40 AM.
    const weekday = new Date(`${first_date}T00:00:00Z`).getUTCDay();
    if (weekday >= 1 && weekday <= 5) {
      await expect(page.locator("#alert-departures")).toContainText("(next day)");
    }

    await page.screenshot({
      path: capturePath(testInfo, "departures-open-1440.png"),
      fullPage: false,
    });

    // A second date gets its own checklist, drawn from the same schedule.
    const second_date = await addDayAfter(page, first_date);
    const second_list = page.locator(`#alert-departure-list-${second_date}`);
    await expect(second_list.locator("input[type='checkbox']")).not.toHaveCount(0);

    // Each chosen departure writes at once, so the pair is on the row before
    // Continue is pressed.
    const chosen = second_list.locator("input[type='checkbox']");
    await chosen.nth(0).click();
    await expect(chosen.nth(0)).toBeChecked();
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    await chosen.nth(1).click();
    await expect(chosen.nth(1)).toBeChecked();

    // The same departure on the first date is a separate pair, because a trip
    // repeats across its service dates.
    await first_list.locator("input[type='checkbox']").first().click();
    await expect(first_list.locator("input[type='checkbox']").first()).toBeChecked();

    await page.screenshot({
      path: capturePath(testInfo, "departures-dated-1440.png"),
      fullPage: false,
    });

    await page.locator("#alert-departures-continue").click();
    await page.waitForURL(/step=reason/, { timeout: 15_000 });
    await expect(page.locator("#alert-question-title")).toHaveText("Why is this happening?");

    await captureDeparturesReference(page, testInfo, "form-trips", "1440");
  });

  test("removing a date takes its departures with it @departures", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openDepartures(page);

    const first_date = await firstDepartureDate(page);
    const second_date = await addDayAfter(page, first_date);

    await page
      .locator(`#alert-departure-list-${second_date} input[type='checkbox']`)
      .first()
      .click();
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    await page.locator(`#alert-remove-date-${second_date}`).click();
    await expect(page.locator(`#alert-departures-${second_date}`)).toHaveCount(0);
    await expect(page.locator(`#alert-departures-${first_date}`)).toBeVisible();
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    await page.screenshot({
      path: capturePath(testInfo, "departures-removed-1440.png"),
      fullPage: false,
    });
  });

  test("departures can be chosen by keyboard at the narrow width @departures", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(NARROW);
    await openDepartures(page);

    await expect(page.locator("#alert-departures")).toBeVisible();
    expect(await fitsViewport(page)).toBe(true);

    const iso = await firstDepartureDate(page);
    const first_box = page.locator(`#alert-departure-list-${iso} input[type='checkbox']`).first();

    // Space on the focused checkbox is the keyboard's own selection, so the
    // departure is stored the same way a pointer click stores it.
    await first_box.focus();
    await expect(first_box).toBeFocused();
    await page.keyboard.press("Space");
    await expect(first_box).toBeChecked();
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    // The narrow viewport is shorter than the checklist, so this capture is
    // the whole page: a cropped one would show the heading and no departures.
    await page.screenshot({
      path: capturePath(testInfo, "departures-selected-320.png"),
      fullPage: true,
    });
    await captureDeparturesReference(page, testInfo, "form-trips", "320");
  });
});

// The timing question, as spec 30's step 19 renders it: what a current
// disruption's end needs, and what a planned change expands to (AC-20). Nothing
// here looks for a publication state or action (R2, CR-1).

// The prototype states this question is compared against. The reference file
// lives in the gitignored `.specs/` workspace, so a checkout without it skips
// the capture rather than failing.
async function captureTimingReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `timing-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// A delay is the sequence the specification's step table gives: urgency,
// situation, mode, routes, direction, timing - so this journey walks the
// editor's own flow to the timing question rather than opening a URL with an
// alert that never existed.
async function openTiming(page, urgency) {
  await openNewAlert(page);
  await waitForEditorMounted(page);

  await page.locator(`#alert-urgency-${urgency}`).click();
  await page.waitForURL(/step=situation/, { timeout: 15_000 });
  await page.locator("#situation-delay").click();

  await page.waitForSelector("#mode-3", { timeout: 15_000 });
  await page.locator("#mode-3").click();
  await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });

  await page.locator("#alert-route-search").pressSequentially("Route 1");
  await page.waitForSelector("#alert-route-options button", { timeout: 15_000 });
  // Match the label span, not the button's text: the button wraps the label in
  // whitespace, and "Route 12" and "Route 50" both contain "Route 1".
  await page
    .locator("#alert-route-options button")
    .filter({ has: page.locator("span.font-semibold", { hasText: /^Route 1$/ }) })
    .first()
    .click();
  await page.locator("#alert-routes-continue").click();

  await page.waitForSelector("#direction-0", { timeout: 15_000 });
  await page.locator("#direction-0").click();

  await page.waitForSelector("#alert-timing", { timeout: 15_000 });
}

// The days this question offers, Monday first, as the ISO numbers the answer
// stores. Only Monday to Friday is a plain weekday run.
const WEEKDAYS = [1, 2, 3, 4, 5];

async function chooseWeekdays(page, days = WEEKDAYS) {
  for (const day of days) {
    await page.locator(`#timing-weekday-${day}`).click();
    await expect(page.locator(`#timing-weekday-${day}`)).toHaveAttribute(
      "aria-pressed",
      "true",
    );
  }
}

test.describe("alert timing", () => {
  test.describe.configure({ timeout: 120_000 });

  test("a current disruption's end asks for a check-in or an end time @timing", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openTiming(page, "now");

    await expect(page.locator("#alert-question-title")).toHaveText(
      "When should this alert end?",
    );

    // The card names the zone the times are read in, because a transit
    // professional's clock and the browser's clock are not always the same one.
    await expect(page.locator("#alert-timing-zone")).toContainText(
      "America/Los_Angeles",
    );

    // An estimate keeps the alert live, so it asks when staff check back.
    await page.locator("#alert-timing-end-kind-estimated").click();
    await expect(page.locator("#alert-timing-end-kind-estimated")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    await expect(page.locator("#timing-check-in")).toBeVisible();
    await expect(page.locator("#timing-end-date")).toHaveCount(0);
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    // Choosing the check-in writes the civil time it falls on.
    await page.locator("#timing-check-in").selectOption({ index: 2 });
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    // A confirmed end expires the alert, so it asks a date and a time instead.
    await page.locator("#alert-timing-end-kind-confirmed").click();
    await expect(page.locator("#timing-end-date")).toBeVisible();
    await expect(page.locator("#timing-end-time")).toBeVisible();
    await expect(page.locator("#timing-check-in")).toHaveCount(0);

    await page.screenshot({
      path: capturePath(testInfo, "timing-now-1440.png"),
      fullPage: false,
    });
    await captureTimingReference(page, testInfo, "form-when-now", "1440");
  });

  test("planned night work previews every date and loses the one removed @timing", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openTiming(page, "planned");

    await expect(page.locator("#alert-question-title")).toHaveText(
      "When will service change?",
    );

    // Once and Repeats each week are two different answers, so choosing the
    // pattern reveals the questions that answer is made of.
    await page.locator("#alert-timing-pattern-weekly").click();
    await expect(page.locator("#timing-first-date")).toBeVisible();
    await expect(page.locator("#timing-weeks")).toBeVisible();

    await page.locator("#timing-first-date").fill("2026-10-05");
    await page.locator("#timing-weeks").fill("2");
    await chooseWeekdays(page);

    await page.locator("#timing-day-start").fill("20:00");
    await page.locator("#timing-day-end").fill("05:00");

    // Until is at or before From, so each night ends the next morning, and the
    // card says so in words.
    await expect(page.locator("#alert-timing-overnight")).toContainText(
      "Ends the following day.",
    );

    // The preview is the alert's own expansion: ten nights, Monday to Friday
    // for two weeks.
    await expect(page.locator("#alert-timing-count")).toContainText(
      "10 days: Oct 5 to Oct 16",
    );
    await expect(page.locator("#alert-timing-occurrences > li")).toHaveCount(10);
    await expect(page.locator("#alert-timing-occurrence-2026-10-05")).toContainText(
      "Monday, October 5",
    );
    await expect(page.locator("#alert-timing-occurrence-2026-10-05")).toContainText(
      "8:00 PM to 5:00 AM (next day)",
    );
    await expect(page.locator("#alert-timing-occurrence-2026-10-10")).toHaveCount(0);

    // Riders are told from the later of today and a week before the first date,
    // and the field says so before anything is stored.
    const notice = await page.locator("#timing-notice-on").inputValue();
    expect(notice).toMatch(/^\d{4}-\d{2}-\d{2}$/);

    await page.screenshot({
      path: capturePath(testInfo, "timing-planned-1440.png"),
      fullPage: false,
    });

    // One Friday is removed, which is nine nights and a chip saying so.
    await page.locator("#timing-date").fill("2026-10-09");
    await page.locator("#add-timing-date").click();

    await expect(page.locator("#alert-timing-removed-2026-10-09")).toContainText(
      "Friday, October 9",
    );
    await expect(page.locator("#alert-timing-count")).toContainText(
      "9 days: Oct 5 to Oct 16",
    );
    await expect(page.locator("#alert-timing-occurrences > li")).toHaveCount(9);
    await expect(page.locator("#alert-timing-occurrence-2026-10-09")).toHaveCount(0);
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    // Putting it back rejoins the pattern.
    await page.locator("#alert-timing-removed-remove-2026-10-09").click();
    await expect(page.locator("#alert-timing-count")).toContainText(
      "10 days: Oct 5 to Oct 16",
    );

    await page.screenshot({
      path: capturePath(testInfo, "timing-planned-removed-1440.png"),
      fullPage: false,
    });
    await captureTimingReference(page, testInfo, "form-when-planned", "1440");
  });

  test("the weekday toggles and the date input work by keyboard @timing", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(NARROW);
    await openTiming(page, "planned");

    await page.locator("#alert-timing-pattern-weekly").click();
    expect(await fitsViewport(page)).toBe(true);

    // A weekday is a button, so Enter on the focused one is the keyboard's own
    // selection - the same answer a click stores.
    const monday = page.locator("#timing-weekday-1");
    await monday.focus();
    await expect(monday).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(monday).toHaveAttribute("aria-pressed", "true");
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    await page.keyboard.press("Space");
    await expect(monday).toHaveAttribute("aria-pressed", "false");

    await chooseWeekdays(page);
    await page.locator("#timing-first-date").fill("2026-10-05");
    await page.locator("#timing-weeks").fill("1");

    await expect(page.locator("#alert-timing-occurrences > li")).toHaveCount(5);

    // The date input is typed rather than filled: a date the keyboard cannot
    // reach is a date a keyboard user cannot choose.
    await page.locator("#timing-date").focus();
    await page.keyboard.type("10052026");
    await expect(page.locator("#timing-date")).toHaveValue("2026-10-05");

    // Tab reaches Add date and Enter presses it. The Monday named is one the
    // pattern already covers, so it is removed rather than added.
    await page.keyboard.press("Tab");
    await expect(page.locator("#add-timing-date")).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page.locator("#alert-timing-removed-2026-10-05")).toBeVisible();
    await expect(page.locator("#alert-timing-occurrences > li")).toHaveCount(4);
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    // The narrow viewport is shorter than the card, so this capture is the
    // whole page: a cropped one would show the heading and no preview.
    await page.screenshot({
      path: capturePath(testInfo, "timing-planned-320.png"),
      fullPage: true,
    });
    await captureTimingReference(page, testInfo, "form-when-planned", "320");
  });
});

// The reason question, as spec 30's step 20 renders it: every cause once, Other
// reason and Not known yet apart, and the optional description that belongs to
// the other reason (AC-21). Nothing here looks for a publication state or
// action (R2, CR-1).

// The prototype state this question is compared against.
async function captureReasonReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `reason-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// The editor composes every autosave against the base revision in a hidden
// field, so two edits sent before the first lands are both refused as stale
// (R6, AC-11). Waiting for that hidden value to move is waiting for the write
// to have landed, which is what keeps this journey from racing itself.
async function waitForSave(page) {
  const before = await page.locator('input[name="alert[revision]"]').inputValue();
  await expect(page.locator('input[name="alert[revision]"]')).not.toHaveValue(before);
}

// A delay is the shortest sequence that reaches the reason question: urgency,
// situation, mode, routes, direction, timing - so this journey walks the
// editor's own flow and answers the timing question rather than opening a URL
// with an alert that never existed.
async function openReason(page) {
  await openTiming(page, "now");

  // An estimate keeps the alert live, so the timing answer is a start date, a
  // clock time and a check-in, and Continue carries the reader on from there.
  await page.locator("#alert-timing-end-kind-estimated").click();
  await page.locator("#timing-check-in").selectOption({ index: 2 });
  await waitForSave(page);

  await page.locator("#timing-start-date").fill("2026-10-01");
  await waitForSave(page);

  await page.locator("#timing-start-time").fill("08:00");
  await waitForSave(page);

  await page.locator("#alert-timing-continue").click();

  await page.waitForSelector("#alert-reason", { timeout: 15_000 });
}

test.describe("alert reason", () => {
  test.describe.configure({ timeout: 120_000 });

  test("every cause is offered once and the two open-ended ones are apart @reason", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openReason(page);

    const cards = page.locator("#alert-cause button");
    await expect(cards).toHaveCount(13);

    // Match the label span, not the button's text: the button wraps the label in
    // whitespace, and "Other reason" and "Not known yet" are different answers
    // that must not collapse into one.
    for (const label of [
      "Construction or roadwork",
      "Crash",
      "Weather",
      "Police activity",
      "Medical emergency",
      "Demonstration",
      "Special event",
      "Holiday",
      "Maintenance",
      "Vehicle or equipment problem",
      "Strike",
      "Other reason",
      "Not known yet",
    ]) {
      await expect(
        cards.filter({
          has: page.locator("span.font-bold", { hasText: label }),
        }),
      ).toHaveCount(1);
    }

    await page.screenshot({
      path: capturePath(testInfo, "reason-list-1440.png"),
      fullPage: false,
    });
    await captureReasonReference(page, testInfo, "form-details", "1440");
  });

  test("the other reason saves its description and it survives a reload @reason", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openReason(page);

    // The description belongs to the other reason, so the field appears with it
    // and not before.
    await expect(page.locator("#cause-detail")).toHaveCount(0);
    await page.locator("#alert-cause-other_cause").click();
    await expect(page.locator("#cause-detail")).toBeVisible();
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    await page.locator("#cause-detail").fill("a fallen tree across the tracks");
    await expect(page.locator("#cause-detail")).toHaveValue(
      "a fallen tree across the tracks",
    );
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    await waitForSave(page);

    await page.screenshot({
      path: capturePath(testInfo, "reason-other-1440.png"),
      fullPage: false,
    });

    // The explanation is stored, so it is still on screen after the page comes
    // back rather than only in this session's memory.
    await page.reload();
    await page.waitForSelector("#cause-detail", { timeout: 15_000 });
    await expect(page.locator("#cause-detail")).toHaveValue(
      "a fallen tree across the tracks",
    );

    // Not known yet is a different answer and takes the description with it.
    await page.locator("#alert-cause-unknown_cause").click();
    await expect(page.locator("#alert-question-title")).toContainText(
      "Check the message for riders",
    );

    await page.reload();
    await page.goto(page.url().replace(/step=[a-z_]+/, "step=reason"));
    await page.waitForSelector("#alert-cause", { timeout: 15_000 });
    await expect(page.locator("#cause-detail")).toHaveCount(0);
    await expect(page.locator("#alert-cause-unknown_cause")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
  });

  test("the reason cards work by keyboard at the narrow width @reason", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(NARROW);
    await openReason(page);

    expect(await fitsViewport(page)).toBe(true);

    // A card is a button, so Enter on the focused one is the keyboard's own
    // selection - the same answer a click stores.
    const other = page.locator("#alert-cause-other_cause");
    await other.focus();
    await expect(other).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(other).toHaveAttribute("aria-pressed", "true");
    await expect(page.locator("#cause-detail")).toBeVisible();
    expect(await fitsViewport(page)).toBe(true);

    // The narrow viewport is shorter than the card, so this capture is the whole
    // page: a cropped one would show the heading and no causes.
    await page.screenshot({
      path: capturePath(testInfo, "reason-other-320.png"),
      fullPage: true,
    });
    await captureReasonReference(page, testInfo, "form-details", "320");
  });
});

// The message step, as spec 30's step 21 renders it: the organization's scripts
// with the alert's own situation first, the generated text, the wording review
// callout and the advisory checks (AC-22). Nothing here looks for a publication
// state or action (R2, CR-1).

// The prototype state this step is compared against.
async function captureMessageReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `message-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// A delay is the shortest sequence that reaches the message step: urgency,
// situation, mode, routes, direction, timing, reason - so this journey walks
// the editor's own flow and answers the reason question rather than opening a
// URL with an alert that never existed.
async function openMessage(page) {
  await openReason(page);

  // A cause is a self-contained answer, so this is the click that carries the
  // reader on to the message step.
  await page.locator("#alert-cause-weather").click();
  await page.waitForSelector("#alert-message", { timeout: 15_000 });
}

test.describe("alert message", () => {
  test.describe.configure({ timeout: 120_000 });

  test("the scripts for this situation are offered first and one fills the text @message", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openMessage(page);

    // Arriving with wording of nobody's own generates what a script would
    // produce, so the reader starts from a sentence.
    await expect(page.locator("#message-origin")).toContainText("Delays");
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    expect(await page.locator("#message-header").inputValue()).toContain("Route 1");

    await page.locator("#browse-scripts").click();
    await expect(page.locator("#message-scripts")).toBeVisible();
    await expect(page.locator("#message-scripts-matching")).toContainText(
      "Scripts for delays",
    );

    // Match the name span, not the button's text: the button wraps the name in
    // whitespace and carries the fill-ins beside it.
    const matching = page.locator("#message-scripts-list li button");
    await expect(matching).toHaveCount(1);
    await expect(
      matching.filter({ has: page.locator("span.font-bold", { hasText: "Delays" }) }),
    ).toHaveCount(1);

    // The organization's own detour script is one of the other scripts, not one
    // of the matches, because this alert is about a delay.
    await expect(
      page
        .locator("#message-scripts-other-list li button")
        .filter({ has: page.locator("span.font-bold", { hasText: "Route detour" }) }),
    ).toHaveCount(1);

    await page.screenshot({
      path: capturePath(testInfo, "message-scripts-1440.png"),
      fullPage: false,
    });

    await matching.first().click();
    await expect(page.locator("#message-scripts")).toHaveCount(0);
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    expect(await page.locator("#message-header").inputValue()).toContain("Route 1");

    // The reference capture navigates away from the app, so it is the last thing
    // this test does rather than a step in the middle of the journey.
    await captureMessageReference(page, testInfo, "form-scripts", "1440");
  });

  test("edited wording is kept and a later answer asks about it @message", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openMessage(page);

    // The editor's own URL for this question, kept because the reference capture
    // navigates away from the app and the journey comes back here.
    const messageUrl = page.url();

    // A header longer than the advisory limit is advised about and still saves.
    const long =
      "Route 1 detour overnight while Highway 101 is repaved near the depot";
    await page.locator("#message-header").fill(long);
    await expect(page.locator("#message-header")).toHaveValue(long);
    // The checks are recomputed from the stored answer, so wait for the write
    // rather than for the keystroke.
    await waitForSave(page);
    await expect(page.locator("#message-check-short")).toContainText(
      "Apps may cut it off after about 60",
    );
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    await page.screenshot({
      path: capturePath(testInfo, "message-advisory-1440.png"),
      fullPage: false,
    });

    // The answers change under the wording: the time the alert applies moves,
    // which changes the fact the text was generated from. A full page load
    // leaves the view connecting, and a change made before it is mounted is
    // never sent, so wait for the editor to be live before typing into it.
    await page.goto(messageUrl.replace(/step=[a-z_]+/, "step=timing"));
    await waitForEditorMounted(page);
    await page.waitForSelector("#timing-start-time", { timeout: 15_000 });
    await page.locator("#timing-start-time").fill("09:00");
    await waitForSave(page);

    await page.goto(messageUrl.replace(/step=[a-z_]+/, "step=message"));
    await waitForEditorMounted(page);
    await page.waitForSelector("#review-wording", { timeout: 15_000 });

    // The wording is still the operator's: the callout reports, it does not
    // rewrite.
    await expect(page.locator("#message-header")).toHaveValue(long);

    await page.screenshot({
      path: capturePath(testInfo, "message-review-1440.png"),
      fullPage: false,
    });

    // Taking the generated text is the action that replaces it.
    await page.locator("#use-generated-text").click();
    await expect(page.locator("#review-wording")).toHaveCount(0);
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    expect(await page.locator("#message-header").inputValue()).not.toBe(long);

    await captureMessageReference(page, testInfo, "form-message", "1440");
  });

  test("a script can be chosen by keyboard at the narrow width @message", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(NARROW);
    await openMessage(page);

    await page.locator("#browse-scripts").click();
    await expect(page.locator("#message-scripts")).toBeVisible();
    expect(await fitsViewport(page)).toBe(true);

    // A script is a button, so Enter on the focused one is the keyboard's own
    // selection - the same text a click fills.
    const script = page.locator("#message-scripts-list li button").first();
    await script.focus();
    await expect(script).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page.locator("#message-scripts")).toHaveCount(0);
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    expect(await page.locator("#message-header").inputValue()).toContain("Route 1");
    expect(await fitsViewport(page)).toBe(true);

    // The narrow viewport is shorter than the card, so this capture is the whole
    // page: a cropped one would show the heading and no checks.
    await page.screenshot({
      path: capturePath(testInfo, "message-wording-320.png"),
      fullPage: true,
    });
    await captureMessageReference(page, testInfo, "form-message", "320");
  });
});

// The review step, as spec 30's step 22 renders it: the alert as a rider reads
// it, the facts beside it, the guidelines' own results, and Save alert in place
// of the prototype's Publish and Schedule (AC-23). Nothing here looks for a
// publication state or an action (R2, CR-1).

// The prototype states this view is compared against.
async function captureReviewReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `review-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// A delay is the shortest sequence that reaches the review, and the message
// step's Continue is the click that carries the reader on, so this walks the
// editor's own flow rather than opening a URL for a draft that never existed.
async function openReview(page) {
  await openMessage(page);

  await page.locator("#alert-message-continue").click();
  await page.waitForSelector("#alert-review", { timeout: 15_000 });
  return page.url();
}

// The same review with one question unanswered: the headline is cleared on the
// message step, which is the one answer this path can lose without walking a
// whole second sequence. A full page load leaves the view connecting, and a
// change made before the editor is mounted is never sent, so every step here
// waits for the editor the way the harness's own readiness signal says.
async function openIncompleteReview(page) {
  const url = await openReview(page);

  await page.goto(url.replace(/step=[a-z_]+/, "step=message"));
  await waitForEditorMounted(page);
  await page.locator("#message-header").fill("");
  await waitForSave(page);

  await page.goto(url.replace(/step=[a-z_]+/, "step=review"));
  await waitForEditorMounted(page);
  await page.locator("#save-alert").click();
  await page.waitForSelector("#review-errors", { timeout: 15_000 });

  return url;
}

test.describe("alert review", () => {
  test.describe.configure({ timeout: 120_000 });

  test("a finished alert is read back and Save alert keeps it @review", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openReview(page);

    // The words the editor stored are the words the review shows, beside the
    // facts it derived from the same answers.
    await expect(page.locator("#review-riders")).toBeVisible();
    await expect(page.locator("#review-header")).toContainText("Route 1");
    await expect(page.locator("#review-description")).toContainText("Route 1");
    await expect(page.locator("#review-when")).toContainText("Oct 1");
    await expect(page.locator("#review-where")).toContainText("Route 1");
    await expect(page.locator("#review-what")).toContainText("Delays");
    await expect(page.locator("#review-details")).toBeVisible();
    await expect(page.locator("#review-guidelines")).toBeVisible();
    await expect(page.locator("#review-check-short")).toBeVisible();

    // Saving an alert never publishes one in this package, so the editor's own
    // frame carries no publication state and no publication action.
    await expect(page.locator("#alert-editor")).not.toContainText(/Schedule/);
    await expect(page.locator("#alert-editor")).not.toContainText(/Publish/);

    await page.screenshot({
      path: capturePath(testInfo, "review-1440.png"),
      fullPage: false,
    });

    // Save alert is the whole action set of this step: with nothing
    // outstanding it finishes the draft and says so.
    await page.locator("#save-alert").click();
    await page.waitForURL(/\/alerts$/, { timeout: 15_000 });
    await expect(page.locator("#alerts-page")).toBeVisible();
    await expect(page.locator("#flash-group")).toContainText("Alert saved.");

    // The reference capture navigates away from the app, so it is last.
    await captureReviewReference(page, testInfo, "review-planned", "1440");
  });

  test("an unfinished alert lists what is missing and focuses the first @review", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    const url = await openIncompleteReview(page);

    // The refusal is a list, and each entry is a way through to the step that
    // answers it rather than a sentence to read (AC-23).
    await expect(page.locator("#review-errors")).toContainText(
      "This alert is not finished yet",
    );
    await expect(page.locator("#review-errors a")).toHaveCount(1);

    const first = page.locator("#review-errors a").first();

    await expect(first).toContainText("Write the headline riders will see.");
    await expect(first).toHaveAttribute("href", /step=message/);

    // Focus follows the refusal onto the first question, which is the one the
    // reader has to answer next.
    const focused = await page.evaluate(() => {
      const active = document.activeElement;
      return active ? active.textContent.trim() : null;
    });

    expect(focused).toBe("Write the headline riders will see.");

    // The editor stayed on the review, and the draft is still there.
    await expect(page.locator("#alert-question-title")).toContainText("Review alert");
    expect(page.url()).toBe(url);

    await page.screenshot({
      path: capturePath(testInfo, "review-errors-1440.png"),
      fullPage: false,
    });
  });

  test("the review reads at the narrow width @review", async ({ page }, testInfo) => {
    await page.setViewportSize(NARROW);
    await openReview(page);

    await expect(page.locator("#alert-review")).toBeVisible();
    await expect(page.locator("#alert-review-actions")).toBeVisible();
    await expect(page.locator("#save-alert")).toBeVisible();
    expect(await fitsViewport(page)).toBe(true);

    // The narrow viewport is shorter than the review, so this capture is the
    // whole page: a cropped one would show the rider card and no details.
    await page.screenshot({
      path: capturePath(testInfo, "review-320.png"),
      fullPage: true,
    });
    await captureReviewReference(page, testInfo, "review-now", "320");
  });
});

// Settings › Alerts, as spec 30's step 23 renders it: the Message scripts and
// Writing guidelines tabs, the scripts table with read-only built-ins, the
// script drawer with its placeholder reference, and the guidelines form
// (AC-24, AC-11). The prototype's Alert feed tab, Languages and Used columns
// and every publishing control are absent from both surfaces, because this
// package saves wording and never publishes an alert (R2, CR-1).

// The prototype states this view is compared against.
async function captureSettingsReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `settings-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// The drawer slides in over 300ms. Capturing before the panel settles
// photographs a panel still translated off the right edge, so the wait requires
// the panel's right edge to sit on the viewport edge and its animation to have
// finished.
async function settleScriptDrawer(page) {
  const panel = page.locator("#script-drawer");
  await panel.waitFor({ state: "visible" });
  await page.waitForFunction(
    () => {
      const element = document.querySelector("#script-drawer");
      if (!element) return false;

      const rect = element.getBoundingClientRect();
      const settled =
        Math.abs(rect.right - window.innerWidth) <= 2 && rect.left < window.innerWidth;
      const stillMoving = element
        .getAnimations()
        .some((animation) => animation.playState === "running");

      return settled && !stillMoving;
    },
    null,
    { timeout: 15_000 },
  );
}

// The version this tab opens against, resolved through the header's own version
// panel the way the other alert journeys resolve theirs.
async function alertsVersionId(page) {
  return versionIdFor(page, ALERTS_VERSION);
}

async function openAlertSettings(page, tab = "scripts") {
  await logIn(page, EDITOR);
  return openAlertSettingsSignedIn(page, tab);
}

// A second page of the same context is already signed in, so this skips the
// sign-in journey and goes straight to the page under test.
async function openAlertSettingsSignedIn(page, tab = "scripts") {
  const versionId = await alertsVersionId(page);
  await page.goto(`/gtfs/${versionId}/settings/alerts?tab=${tab}`);
  // A full page load leaves the view connecting, and a change made before it is
  // mounted is never sent, so every interaction here waits for the page itself.
  await page.waitForSelector("#alert-settings-page", { timeout: 15000 });
  await page.waitForSelector("#alert-settings-tabs[role='tablist']", { timeout: 15000 });
  return versionId;
}

test.describe("alert settings", () => {
  test.describe.configure({ timeout: 120_000 });

  test("the scripts tab lists the organization's scripts and the read-only built-ins @settings", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openAlertSettings(page);

    // The organization's own script comes first; the built-ins follow and each
    // one offers Copy to edit rather than Edit (AC-11, FH-24).
    await expect(page.locator("#scripts-status")).toContainText("1 script of your own");
    await expect(page.locator("#scripts-status")).toContainText("8 built-ins to copy");

    const rows = page.locator("#scripts tr");
    await expect(rows).toHaveCount(9);
    // An organization row carries two buttons: the name opens the drawer and
    // Edit is the same action in the actions column.
    await expect(rows.first()).toContainText("Route detour");
    await expect(rows.first().locator("#script-drawer-title")).toHaveCount(0);

    await expect(page.locator("#copy-builtin-detour")).toBeVisible();
    await expect(page.locator("#script-for-builtin-detour")).toContainText("Detour");
    await expect(page.locator("#copy-builtin-detour")).toHaveAttribute(
      "aria-label",
      /Copy to edit/,
    );

    await page.screenshot({
      path: capturePath(testInfo, "settings-scripts-1440.png"),
      fullPage: false,
    });

    // The narrow viewport is shorter than the table, so this capture is the
    // whole page: a cropped one would show the heading and no built-ins.
    await page.setViewportSize(NARROW);
    await expect(page.locator("#copy-builtin-suspension")).toBeVisible();
    expect(await fitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "settings-scripts-320.png"),
      fullPage: true,
    });

    await captureSettingsReference(page, testInfo, "settings-scripts", "1440");
  });

  test("a script is created, refused and copied in the drawer @settings", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openAlertSettings(page);

    await page.locator("#create-script").click();
    await page.waitForSelector("#script-form", { timeout: 15_000 });
    await settleScriptDrawer(page);
    await expect(page.locator("#script-fill-ins")).toContainText("Fill-ins");

    // An unknown placeholder is refused on the field that caused it, and the
    // templates that were typed stay in the form (R10, AC-24).
    await page.locator("#script-name").fill("Detour notice");
    await page.locator("#script-situation").selectOption("detour");
    await page.locator("#script-header").fill("[route] detour: [headline]");
    await page.locator("#script-description").fill("[route] is not serving [stop].");
    await page.locator("#script-save").click();

    await expect(page.locator("#script-header-error")).toContainText(
      "which this app does not fill in",
    );
    await expect(page.locator("#script-header")).toHaveValue("[route] detour: [headline]");
    await expect(page.locator("#script-description")).toHaveValue(
      "[route] is not serving [stop].",
    );

    await page.screenshot({
      path: capturePath(testInfo, "settings-script-error-1440.png"),
      fullPage: false,
    });

    // Correcting the placeholder stores the script; the built-in's own wording
    // is unchanged, so the organization starts from the recommended text.
    await page.locator("#script-header").fill("[route] detour: [stop] not served");
    await page.locator("#script-save").click();
    await page.waitForSelector("#script-notice", { timeout: 15_000 });
    await expect(page.locator("#script-notice")).toContainText("Detour notice saved.");
    await expect(page.locator("#scripts-status")).toContainText("2 scripts of your own");

    // Copy to edit creates an organization script from the read-only default and
    // opens that new row in the drawer, so one tenant's copy stays theirs.
    await page.locator("#copy-builtin-detour").click();
    await page.waitForSelector("#script-form", { timeout: 15_000 });
    await settleScriptDrawer(page);
    await expect(page.locator("#script-drawer-title")).toContainText("Edit script");
    await expect(page.locator("#script-name")).toHaveValue("Detour, stops skipped");
    await expect(page.locator("#script-header")).toHaveValue(
      "Route [route] detour: [first skipped] to [last skipped] not served",
    );
    await expect(page.locator("#scripts-status")).toContainText("3 scripts of your own");

    await page.screenshot({
      path: capturePath(testInfo, "settings-script-edit-1440.png"),
      fullPage: false,
    });

    await captureSettingsReference(page, testInfo, "settings-script-edit", "1440");
  });

  test("guidelines save and a stale revision says so @settings", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    const versionId = await openAlertSettings(page, "guidelines");

    // The recommended text is shown at revision 0, and reading it stored nothing.
    await expect(page.locator("#guidelines-revision")).toContainText(
      "Recommended guidelines, not changed yet",
    );
    await expect(page.locator("#guidelines-text")).toHaveValue(
      /Lead with the route and the change/,
    );
    await expect(page.locator("#guidelines-apply")).toContainText("Where these apply");

    await page.screenshot({
      path: capturePath(testInfo, "settings-guidelines-1440.png"),
      fullPage: false,
    });

    await page.locator("#guidelines-text").fill("Our own wording, one guideline per paragraph.");
    await page.locator("#save-guidelines").click();
    await page.waitForSelector("#guidelines-notice", { timeout: 15_000 });
    await expect(page.locator("#guidelines-notice")).toContainText("Guidelines saved.");
    await expect(page.locator("#guidelines-revision")).toContainText("Revision 1");

    // A second session's save moves the revision, so this tab's next save is a
    // stale one: it is refused with the conflict sentence rather than silently
    // overwriting (R6, FH-24).
    await page.locator("#guidelines-text").fill("A second wording from this tab.");
    // A second page of the same context shares the sign-in but starts on a blank
    // document, so the version is resolved from this tab rather than from a
    // header panel the new page has not rendered yet.
    const otherSession = await page.context().newPage();
    await otherSession.goto(
      `/gtfs/${versionId}/settings/alerts?tab=guidelines`,
    );
    await otherSession.waitForSelector("#guidelines-card", { timeout: 15000 });
    await otherSession.locator("#guidelines-text").fill("Another editor's wording.");
    await otherSession.locator("#save-guidelines").click();
    await otherSession.waitForSelector("#guidelines-revision:has-text('Revision 2')", {
      timeout: 15_000,
    });
    await otherSession.close();

    await page.locator("#save-guidelines").click();
    await page.waitForSelector("#guidelines-reload", { timeout: 15_000 });
    await expect(page.locator("#guidelines-notice")).toContainText(
      "Someone else changed these guidelines. Reload to see their version.",
    );
    await expect(page.locator("#guidelines-text")).toHaveValue(
      "A second wording from this tab.",
    );

    // Reload is the way through: it takes the other editor's text and its
    // revision rather than forcing this tab's own.
    await page.locator("#guidelines-reload").click();
    await expect(page.locator("#guidelines-reload")).toHaveCount(0);
    await expect(page.locator("#guidelines-text")).toHaveValue("Another editor's wording.");
    await expect(page.locator("#guidelines-revision")).toContainText("Revision 2");
  });

  test("the overview lists Alerts first under All versions @settings", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    const versionId = await openAlertSettings(page);

    await page.locator("#settings-back").click();
    await page.waitForURL(/\/settings$/, { timeout: 15_000 });

    const allVersions = page.locator("#settings-all-versions li");
    await expect(allVersions.first()).toHaveAttribute("id", "settings-entry-alerts");
    await expect(page.locator("#settings-entry-alerts a")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/settings/alerts`,
    );

    await page.screenshot({
      path: capturePath(testInfo, "settings-overview-1440.png"),
      fullPage: false,
    });
  });
});

// The assistant frame the editor opens in Assistant mode: the "Describe the
// situation" card `/alerts/new` shows before there is a draft to talk about
// (AC-28). The unavailable state that card also has to carry is a provider
// failure, and the provider is scripted in step 28; until then this journey
// observes the card itself at both widths.
// The assistant interview's reference capture, for the same side-by-side
// reading as the start card's.
async function captureInterviewReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `assistant-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// Drives the scripted Route 12 interview from the start card and returns the
// saved alert's URL. The scripted provider (test/support/agents/
// browser_open_router.ex) answers the turn with get_draft, search_routes and
// propose_changes, and the editor applies the prepared change itself, so the
// only thing this waits for is the applied result: the preview's own assistant
// tag. The helper asserts the row is a real alert before returning.
async function runRoute12Interview(page) {
  const versionId = await editorVersionId(page);

  await page.goto(`/gtfs/${versionId}/alerts/new?mode=assistant`);
  await page.waitForSelector("#alert-assistant-start", { timeout: 15_000 });

  await page.locator("#alert-assistant-example-1").click();
  await expect(page.locator("#alert-assistant-note")).toHaveValue(/Route 12 is detouring/);
  await page.locator("#alert-assistant-send").click();

  await page.waitForURL(/\/alerts\/[0-9a-f-]+\?/, { timeout: 20_000 });

  const url = page.url().split("?")[0];

  // The turn settles asynchronously in the session process; the preview's own
  // "Filled in by the assistant" tag is the signal that the prepared change
  // was applied, and the save bar that it was saved rather than only proposed.
  await expect(page.locator("#alert-preview-assistant")).toBeVisible({ timeout: 30_000 });
  await expect(page.locator("#alert-save-bar")).toContainText("Saved");

  return url;
}

test.describe("alert editor assistant", () => {
  test.describe.configure({ timeout: 120_000 });

  test("the new alert start card matches the prototype layout @assistant-start", async ({
    page,
  }, testInfo) => {
    const versionId = await editorVersionId(page);

    for (const viewport of [DESKTOP, NARROW]) {
      await page.setViewportSize(viewport);
      await page.goto(`/gtfs/${versionId}/alerts/new?mode=assistant`);
      await page.waitForSelector("#alert-assistant-start", { timeout: 15_000 });

      await expect(page.locator("#alert-editor")).toBeVisible();
      await expect(page.locator("#alert-mode")).toBeVisible();
      await expect(page.locator("#alert-assistant-start-title")).toHaveText(
        "Describe the situation",
      );

      // "Saving", not "publishing": nothing in this package publishes.
      await expect(page.locator("#alert-assistant-start-subtitle")).toContainText(
        "You check it before saving.",
      );
      await expect(page.locator("#alert-assistant-start-intro")).toContainText(
        "tell me what happened",
      );
      await expect(page.locator("#alert-assistant-note")).toBeVisible();
      await expect(page.locator("#alert-assistant-send")).toBeEnabled();
      await expect(page.locator("#alert-assistant-example-1")).toBeVisible();
      await expect(page.locator("#alert-save-bar")).toBeVisible();

      const body = await page.locator("#alert-editor").innerText();
      expect(body).not.toContain("review before publishing");
      expect(body).not.toContain("Data sent to apps");
      for (const word of ["Live", "Scheduled", "Ended", "End alert"]) {
        expect(body).not.toContain(word);
      }

      expect(await fitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, `assistant-start-${viewport.label}.png`),
        fullPage: false,
      });

      if (viewport === DESKTOP) {
        await captureAssistantReference(page, testInfo, "asst-start", viewport.label);
      }
    }
  });

  test("a sample situation fills the note rather than sending it @assistant-start", async ({
    page,
  }) => {
    const versionId = await editorVersionId(page);
    await page.setViewportSize(DESKTOP);
    await page.goto(`/gtfs/${versionId}/alerts/new?mode=assistant`);
    await page.waitForSelector("#alert-assistant-start", { timeout: 15_000 });

    await page.locator("#alert-assistant-example-1").click();

    await expect(page.locator("#alert-assistant-note")).toHaveValue(
      /Route 12 is detouring/,
    );

    // Nothing was created: the note is still the reader's to change.
    await expect(page.locator("#alert-save-bar")).toContainText("No alert saved yet.");
    await expect(page).toHaveURL(/\/alerts\/new\?mode=assistant/);
  });

  test("the Route 12 interview fills the preview @assistant", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await runRoute12Interview(page);

    // The rider preview reads the saved answers: the route the search returned
    // and the current-alert timing sentence the proposal carried. A detour that
    // names no skipped stop derives no effect of its own (R9), so the preview
    // asserts the route and the timing rather than an effect chip.
    await expect(page.locator("#alert-preview-where")).toContainText("Route 12");
    await expect(page.locator("#alert-preview-when")).toContainText("until further notice");
    await expect(page.locator("#alert-assistant-panel")).toBeVisible();
    await expect(page.locator("#alert-assistant")).toBeVisible();

    // The assistant's own last sentence, and nothing that claims a save or a
    // publication: the prepared change is the editor's to apply.
    await expect(page.locator("#agent-entries")).toContainText("I prepared a detour");
    const conversation = await page.locator("#agent-entries").innerText();
    expect(conversation).not.toMatch(/published|riders can see/i);

    expect(await fitsViewport(page)).toBe(true);

    for (const viewport of [DESKTOP, NARROW]) {
      await page.setViewportSize(viewport);
      await expect(page.locator("#alert-preview")).toBeVisible();
      await expect(page.locator("#alert-preview-where")).toContainText("Route 12");

      await page.screenshot({
        path: capturePath(testInfo, `assistant-ready-${viewport.label}.png`),
        fullPage: false,
      });
    }

    await captureInterviewReference(page, testInfo, "asst-ready", "1440");
  });

  test("switching to the Guided form shows the prepared answers @assistant", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    const url = await runRoute12Interview(page);

    // The mode control is the way out of assistant mode, and it keeps every
    // answer: the same row, read by the form.
    await page.locator('label[for="alert-mode-control-option-form"]').click();
    await page.waitForURL(/mode=form/, { timeout: 15_000 });
    await page.waitForSelector("#alert-question", { timeout: 15_000 });

    await page.goto(`${url}?mode=form&step=situation`);
    await page.waitForSelector("#situation-detour", { timeout: 15_000 });
    await expect(page.locator("#situation-detour")).toHaveAttribute("aria-pressed", "true");

    // The route question offers what a search returns, so the chosen route is
    // visible after the same search a reader would type.
    await page.goto(`${url}?mode=form&step=routes`);
    await page.waitForSelector("#alert-route-search", { timeout: 15_000 });
    await page.locator("#alert-route-search").pressSequentially("Route 1");
    await page.waitForSelector("#alert-route-options button[aria-pressed='true']", {
      timeout: 15_000,
    });
    await expect(
      page.locator("#alert-route-options button[aria-pressed='true']"),
    ).toContainText("Route 12");
    await expect(page.locator("#alert-routes-count")).toContainText("1 route selected");

    await page.screenshot({
      path: capturePath(testInfo, "assistant-in-form-1440.png"),
      fullPage: false,
    });

    await captureInterviewReference(page, testInfo, "asst-in-form", "1440");
  });
});

// The cross-scenario keyboard journeys, as spec 30's step 29 lays them out:
// the six situations an operator actually writes, each walked from `/alerts/new`
// through the questions its own sequence puts in front of them, with the refresh
// and second-tab recoveries beside them.
//
// Every answer here is made the way a keyboard user makes it: a card or a
// button is focused and Enter is pressed, a search is typed into, a checkbox is
// focused and Space is pressed. Nothing in this block calls `click()` on a
// question, because a journey that only proves the pointer path cannot show
// that the editor is operable without one. A native `<select>` is the one
// control a keyboard drives through its own value rather than through keys
// Playwright can synthesise per option, so it is set with `selectOption`.

// The prototype state a journey's final review is compared against. The
// reference file lives in the gitignored `.specs/` workspace, so a checkout
// without it skips the reference capture rather than failing.
async function captureJourneyReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  await page.goto(`file://${REFERENCE_PATH}?state=${state}`);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `journey-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

// A new alert opened in the form mode whatever any earlier test stored as the
// reader's default: an authoring journey that landed on the assistant's start
// card would be testing the wrong surface (FH-28's own lesson).
async function openJourneyAlert(page) {
  const versionId = await editorVersionId(page);
  await page.goto(`/gtfs/${versionId}/alerts/new?mode=form`);
  await page.waitForSelector("#alert-question", { timeout: 15_000 });
  await waitForEditorMounted(page);
  return versionId;
}

// A card or a button is a real button, so Enter on the focused one is the
// keyboard's own selection and stores exactly what a click stores.
async function pressChoice(page, selector) {
  const control = page.locator(selector);
  await control.focus();
  await expect(control).toBeFocused();
  await page.keyboard.press("Enter");
}

// The route search is typed into and the result is chosen with the keyboard,
// matching the label span rather than the button's own padded text: "Route 12"
// and "Route 50" both contain "Route 1".
async function chooseRoute(page, label) {
  const search = page.locator("#alert-route-search");
  await search.focus();
  await expect(search).toBeFocused();
  await search.pressSequentially(label);
  await page.waitForSelector("#alert-route-options button", {
    timeout: 15_000,
  });
  await pressChoice(
    page,
    "#alert-route-options button:has(span.font-semibold:text-is('" +
      label +
      "'))",
  );
  await expect(
    page.locator(
      "#alert-route-options button:has(span.font-semibold:text-is('" +
        label +
        "'))",
    ),
  ).toHaveAttribute("aria-pressed", "true");
}

// The agency's own today, read from the zone the timing card names and computed
// in the browser rather than taken from the machine's clock, so the date this
// journey types is the day the server is on (CR-7).
async function agencyToday(page) {
  const text = await page.locator("#alert-timing-zone").innerText();
  const zone = text.trim().split(/\s+/).pop().replace(/\.$/, "");

  return page.evaluate(
    (timeZone) =>
      new Intl.DateTimeFormat("en-CA", { timeZone }).format(new Date()),
    zone,
  );
}

// A date input is typed the way the segments take it rather than filled as one
// value, because a date a keyboard cannot reach is a date a keyboard user
// cannot choose.
async function typeDate(page, selector, iso) {
  const [year, month, day] = iso.split("-");
  const field = page.locator(selector);
  await field.focus();
  await expect(field).toBeFocused();
  await field.pressSequentially(`${month}${day}${year}`);
  await expect(field).toHaveValue(iso);
}

// A current disruption's own answer: an estimate keeps the alert live, so it
// asks when staff check back rather than when service recovers.
async function answerCurrentTiming(page, startTime) {
  await pressChoice(page, "#alert-timing-end-kind-estimated");
  await expect(page.locator("#timing-check-in")).toBeVisible();
  await page.locator("#timing-check-in").selectOption({ index: 2 });
  await expect(page.locator("#alert-save-status")).toHaveText("Saved");

  await typeDate(page, "#timing-start-date", await agencyToday(page));
  await page.locator("#timing-start-time").fill(startTime);
  await expect(page.locator("#alert-save-status")).toHaveText("Saved");

  await pressChoice(page, "#alert-timing-continue");
  await page.waitForSelector("#alert-reason", { timeout: 15_000 });
}

// The urgency, situation and mode questions every situation starts with, on the
// seeded version's own three route types.
async function startJourney(page, urgency, situation) {
  await pressChoice(page, `#alert-urgency-${urgency}`);
  await page.waitForURL(/step=situation/, { timeout: 15_000 });
  await pressChoice(page, `#situation-${situation}`);

  await page.waitForSelector("#mode-3", { timeout: 15_000 });
  await pressChoice(page, "#mode-3");
}

// The place combobox: typed into, then the keyboard picks from the same list a
// pointer would, and the identity is stored by the form's own change (R7).
async function choosePlace(page) {
  const search = page.locator("#place_stop_id_text_input");
  await search.focus();
  await expect(search).toBeFocused();
  await search.pressSequentially("Newport Transit Center");
  await page.waitForSelector("#alert-place-stop ul li div[data-idx]", {
    timeout: 15_000,
  });
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  await expect(page.locator("#alert-save-status")).toHaveText("Saved");
}

// A journey's final review, captured at both widths. The narrow viewport is
// shorter than the card, so that capture is the whole page: a cropped one would
// show the heading and nothing else.
async function captureJourneyReview(page, testInfo, scenario) {
  await expect(page.locator("#alert-review")).toBeVisible();
  await expect(page.locator("#review-errors")).toHaveCount(0);
  expect(await fitsViewport(page)).toBe(true);

  await page.screenshot({
    path: capturePath(testInfo, `journey-${scenario}-1440.png`),
    fullPage: false,
  });

  await page.setViewportSize(NARROW);
  expect(await fitsViewport(page)).toBe(true);
  await page.screenshot({
    path: capturePath(testInfo, `journey-${scenario}-320.png`),
    fullPage: true,
  });
  await page.setViewportSize(DESKTOP);
}

// The alert's own identity, read from the URL the editor is on, so a row on the
// list is matched by the row this journey wrote rather than by its wording.
function alertIdFrom(page) {
  return page.url().split("?")[0].split("/").pop();
}

test.describe("alert authoring journeys", () => {
  // Each journey walks a whole situation's sequence from the first question to
  // the review, and one of them walks it twice at two widths, so these carry
  // more than a single question's budget.
  test.describe.configure({ timeout: 240_000 });

  test("an urgent Route 1 delay with a check-in completes and lists under Current @journey", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openJourneyAlert(page);

    await startJourney(page, "now", "delay");

    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    await chooseRoute(page, "Route 1");
    await pressChoice(page, "#alert-routes-continue");

    await page.waitForSelector("#direction-0", { timeout: 15_000 });
    await pressChoice(page, "#direction-0");

    await page.waitForSelector("#alert-timing", { timeout: 15_000 });
    await answerCurrentTiming(page, "08:00");

    // A cause is a self-contained answer, so choosing it is what carries the
    // reader on to the message step, where the wording is generated.
    await pressChoice(page, "#alert-cause-weather");
    await page.waitForSelector("#alert-message", { timeout: 15_000 });
    await expect(page.locator("#message-origin")).toContainText("Delays");

    await pressChoice(page, "#alert-message-continue");
    await page.waitForSelector("#alert-review", { timeout: 15_000 });

    await expect(page.locator("#review-where")).toContainText("Route 1");
    await expect(page.locator("#review-what")).toContainText("Delays");
    // An estimate leaves the end open, so the review reads as open-ended
    // rather than naming a recovery time nobody chose (AC-20).
    await expect(page.locator("#review-when")).toContainText(
      "until further notice",
    );

    const alertId = alertIdFrom(page);
    await captureJourneyReview(page, testInfo, "delay");

    // Saving finishes the draft and returns to the list, where an alert with no
    // end date and a first date that has arrived is Current, not Upcoming.
    await pressChoice(page, "#save-alert");
    await page.waitForURL(/\/alerts$/, { timeout: 15_000 });
    await expect(page.locator("#alerts-tab-current")).toHaveAttribute(
      "aria-selected",
      "true",
    );
    await expect(page.locator(`#alert-link-${alertId}`)).toBeVisible();

    await captureJourneyReference(page, testInfo, "review-now", "1440");
  });

  test("a Route 1 detour past the shared stop takes Route 12 with it and completes @journey", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openJourneyAlert(page);

    await startJourney(page, "now", "detour");

    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    await chooseRoute(page, "Route 1");
    await pressChoice(page, "#alert-routes-continue");

    await page.waitForSelector("#alert-stops", { timeout: 15_000 });
    await pressChoice(
      page,
      "#alert-stops-list button:has-text('Newport Transit Center')",
    );
    await pressChoice(page, "#alert-stops-continue");

    // The stop Route 1 and Route 12 share is what raises the other-route
    // question, and answering yes makes the pairs at that stop affected too
    // (AC-18).
    await page.waitForSelector("#alert-shared", { timeout: 15_000 });
    await expect(page.locator("#alert-shared fieldset")).toContainText(
      "Route 12 also stops at Newport Transit Center",
    );
    await pressChoice(page, "#alert-shared button[id$='-yes']");

    await page.waitForSelector("#alert-boarding", { timeout: 15_000 });
    const search = page.locator("#alternative_stop_id_text_input");
    await search.focus();
    await search.pressSequentially("N Coast");
    await page.waitForSelector("#alert-boarding-stop ul li div[data-idx]", {
      timeout: 15_000,
    });
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("Enter");
    await expect(page.locator("#alternative_stop_id")).not.toHaveValue("");
    await pressChoice(page, "#alert-alternative-continue");

    await page.waitForSelector("#alert-timing", { timeout: 15_000 });
    await answerCurrentTiming(page, "08:00");

    await pressChoice(page, "#alert-cause-weather");
    await page.waitForSelector("#alert-message", { timeout: 15_000 });
    await pressChoice(page, "#alert-message-continue");
    await page.waitForSelector("#alert-review", { timeout: 15_000 });

    // The affected pairs are the routes the review reads, so Route 12 is named
    // beside Route 1 without the reader having chosen it on the routes card.
    await expect(page.locator("#review-where")).toContainText("Route 1");
    await expect(page.locator("#review-where")).toContainText("Route 12");

    await captureJourneyReview(page, testInfo, "detour");
    await captureJourneyReference(page, testInfo, "review-now", "1440");
  });

  test("a moved stop completes once its place carries a written alternative @journey", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openJourneyAlert(page);

    await startJourney(page, "now", "stop_moved");

    // The place question names the stop, and Continue is what carries the
    // reader on to the routes the place preselected (AC-18, INV-2).
    await page.waitForSelector("#alert-place", { timeout: 15_000 });
    await choosePlace(page);
    await pressChoice(page, "#alert-place-continue");

    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    await expect(page.locator("#alert-routes-count")).toContainText(
      "2 routes selected",
    );
    await pressChoice(page, "#alert-routes-continue");

    // A moved stop must say where riders go instead, so the question refuses to
    // advance on nothing.
    await page.waitForSelector("#alert-boarding", { timeout: 15_000 });
    await pressChoice(page, "#alert-alternative-continue");
    await expect(page.locator("#alert-alternative-error")).toContainText(
      "Choose a stop to board at, or write directions instead.",
    );

    await pressChoice(page, "#write-directions");
    await page.waitForSelector("#write-directions-field", { timeout: 15_000 });
    const directions = page.locator("#write-directions-field");
    await directions.focus();
    await directions.pressSequentially(
      "Board at the temporary stop on NE Main St.",
    );
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");
    await pressChoice(page, "#alert-alternative-continue");

    await page.waitForSelector("#alert-timing", { timeout: 15_000 });
    await answerCurrentTiming(page, "08:00");

    await pressChoice(page, "#alert-cause-weather");
    await page.waitForSelector("#alert-message", { timeout: 15_000 });
    await pressChoice(page, "#alert-message-continue");
    await page.waitForSelector("#alert-review", { timeout: 15_000 });

    await expect(page.locator("#review-what")).toContainText("Stop moved");
    await expect(page.locator("#review-errors")).toHaveCount(0);

    await captureJourneyReview(page, testInfo, "stop-moved");
    await captureJourneyReference(page, testInfo, "review-now", "1440");
  });

  test("a dated cancellation of two Route 1 departures completes without a timing question @journey", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openJourneyAlert(page);

    await startJourney(page, "now", "cancelled_trips");

    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    await chooseRoute(page, "Route 1");
    await pressChoice(page, "#alert-routes-continue");

    // A cancellation's period is the service dates of the departures it names,
    // so this sequence has no timing question at all (AC-19, INV-2).
    await expect(page.locator("#alert-step-timing")).toHaveCount(0);

    await page.waitForSelector("#alert-departures", { timeout: 15_000 });
    const first_date = await firstDepartureDate(page);
    const second_date = await addDayAfter(page, first_date);

    const first_list = page.locator(`#alert-departure-list-${first_date}`);
    const second_list = page.locator(`#alert-departure-list-${second_date}`);

    const first_box = first_list.locator("input[type='checkbox']").first();
    await first_box.focus();
    await expect(first_box).toBeFocused();
    await page.keyboard.press("Space");
    await expect(first_box).toBeChecked();

    const second_box = second_list.locator("input[type='checkbox']").nth(1);
    await second_box.focus();
    await page.keyboard.press("Space");
    await expect(second_box).toBeChecked();
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    await pressChoice(page, "#alert-departures-continue");

    await page.waitForSelector("#alert-reason", { timeout: 15_000 });
    await pressChoice(page, "#alert-cause-weather");
    await page.waitForSelector("#alert-message", { timeout: 15_000 });
    await pressChoice(page, "#alert-message-continue");
    await page.waitForSelector("#alert-review", { timeout: 15_000 });

    await expect(page.locator("#review-what")).toContainText("No service");
    await expect(page.locator("#review-where")).toContainText("Route 1");

    await captureJourneyReview(page, testInfo, "cancellation");
    await captureJourneyReference(page, testInfo, "review-now", "1440");
  });

  test("planned night work for two weeks loses one Friday and the review reads nine dates @journey", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openJourneyAlert(page);

    await startJourney(page, "planned", "delay");

    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    await chooseRoute(page, "Route 1");
    await pressChoice(page, "#alert-routes-continue");

    await page.waitForSelector("#direction-0", { timeout: 15_000 });
    await pressChoice(page, "#direction-0");

    await page.waitForSelector("#alert-timing", { timeout: 15_000 });
    await pressChoice(page, "#alert-timing-pattern-weekly");
    await typeDate(page, "#timing-first-date", "2026-10-05");
    await page.locator("#timing-weeks").fill("2");

    for (const day of [1, 2, 3, 4, 5]) {
      await pressChoice(page, `#timing-weekday-${day}`);
    }

    // Until is at or before From, so each night ends the next morning.
    await page.locator("#timing-day-start").fill("20:00");
    await page.locator("#timing-day-end").fill("05:00");
    await expect(page.locator("#alert-timing-count")).toContainText(
      "10 days: Oct 5 to Oct 16",
    );

    await typeDate(page, "#timing-date", "2026-10-09");
    await page.keyboard.press("Tab");
    await expect(page.locator("#add-timing-date")).toBeFocused();
    await page.keyboard.press("Enter");

    // Nine nights are what the pattern now covers, listed one date at a time.
    await expect(page.locator("#alert-timing-count")).toContainText(
      "9 days: Oct 5 to Oct 16",
    );
    await expect(page.locator("#alert-timing-occurrences > li")).toHaveCount(9);
    await expect(
      page.locator("#alert-timing-occurrence-2026-10-09"),
    ).toHaveCount(0);

    await pressChoice(page, "#alert-timing-continue");
    await page.waitForSelector("#alert-reason", { timeout: 15_000 });
    await pressChoice(page, "#alert-cause-construction");
    await page.waitForSelector("#alert-message", { timeout: 15_000 });
    await pressChoice(page, "#alert-message-continue");
    await page.waitForSelector("#alert-review", { timeout: 15_000 });

    // The review reads the pattern and the exception in one sentence, which is
    // what nine dates and one removal look like to a rider (AC-20).
    await expect(page.locator("#review-when")).toContainText("Oct 5 to Oct 16");
    await expect(page.locator("#review-when")).toContainText(
      "except Fri Oct 9",
    );

    await captureJourneyReview(page, testInfo, "night-work");
    await captureJourneyReference(page, testInfo, "review-planned", "1440");
  });

  test("an accessibility issue names the facility it closes and completes @journey", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openJourneyAlert(page);

    await startJourney(page, "now", "accessibility");

    await page.waitForSelector("#alert-place", { timeout: 15_000 });
    await choosePlace(page);
    await pressChoice(page, "#alert-place-continue");

    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    await pressChoice(page, "#alert-routes-continue");

    // An accessibility question adds the facility riders cannot use to the
    // alternatives it already asks for (AC-18).
    await page.waitForSelector("#alert-alternative", { timeout: 15_000 });
    const facility = page.locator("#alert_scope_facility");
    await facility.focus();
    await facility.pressSequentially("North entrance ramp");
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    await pressChoice(page, "#write-directions");
    await page.waitForSelector("#write-directions-field", { timeout: 15_000 });
    const directions = page.locator("#write-directions-field");
    await directions.focus();
    await directions.pressSequentially(
      "Use the south entrance ramp, which is step-free.",
    );
    await pressChoice(page, "#alert-alternative-continue");

    await page.waitForSelector("#alert-timing", { timeout: 15_000 });
    await answerCurrentTiming(page, "08:00");

    await pressChoice(page, "#alert-cause-weather");
    await page.waitForSelector("#alert-message", { timeout: 15_000 });
    await pressChoice(page, "#alert-message-continue");
    await page.waitForSelector("#alert-review", { timeout: 15_000 });

    // An accessibility issue stays an accessibility issue rather than becoming
    // a closure (R9).
    await expect(page.locator("#review-what")).toContainText(
      "Accessibility issue",
    );

    await captureJourneyReview(page, testInfo, "accessibility");
    await captureJourneyReference(page, testInfo, "review-now", "1440");
  });

  test("reloading during typing keeps the wording, and another tab's save says so @journey", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openJourneyAlert(page);

    await startJourney(page, "now", "delay");

    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    await chooseRoute(page, "Route 1");
    await pressChoice(page, "#alert-routes-continue");
    await page.waitForSelector("#direction-0", { timeout: 15_000 });
    await pressChoice(page, "#direction-0");

    await page.waitForSelector("#alert-timing", { timeout: 15_000 });
    await answerCurrentTiming(page, "08:00");
    await pressChoice(page, "#alert-cause-weather");
    await page.waitForSelector("#alert-message", { timeout: 15_000 });

    const url = page.url().split("?")[0];
    const header = page.locator("#message-header");
    await header.focus();
    await header.pressSequentially("Route 1 delayed by a stalled truck");
    await expect(page.locator("#alert-save-status")).toHaveText("Saved");

    // A reload inside the browser's own recovery window is the same question
    // with the same answer, because the draft is on the server (AC-16).
    await page.waitForTimeout(2000);
    await page.reload();
    await waitForEditorMounted(page);
    await expect(page.locator("#message-header")).toHaveValue(
      "Route 1 delayed by a stalled truck",
    );

    // A second tab holding the same alert at the same revision saves first,
    // which is the interleaving AC-16 describes.
    const other = await page.context().newPage();
    await other.goto(`${url}?mode=form&step=message`);
    await other.waitForSelector("#message-header", { timeout: 15_000 });
    const other_header = other.locator("#message-header");
    await other_header.focus();
    await other_header.pressSequentially("Saved in the other tab");
    await expect(other.locator("#alert-save-status")).toHaveText("Saved");
    await other.close();

    await header.focus();
    await header.pressSequentially("Typed in this tab");
    await expect(page.locator("#alert-conflict")).toBeVisible();
    await expect(page.locator("#alert-conflict")).toContainText(
      "another tab or by another editor",
    );
    await expect(page.locator("#alert-save-status")).toHaveText("Not saved.");

    // Load latest takes the other side of the conflict, and nothing else does.
    await pressChoice(page, "#conflict-load-latest");
    await expect(page.locator("#alert-conflict")).toHaveCount(0);
    await expect(page.locator("#message-header")).toHaveValue(
      "Saved in the other tab",
    );

    // The recovered draft is still a complete one, so the journey ends where
    // every other journey ends.
    await pressChoice(page, "#alert-message-continue");
    await page.waitForSelector("#alert-review", { timeout: 15_000 });
    await captureJourneyReview(page, testInfo, "conflict");
    await captureJourneyReference(page, testInfo, "review-now", "1440");
  });

  test("no question on the way to a review overflows the narrow width @journey", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(NARROW);
    await openJourneyAlert(page);

    const assertFits = async () => expect(await fitsViewport(page)).toBe(true);

    await assertFits();

    await pressChoice(page, "#alert-urgency-now");
    await page.waitForURL(/step=situation/, { timeout: 15_000 });
    await assertFits();

    await pressChoice(page, "#situation-stop_moved");
    await page.waitForSelector("#alert-place", { timeout: 15_000 });
    await assertFits();

    await choosePlace(page);
    await assertFits();

    await pressChoice(page, "#alert-place-continue");
    await page.waitForSelector("#alert-routes-continue", { timeout: 15_000 });
    await assertFits();

    await pressChoice(page, "#alert-routes-continue");
    await page.waitForSelector("#alert-boarding", { timeout: 15_000 });
    await assertFits();

    await pressChoice(page, "#write-directions");
    await page.waitForSelector("#write-directions-field", { timeout: 15_000 });
    await assertFits();

    const directions = page.locator("#write-directions-field");
    await directions.focus();
    await directions.pressSequentially("Board on NE Main St.");
    await pressChoice(page, "#alert-alternative-continue");

    await page.waitForSelector("#alert-timing", { timeout: 15_000 });
    await assertFits();
    await answerCurrentTiming(page, "08:00");
    await assertFits();

    await pressChoice(page, "#alert-cause-weather");
    await page.waitForSelector("#alert-message", { timeout: 15_000 });
    await assertFits();

    await pressChoice(page, "#alert-message-continue");
    await page.waitForSelector("#alert-review", { timeout: 15_000 });
    await assertFits();

    await page.screenshot({
      path: capturePath(testInfo, "journey-narrow-review-320.png"),
      fullPage: true,
    });

    expect(await fitsViewport(page)).toBe(true);
  });
});
