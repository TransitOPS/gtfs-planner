import { test, expect } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  loginAndGoToDiagram,
  selectDiagramMode,
} from "./station_diagram_helpers.js";

const here = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(here, "../..");
const referenceRoot = resolve(repositoryRoot, ".specs/journal-02/visual-references");
const artifactRoot = resolve(repositoryRoot, ".artifacts/journal-02");
const pkg3ReferenceRoot = resolve(repositoryRoot, ".specs/journal-03/visual-references");
const pkg3ArtifactRoot = resolve(repositoryRoot, ".artifacts/journal-03");
const pkg4ReferenceRoot = resolve(repositoryRoot, ".specs/journal-04/visual-references");
const pkg4ArtifactRoot = resolve(repositoryRoot, ".artifacts/journal-04");

const PHOTO_ENTRY_ID = "00000000-0000-4000-8000-000000000701";
const CLOSED_ENTRY_ID = "00000000-0000-4000-8000-000000000702";
const SECOND_OPEN_ENTRY_ID = "00000000-0000-4000-8000-000000000703";
const PENDING_ENTRY_ID = "00000000-0000-4000-8000-0000000007f0";
const L2_PIN_ENTRY_ID = "00000000-0000-4000-8000-000000000712";

const diagramUser = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

test.use({ viewport: { width: 1440, height: 900 } });

async function openJournal(page) {
  await loginAndGoToDiagram(page);

  const trigger = page.locator("#journal-trigger");
  await expect(trigger).toBeVisible();
  await expect(trigger).toHaveAttribute("aria-expanded", "false");
  await trigger.click();

  const panel = page.locator("#station-journal-panel");
  await expect(panel).toBeVisible();
  await expect(trigger).toHaveAttribute("aria-expanded", "true");
  await expect(panel.locator("#journal-entry-list")).toBeVisible();
  await expect(panel.locator('[data-role="journal-entry"]')).not.toHaveCount(0);

  return panel;
}

function journalRow(panel, entryId) {
  return panel.locator(`[data-role="journal-entry"][data-entry-id="${entryId}"]`);
}

async function expectFocusInsidePage(page) {
  await expect
    .poll(() => page.evaluate(() => document.activeElement?.tagName))
    .not.toBe("BODY");
}

async function apiJournalWriter(page) {
  const login = await page.request.post("/api/v1/auth/login", {
    data: diagramUser,
  });
  expect(login.ok()).toBe(true);

  const loginData = (await login.json()).data;
  const headers = {
    authorization: `Bearer ${loginData.token}`,
    "x-organization-id": loginData.organization_id,
  };

  const versionsResponse = await page.request.get("/api/v1/versions", { headers });
  expect(versionsResponse.ok()).toBe(true);
  const versions = (await versionsResponse.json()).data;
  const version = versions.find(({ name }) => name === "Browser E2E Version");
  expect(version).toBeTruthy();

  const stationsResponse = await page.request.get(
    `/api/v1/versions/${version.id}/stations`,
    { headers },
  );
  expect(stationsResponse.ok()).toBe(true);
  const stations = (await stationsResponse.json()).data;
  const station = stations.find(({ stop_id }) => stop_id === "BROWSER_STATION");
  expect(station).toBeTruthy();

  return async () => {
    const response = await page.request.post(
      `/api/v1/versions/${version.id}/stations/${station.id}/sync`,
      {
        headers,
        data: {
          pathways: [],
          journal_entries: [
            {
              id: PENDING_ENTRY_ID,
              target_type: "station",
              body: "New field observation received while the journal was scrolled.",
              captured_at: "2026-07-22T12:30:00Z",
            },
          ],
        },
      },
    );

    expect(response.ok()).toBe(true);
    expect((await response.json()).data.journal_synced_count).toBe(1);
  };
}

test("Package 03 marker palette resolves amber token and captures reference", async ({ page }) => {
  await mkdir(pkg3ArtifactRoot, { recursive: true });

  await page.goto(
    pathToFileURL(resolve(pkg3ReferenceRoot, "mock-02-floorplans-view.html")).href,
    { waitUntil: "networkidle" },
  );
  await page.evaluate(() => document.fonts.ready);

  const referenceHeading = page.getByText("Mock 02 · Floorplans — View mode, journal closed", { exact: false });
  await expect(referenceHeading).toBeVisible();

  await page.screenshot({ path: resolve(pkg3ArtifactRoot, "reference-marker-palette.png") });

  await loginAndGoToDiagram(page);

  const diagramPage = page.locator("#diagram-page");
  await expect(diagramPage).toBeVisible();

  const journalOpenVar = await diagramPage.evaluate((el) =>
    getComputedStyle(el).getPropertyValue("--diagram-journal-open").trim().toUpperCase()
  );
  expect(journalOpenVar).toBe("#B45309");

  await page.screenshot({
    path: resolve(pkg3ArtifactRoot, "production-marker-palette.png"),
    animations: "disabled",
  });
});

test("Package 03 marker shell and legend", async ({ page }) => {
  await mkdir(pkg3ArtifactRoot, { recursive: true });

  await page.goto(
    pathToFileURL(resolve(pkg3ReferenceRoot, "mock-02-floorplans-view.html")).href,
    { waitUntil: "networkidle" }
  );
  await page.evaluate(() => document.fonts.ready);

  const referenceHeading = page.getByText("Mock 02 · Floorplans — View mode, journal closed", { exact: false });
  await expect(referenceHeading).toBeVisible();

  await page.screenshot({ path: resolve(pkg3ArtifactRoot, "reference-marker-anatomy.png") });

  await loginAndGoToDiagram(page);

  const diagramPage = page.locator("#diagram-page");
  await expect(diagramPage).toBeVisible();

  const markerStream = page.locator("#journal-markers-svg");
  await expect(markerStream).toBeAttached();

  const keyButton = page.getByRole("button", { name: "Show Key" });
  await expect(keyButton).toBeVisible();
  await keyButton.click();

  const legendPanel = page.locator("#diagram-legend-panel");
  await expect(legendPanel).toBeVisible();
  await expect(legendPanel.getByText("Entry Pin")).toBeVisible();
  await expect(legendPanel.getByText("Entity Dot")).toBeVisible();

  await page.screenshot({
    path: resolve(pkg3ArtifactRoot, "production-marker-shell.png"),
    animations: "disabled",
  });
});

test("renders copied journal references", async ({ page }) => {
  await mkdir(artifactRoot, { recursive: true });

  await page.goto(
    pathToFileURL(resolve(referenceRoot, "mock-03-floorplans-journal-open.html")).href,
    { waitUntil: "networkidle" },
  );
  await page.evaluate(() => document.fonts.ready);

  const journalHeading = page.getByRole("heading", { name: "Journal", exact: true }).first();
  const idealRegion = journalHeading.locator(
    'xpath=ancestor::div[contains(@class, "w-[1360px]")][1]',
  );

  await expect(journalHeading).toBeVisible();
  await expect(page.getByRole("button", { name: /Journal/ })).toHaveAttribute(
    "aria-expanded",
    "true",
  );
  await expect(idealRegion.locator('aside[aria-label="Station journal"]')).toBeVisible();
  await idealRegion.screenshot({ path: resolve(artifactRoot, "reference-ideal.png") });

  await page.goto(
    pathToFileURL(resolve(referenceRoot, "mock-04-journal-panel-states.html")).href,
    { waitUntil: "networkidle" },
  );
  await page.evaluate(() => document.fonts.ready);

  const statesRegion = page.getByText("1 · LOADING", { exact: false }).locator(
    'xpath=ancestor::div[contains(@class, "grid-cols-4")][1]',
  );

  await expect(page.getByText("1 · LOADING", { exact: false })).toBeVisible();
  await expect(page.getByText("2 · FIRST-USE EMPTY", { exact: false })).toBeVisible();
  await expect(page.getByText("3 · FILTERED EMPTY", { exact: false })).toBeVisible();
  await expect(page.getByText("4 · ERROR", { exact: false })).toBeVisible();
  await statesRegion.screenshot({ path: resolve(artifactRoot, "reference-states.png") });
});

test("renders the production ideal hierarchy and canonical photo", async ({ page }) => {
  await mkdir(artifactRoot, { recursive: true });
  await page.emulateMedia({ reducedMotion: "reduce" });
  const panel = await openJournal(page);

  const row = journalRow(panel, PHOTO_ENTRY_ID);
  await expect(row.locator(`#journal-entry-target-${PHOTO_ENTRY_ID}`)).toContainText(
    "Node · Platform A North",
  );
  await expect(row.locator("time")).toHaveAttribute(
    "datetime",
    "2026-07-21T14:32:00.000000Z",
  );
  await expect(row.locator('[data-role="journal-note"]')).toBeVisible();
  await expect(row.getByRole("button", { name: "Edit node" })).toBeVisible();
  await expect(row.locator(`#journal-entry-toggle-${PHOTO_ENTRY_ID}`)).toHaveCount(0);
  await expect(row.locator(`#journal-show-entry-${PHOTO_ENTRY_ID}`)).toBeVisible();

  const photo = row.locator('button[id^="journal-photo-"]');
  await expect(photo).toHaveCount(1);
  await expect(photo).toHaveAttribute("phx-click", "open_journal_photo");
  await expect(photo.locator("img")).toHaveAttribute(
    "src",
    /\/uploads\/field-captures\/.+\.png$/,
  );
  await expect
    .poll(() => photo.locator("img").evaluate((image) => image.complete && image.naturalWidth > 0))
    .toBe(true);

  await page.evaluate(() => window.scrollTo(0, 0));
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({
    path: resolve(artifactRoot, "production-ideal.png"),
    animations: "disabled",
  });
});

test("shows every entry with no status controls", async ({ page }) => {
  const panel = await openJournal(page);

  await expect(journalRow(panel, PHOTO_ENTRY_ID)).toBeVisible();
  await expect(journalRow(panel, SECOND_OPEN_ENTRY_ID)).toBeVisible();
  await expect(journalRow(panel, CLOSED_ENTRY_ID)).toBeVisible();

  await expect(panel.locator("#journal-filter")).toHaveCount(0);
  await expect(panel.locator('button[id^="journal-close-entry-"]')).toHaveCount(0);
  await expect(panel.locator('button[id^="journal-reopen-entry-"]')).toHaveCount(0);
  await expect(panel.locator("#journal-count-summary")).toContainText(/\d+ entries/);
});

test("carries the journal note into the edit drawer", async ({ page }) => {
  const panel = await openJournal(page);
  const row = journalRow(panel, PHOTO_ENTRY_ID);
  const note = (await row.locator('[data-role="journal-note"]').innerText()).trim();

  await row.getByRole("button", { name: "Edit node" }).click();
  await expect(page.locator("#station-journal-panel")).toHaveCount(0);

  const contextBox = page.locator("#journal-form-context");
  await expect(contextBox).toBeVisible();
  await expect(contextBox).toContainText("Journal entry");
  await expect(contextBox).toContainText(note.slice(0, 30));

  await page.locator("#child-stop-drawer-close").click();
  await expect(contextBox).toHaveCount(0);
});

test("opens photos in an in-app viewer instead of a raw file tab", async ({ page }) => {
  const panel = await openJournal(page);
  const row = journalRow(panel, PHOTO_ENTRY_ID);
  const thumbnail = row.locator('button[id^="journal-photo-"]').first();

  await thumbnail.click();

  const viewer = page.locator("#journal-photo-viewer");
  await expect(viewer).toBeVisible();
  await expect(viewer).toHaveAttribute("aria-modal", "true");
  await expect(viewer.locator("img")).toBeVisible();
  await expect(viewer.locator("#journal-photo-viewer-close")).toBeFocused();
  await expect(viewer.locator("#journal-photo-viewer-original")).toHaveAttribute(
    "href",
    /\/uploads\/field-captures\/.+\.png$/,
  );

  await page.keyboard.press("Escape");
  await expect(viewer).toHaveCount(0);
  await expect(panel).toBeVisible();
  await expect(thumbnail).toBeFocused();

  await thumbnail.click();
  await expect(viewer).toBeVisible();
  await viewer.locator("#journal-photo-viewer-backdrop").click({ position: { x: 8, y: 8 } });
  await expect(viewer).toHaveCount(0);
  await expect(panel).toBeVisible();
});

test("returns focus after Escape, header close, and Align restoration", async ({ page }) => {
  let panel = await openJournal(page);

  await panel.locator(`#journal-show-entry-${PHOTO_ENTRY_ID}`).focus();
  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await expect(page.locator("#journal-trigger")).toBeFocused();

  await page.locator("#journal-trigger").click();
  panel = page.locator("#station-journal-panel");
  await expect(panel).toBeVisible();
  await panel.locator("#journal-panel-close").click();
  await expect(panel).toHaveCount(0);
  await expect(page.locator("#journal-trigger")).toBeFocused();

  await page.locator("#journal-trigger").click();
  await expect(panel).toBeVisible();
  await selectDiagramMode(page, "map");
  await expect(panel).toHaveCount(0);
  await expect(page.locator("#journal-trigger")).toHaveCount(0);
  await expect(page.locator('#diagram-mode input[value="map"]')).toBeFocused();

  await selectDiagramMode(page, "view");
  await expect(panel).toBeVisible();
  await expect(page.locator("#journal-trigger")).toHaveAttribute("aria-expanded", "true");
  await expect(page.locator('#diagram-mode input[value="view"]')).toBeFocused();
  await expectFocusInsidePage(page);
});

test("keeps scrolled rows stable and applies one identity-based pending entry", async ({
  page,
}) => {
  const sentJournalScrollFrames = [];
  page.on("websocket", (socket) => {
    socket.on("framesent", ({ payload }) => {
      const text = Buffer.isBuffer(payload) ? payload.toString("utf8") : String(payload);
      if (text.includes("journal_scroll_state")) sentJournalScrollFrames.push(text);
    });
  });

  const panel = await openJournal(page);
  const list = panel.locator("#journal-entry-list");
  const initialIds = await list
    .locator('[data-role="journal-entry"]')
    .evaluateAll((rows) => rows.map((row) => row.dataset.entryId));

  await expect
    .poll(() => list.evaluate((element) => element.scrollHeight > element.clientHeight))
    .toBe(true);
  await list.evaluate((element) => element.scrollTo({ top: element.scrollHeight, behavior: "auto" }));
  await expect.poll(() => list.evaluate((element) => element.scrollTop > 8)).toBe(true);
  await expect.poll(() => sentJournalScrollFrames.length).toBe(1);

  const writeEntry = await apiJournalWriter(page);
  await writeEntry();
  await expect(panel.locator("#journal-pending-entries")).toContainText("1 new entry");
  expect(
    await list
      .locator('[data-role="journal-entry"]')
      .evaluateAll((rows) => rows.map((row) => row.dataset.entryId)),
  ).toEqual(initialIds);

  await writeEntry();
  await expect(panel.locator("#journal-pending-entries")).toContainText("1 new entry");
  expect(
    await list
      .locator('[data-role="journal-entry"]')
      .evaluateAll((rows) => rows.map((row) => row.dataset.entryId)),
  ).toEqual(initialIds);
  expect(sentJournalScrollFrames).toHaveLength(1);

  await panel.locator("#journal-pending-entries").click();
  const newRow = panel.locator(`#journal-entries-${PENDING_ENTRY_ID}`);
  await expect(newRow).toBeVisible();
  await expect(newRow).toBeFocused();
  await expect(panel.locator("#journal-pending-entries")).toHaveCount(0);
  await expect.poll(() => list.evaluate((element) => element.scrollTop <= 8)).toBe(true);
  await expect.poll(() => sentJournalScrollFrames.length).toBe(2);
});

for (const width of [1280, 1440, 1920]) {
  test(`keeps the 340px push layout and minimum targets at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const panel = await openJournal(page);
    await expect(journalRow(panel, PHOTO_ENTRY_ID)).toBeVisible();

    const layout = await page.evaluate(() => {
      const panel = document.querySelector("#station-journal-panel");
      const canvas = document.querySelector("#diagram-canvas-wrapper");
      const workspace = document.querySelector("#diagram-workspace");
      const list = document.querySelector("#journal-entry-list");

      return {
        panelWidth: panel.getBoundingClientRect().width,
        canvasWidth: canvas.getBoundingClientRect().width,
        workspaceWidth: workspace.getBoundingClientRect().width,
        listOverflowY: getComputedStyle(list).overflowY,
        bodyOverflow: document.body.scrollWidth - window.innerWidth,
      };
    });

    expect(layout.panelWidth).toBe(340);
    expect(layout.canvasWidth).toBeLessThan(layout.workspaceWidth - 300);
    expect(layout.listOverflowY).toBe("auto");
    expect(layout.bodyOverflow).toBeLessThanOrEqual(2);

    const measureBoxes = (locator) =>
      locator.evaluateAll((targets) =>
        targets.map((target) => ({
          id: target.id || target.getAttribute("for"),
          width: target.getBoundingClientRect().width,
          height: target.getBoundingClientRect().height,
        })),
      );

    const standaloneBoxes = await measureBoxes(
      page.locator(
        `#journal-panel-close, #journal-photo-${"00000000-0000-4000-8000-0000000007a1"}`,
      ),
    );

    expect(standaloneBoxes.length).toBeGreaterThanOrEqual(2);
    for (const box of standaloneBoxes) {
      expect(box.width, `${box.id} width`).toBeGreaterThanOrEqual(44);
      expect(box.height, `${box.id} height`).toBeGreaterThanOrEqual(44);
    }

    // Compact inline controls trade the 44px square for a quieter queue; they
    // must still clear WCAG 2.5.8's 24px minimum with generous width.
    const compactBoxes = await measureBoxes(
      page.locator(
        `#journal-trigger, #journal-show-entry-${PHOTO_ENTRY_ID}, #journal-edit-target-${PHOTO_ENTRY_ID}`,
      ),
    );

    expect(compactBoxes.length).toBeGreaterThanOrEqual(3);
    for (const box of compactBoxes) {
      expect(box.width, `${box.id} width`).toBeGreaterThanOrEqual(44);
      expect(box.height, `${box.id} height`).toBeGreaterThanOrEqual(28);
    }
  });
}

test("keeps independent panel scrolling in Add and Connect", async ({ page }) => {
  const panel = await openJournal(page);

  for (const mode of ["add", "connect"]) {
    await selectDiagramMode(page, mode);
    await expect(panel).toBeVisible();
    const list = panel.locator("#journal-entry-list");

    const scrolling = await list.evaluate((element) => ({
      overflowY: getComputedStyle(element).overflowY,
      scrollable: element.scrollHeight > element.clientHeight,
    }));

    expect(scrolling.overflowY).toBe("auto");
    expect(scrolling.scrollable).toBe(true);
    expect(
      await page.evaluate(() => document.body.scrollWidth - window.innerWidth),
    ).toBeLessThanOrEqual(2);
  }
});

test("disables journal motion when reduced motion is requested", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  const panel = await openJournal(page);
  const row = journalRow(panel, PHOTO_ENTRY_ID);
  await expect(row).toBeVisible();

  const motion = await page.evaluate((entryId) => {
    const panel = document.querySelector("#station-journal-panel");
    const row = document.querySelector(`[data-entry-id="${entryId}"]`);
    const image = row.querySelector("img");

    return {
      panelTransition: getComputedStyle(panel).transitionDuration,
      rowAnimation: getComputedStyle(row).animationDuration,
      rowTransition: getComputedStyle(row).transitionDuration,
      imageTransition: getComputedStyle(image).transitionDuration,
    };
  }, PHOTO_ENTRY_ID);

  expect(motion).toEqual({
    panelTransition: "0s",
    rowAnimation: "0s",
    rowTransition: "0s",
    imageTransition: "0s",
  });
});

test("preserves the repository 200 percent zoom overflow contract", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const panel = await openJournal(page);
  await page.evaluate(() => {
    document.body.style.zoom = "2";
  });

  await expect(panel).toBeVisible();
  await expect(panel.locator("#journal-entry-list")).toBeVisible();

  const zoomed = await page.evaluate(() => ({
    panelWidth: getComputedStyle(document.querySelector("#station-journal-panel")).width,
    body: document.body.scrollWidth,
    viewport: window.innerWidth,
  }));

  expect(zoomed.panelWidth).toBe("340px");
  expect(zoomed.body).toBeLessThanOrEqual(zoomed.viewport + 2);
});

test("Package 03 marker to panel scoping and clear action", async ({ page }) => {
  await mkdir(pkg3ArtifactRoot, { recursive: true });
  await loginAndGoToDiagram(page);

  const diagramPage = page.locator("#diagram-page");
  await expect(diagramPage).toBeVisible();

  const nodeMarker = page.locator('#journal-markers-svg [data-journal-kind="node"]').first();
  await expect(nodeMarker).toBeVisible();
  await nodeMarker.click();

  const panel = page.locator("#station-journal-panel");
  await expect(panel).toBeVisible();
  await expectFocusInsidePage(page);

  const scopeBar = panel.locator("#journal-target-scope");
  await expect(scopeBar).toBeVisible();

  const clearBtn = panel.locator("#journal-clear-target-scope");
  await expect(clearBtn).toBeVisible();

  await page.evaluate(() => document.fonts.ready);
  const screenshotPath = resolve(pkg3ArtifactRoot, "production-marker-to-panel.png");
  console.log("SAVING SCREENSHOT TO:", screenshotPath);
  const buf = await page.screenshot({
    animations: "disabled",
  });
  const { writeFile } = await import("node:fs/promises");
  await writeFile(screenshotPath, buf);
  console.log("SCREENSHOT WRITTEN BYTES:", buf.length);

  await clearBtn.click();
  await expect(scopeBar).toHaveCount(0);
});

test("Package 03 Show on floorplan", async ({ page }) => {
  await mkdir(pkg3ArtifactRoot, { recursive: true });
  const panel = await openJournal(page);

  const showBtn = panel.locator(`#journal-show-entry-${PHOTO_ENTRY_ID}`);
  await expect(showBtn).toBeVisible();

  await showBtn.click();

  await expect(showBtn).toBeFocused();

  const ring = page.locator('#journal-markers-svg [data-journal-ring="true"]');
  await expect(ring).toBeVisible();

  await page.evaluate(() => document.fonts.ready);
  const screenshotPath = resolve(pkg3ArtifactRoot, "production-show-on-floorplan.png");
  console.log("SAVING SCREENSHOT TO:", screenshotPath);
  const buf = await page.screenshot({
    animations: "disabled",
  });
  const { writeFile } = await import("node:fs/promises");
  await writeFile(screenshotPath, buf);
  console.log("SCREENSHOT WRITTEN BYTES:", buf.length);
});

test("Package 03 marker keyboard activation opens panel with focus", async ({ page }) => {
  await loginAndGoToDiagram(page);

  const nodeMarker = page.locator('#journal-markers-svg [data-journal-kind="node"]').first();
  await expect(nodeMarker).toBeVisible();
  await nodeMarker.focus();
  await page.keyboard.press("Enter");

  const panel = page.locator("#station-journal-panel");
  await expect(panel).toBeVisible();
  await expect(panel.locator("#journal-target-scope")).toBeVisible();
  await expectFocusInsidePage(page);

  await panel.locator("#journal-clear-target-scope").click();
  await expect(panel.locator("#journal-target-scope")).toHaveCount(0);

  const pinMarker = page.locator('#journal-markers-svg [data-journal-kind="pin"]').first();
  await expect(pinMarker).toBeVisible();
  await pinMarker.focus();
  await page.keyboard.press("Space");

  await expect(panel.locator("#journal-entry-list")).toBeVisible();
  await expectFocusInsidePage(page);
});

test("Package 03 entity scope shows scoped entries and clear restores station view", async ({ page }) => {
  await loginAndGoToDiagram(page);

  const nodeMarkers = page.locator('#journal-markers-svg [data-journal-kind="node"]');
  await expect(nodeMarkers.first()).toBeVisible();

  const targetId = await nodeMarkers.first().getAttribute("data-journal-target-id");
  expect(targetId).toBeTruthy();
  await nodeMarkers.first().click();

  const panel = page.locator("#station-journal-panel");
  await expect(panel).toBeVisible();

  const scopeBar = panel.locator("#journal-target-scope");
  await expect(scopeBar).toBeVisible();

  const visibleRows = panel.locator('[data-role="journal-entry"]');
  const count = await visibleRows.count();
  expect(count).toBeGreaterThanOrEqual(1);

  await panel.locator("#journal-clear-target-scope").click();
  await expect(scopeBar).toHaveCount(0);

  const allRows = panel.locator('[data-role="journal-entry"]');
  const allCount = await allRows.count();
  expect(allCount).toBeGreaterThan(count);
});

test("Package 03 same-level Show on floorplan retains focus and renders one ring", async ({ page }) => {
  const panel = await openJournal(page);

  const showBtn = panel.locator(`#journal-show-entry-${PHOTO_ENTRY_ID}`);
  await expect(showBtn).toBeVisible();
  await showBtn.click();

  await expect(showBtn).toBeFocused();

  const rings = page.locator('#journal-markers-svg [data-journal-ring="true"]');
  await expect(rings).toHaveCount(1);
  await expect(rings.first()).toBeVisible();
});

test("Package 03 other-level Show on floorplan switches level and renders ring", async ({ page }) => {
  const panel = await openJournal(page);

  const showBtn = panel.locator(`#journal-show-entry-${L2_PIN_ENTRY_ID}`);
  await expect(showBtn).toBeVisible();
  await showBtn.click();

  await expect(showBtn).toBeFocused();

  const rings = page.locator('#journal-markers-svg [data-journal-ring="true"]');
  await expect(rings).toHaveCount(1);

  const levelIndicator = page.locator("#level-control-trigger");
  await expect(levelIndicator).toContainText("Browser Level 2");
});

test("Package 03 markers visible but inert in Add and Connect modes", async ({ page }) => {
  await loginAndGoToDiagram(page);

  const markers = page.locator("#journal-markers-svg [data-journal-marker]");
  await expect(markers.first()).toBeVisible();
  const markerCount = await markers.count();

  for (const mode of ["add", "connect"]) {
    await selectDiagramMode(page, mode);

    await expect(markers).toHaveCount(markerCount);

    const firstMarker = markers.first();
    const pointerEvents = await firstMarker.evaluate(
      (el) => getComputedStyle(el).pointerEvents,
    );
    expect(pointerEvents).toBe("none");

    const tabindex = await firstMarker.getAttribute("tabindex");
    expect(tabindex).toBeNull();

    const role = await firstMarker.getAttribute("role");
    expect(role).toBeNull();
  }
});

test("Package 03 no marker overlay in Align mode", async ({ page }) => {
  await loginAndGoToDiagram(page);

  await selectDiagramMode(page, "map");

  const markerSvg = page.locator("#journal-markers-svg");
  await expect(markerSvg).toHaveCount(0);
});

test("Package 03 reduced motion keeps markers usable", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await loginAndGoToDiagram(page);

  const nodeMarker = page.locator('#journal-markers-svg [data-journal-kind="node"]').first();
  await expect(nodeMarker).toBeVisible();

  const transition = await nodeMarker.evaluate(
    (el) => getComputedStyle(el).transitionDuration,
  );
  expect(transition).toBe("0s");

  await nodeMarker.click();
  const panel = page.locator("#station-journal-panel");
  await expect(panel).toBeVisible();
  await expectFocusInsidePage(page);
});

test("Package 03 panel scroll independent of canvas at multiple viewports", async ({ page }) => {
  const panel = await openJournal(page);

  for (const width of [1280, 1440, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    await expect(panel).toBeVisible();

    const list = panel.locator("#journal-entry-list");
    const scrolling = await list.evaluate((element) => ({
      overflowY: getComputedStyle(element).overflowY,
      scrollable: element.scrollHeight > element.clientHeight,
    }));

    expect(scrolling.overflowY).toBe("auto");
    expect(scrolling.scrollable).toBe(true);

    const bodyOverflow = await page.evaluate(
      () => document.body.scrollWidth - window.innerWidth,
    );
    expect(bodyOverflow).toBeLessThanOrEqual(2);
  }
});

test("Package 03 no document overflow at 200 percent zoom with markers", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginAndGoToDiagram(page);

  await expect(page.locator("#journal-markers-svg")).toBeAttached();

  await page.evaluate(() => {
    document.body.style.zoom = "2";
  });

  const overflow = await page.evaluate(() => ({
    body: document.body.scrollWidth,
    viewport: window.innerWidth,
  }));

  expect(overflow.body).toBeLessThanOrEqual(overflow.viewport + 2);
});

test("Package 03 crowded stop marker stays attached at 200 percent zoom", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await loginAndGoToDiagram(page);

  const markers = page.locator("#journal-markers-svg [data-journal-marker]");
  await expect(markers.first()).toBeVisible();

  await page.evaluate(() => {
    document.body.style.zoom = "2";
  });

  const geometries = await markers.evaluateAll((els) =>
    els.map((el) => {
      const rect = el.getBoundingClientRect();
      return {
        id: el.id,
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
        hasNaN: [rect.x, rect.y, rect.width, rect.height].some(Number.isNaN),
      };
    }),
  );

  for (const geo of geometries) {
    expect(geo.hasNaN, `${geo.id} has NaN geometry`).toBe(false);
    expect(geo.width, `${geo.id} width`).toBeGreaterThan(0);
    expect(geo.height, `${geo.id} height`).toBeGreaterThan(0);
  }
});

test("Package 03 captures stable reference-governed screenshots", async ({ page }) => {
  await mkdir(pkg3ArtifactRoot, { recursive: true });
  await page.emulateMedia({ reducedMotion: "reduce" });
  await loginAndGoToDiagram(page);

  await expect(page.locator("#journal-markers-svg")).toBeAttached();
  await page.evaluate(() => document.fonts.ready);

  await page.screenshot({
    path: resolve(pkg3ArtifactRoot, "production-markers-view-mode.png"),
    animations: "disabled",
  });

  const trigger = page.locator("#journal-trigger");
  await trigger.click();
  const panel = page.locator("#station-journal-panel");
  await expect(panel).toBeVisible();
  await expect(panel.locator("#journal-entry-list")).toBeVisible();

  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({
    path: resolve(pkg3ArtifactRoot, "production-markers-journal-open.png"),
    animations: "disabled",
  });

  const nodeMarker = page.locator('#journal-markers-svg [data-journal-kind="node"]').first();
  await nodeMarker.click();
  await expect(panel.locator("#journal-target-scope")).toBeVisible();

  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({
    path: resolve(pkg3ArtifactRoot, "production-markers-entity-scope.png"),
    animations: "disabled",
  });
});

test("Package 04 component baseline — executable reference and production tab strip", async ({ page }) => {
  await mkdir(pkg4ArtifactRoot, { recursive: true });

  // Capture the executable reference drawer
  await page.goto(
    pathToFileURL(resolve(pkg4ReferenceRoot, "mock-06-entity-drawer-journal.html")).href,
    { waitUntil: "networkidle" },
  );
  await page.evaluate(() => document.fonts.ready);

  const referenceHeading = page.getByText("Mock 06 · Journal inside an entity edit drawer", {
    exact: false,
  });
  await expect(referenceHeading).toBeVisible();

  await page.screenshot({
    path: resolve(pkg4ArtifactRoot, "reference-entity-drawer-journal.png"),
  });

  // Capture the current production stop/pathway tab strip baseline
  await loginAndGoToDiagram(page);

  const diagramPage = page.locator("#diagram-page");
  await expect(diagramPage).toBeVisible();

  // Open a child stop drawer to capture its current two-tab strip
  const nodeMarker = page.locator('#journal-markers-svg [data-journal-kind="node"]').first();
  await expect(nodeMarker).toBeVisible();
  await nodeMarker.click();

  // Open the edit drawer from a scoped journal entry
  const panel = page.locator("#station-journal-panel");
  await expect(panel).toBeVisible();

  const editBtn = panel.locator('button[id^="journal-edit-target-"]').first();
  await expect(editBtn).toBeVisible();
  await editBtn.click();

  // The child stop drawer with its tab strip should be open
  const drawer = page.locator('[aria-label="Edit node details"]');
  await expect(drawer).toBeVisible();

  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({
    path: resolve(pkg4ArtifactRoot, "production-tab-baseline.png"),
    animations: "disabled",
  });
});
