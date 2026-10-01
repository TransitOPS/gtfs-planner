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
