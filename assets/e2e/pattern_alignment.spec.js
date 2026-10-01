import { test, expect } from "@playwright/test";
import { bodyFitsViewport, readZipTextMember } from "./browser_helpers";
import { mkdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Alignment task shell (spec 12, step 20 and later visual steps).
 *
 * Step 20 owns the `test.describe("alignment shell")` block: it opens
 * BROWSER-ALIGN-A's Alignment task and captures it at 1440×1000 and 320×900
 * against the Missing-section reference. Later visual steps add their own
 * describe blocks; step 30 adds the end-to-end journeys. Every mutating
 * journey uses its own `-B` pattern copy so viewports never share modified
 * records.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const ALIGN_ROUTE = "BROWSER_ALIGN";
const ALIGN_PATTERN = "BROWSER-ALIGN-A";
// Step 26 draws a five-point saved section here so the Simplify action
// renders from saved geometry (the server cannot see hook drafts, CR-5).
const ALIGN_ACTIONS_PATTERN = "BROWSER-ALIGN-ACTIONS";

const CAPTURE_DIR = process.env.PATTERN_ALIGNMENT_CAPTURE_DIR;

// A verified-transparent 1×1 PNG served for every tile request, so captures
// never depend on the network or on Geoapify credits. (An earlier literal
// for this stub decoded to a half-green pixel and tinted the whole map.)
const BLANK_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=",
  "base64",
);

async function captureViewport(page, name) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`) });
}

async function captureFullPage(page, name) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(CAPTURE_DIR, `${name}.png`),
    fullPage: true,
    animations: "disabled",
  });
}

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

function collectPageErrors(page) {
  const problems = [];
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  return problems;
}

// Waits for the LiveView root to report itself connected, so an interaction is
// never clicked into a server-rendered page that has not been hydrated yet.
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

async function stubTiles(page) {
  await page.route("**/map/tiles/**", async (route) => {
    await route.fulfill({ contentType: "image/png", body: BLANK_PNG });
  });
}

test.describe("alignment shell", () => {
  test("renders the Alignment task at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(page.locator("#alignment-title")).toHaveText(
      "Path between stops",
    );
    await expect(page.locator("#alignment-status")).toContainText("1 missing");
    await expect(page.locator("#alignment-section-2")).toBeVisible();
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "shell-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    await page.setViewportSize({ width: 320, height: 900 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(page.locator("#alignment-title")).toHaveText(
      "Path between stops",
    );
    await expect(page.locator("#alignment-section-2")).toBeVisible();
    await captureFullPage(page, "shell-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

test.describe("point editing", () => {
  test("edits points with handles and box selection at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    await expect(
      page.locator("#alignment-map-root .pa-stop-pin").first(),
    ).toBeVisible({ timeout: 15000 });

    // Section 1 is selected by default and saved: enter Edit points.
    const edit = page.locator("#alignment-map-root [data-pa-edit]");
    await expect(edit).toBeEnabled({ timeout: 15000 });
    await edit.click();
    await expect(
      page.locator("#alignment-map-root .alignment-handle"),
    ).toHaveCount(1);
    await expect(
      page.locator(
        '#alignment-map-root [data-pa-edit][aria-pressed="true"]',
      ),
    ).toHaveCount(1);
    await expect(page.locator("#alignment-map-root")).toContainText(
      "Click the line to add a point",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "editing-1440");

    // Insert a second point by clicking the drawn edge between stop 1
    // and the handle. The fitted zoom varies with layout timing (the
    // whole pattern shares a few hundred pixels), so steer the section
    // into view with real drags, spread it with trusted double-click
    // zooms on the handle, and only click once the edge midpoint reads
    // as bare stage. Coordinates are re-read after every gesture.
    async function editGeometry() {
      return page.evaluate(() => {
        const icons = [
          ...document.querySelectorAll("#alignment-map-root .pa-div-icon"),
        ];
        const icon = icons.find(
          (el) =>
            el.querySelector(".pa-stop-pin")?.textContent.trim() === "1",
        );
        const handle = document.querySelector(
          "#alignment-map-root .alignment-handle",
        );
        const stage = document.querySelector(
          "#alignment-map-root [data-pa-stage]",
        );
        const center = (rect) => ({
          x: (rect.left + rect.right) / 2,
          y: (rect.top + rect.bottom) / 2,
        });
        // The divIcon root is fixed 30x30 centered on the stop anchor,
        // so its center is the exact anchor screen position.
        const anchor = center(icon.getBoundingClientRect());
        const handleAt = center(handle.getBoundingClientRect());
        const stageRect = stage.getBoundingClientRect();
        const stageAt = center(stageRect);
        const mid = {
          x: (anchor.x + handleAt.x) / 2,
          y: (anchor.y + handleAt.y) / 2,
        };
        const under = document.elementFromPoint(mid.x, mid.y);
        return {
          anchor,
          handle: handleAt,
          stage: stageAt,
          mid,
          gap: Math.hypot(anchor.x - handleAt.x, anchor.y - handleAt.y),
          handleVisible:
            handleAt.x > stageRect.left + 60 &&
            handleAt.x < stageRect.right - 60 &&
            handleAt.y > stageRect.top + 60 &&
            handleAt.y < stageRect.bottom - 60,
          midInStage: Boolean(
            under?.closest?.("[data-pa-stage]") &&
              !under?.closest?.(".alignment-handle") &&
              !under?.closest?.(".pa-div-icon"),
          ),
        };
      });
    }

    // Drag content toward the stage center: press the stage center (always
    // a valid on-screen map point) and release toward the mirrored
    // offset of whatever must come into view.
    async function steerToward(point) {
      const g = await editGeometry();
      const dx = Math.max(-300, Math.min(300, g.stage.x - point.x));
      const dy = Math.max(-300, Math.min(300, g.stage.y - point.y));
      await page.mouse.move(g.stage.x, g.stage.y);
      await page.mouse.down();
      await page.mouse.move(g.stage.x + dx, g.stage.y + dy, { steps: 10 });
      await page.mouse.up();
      await page.waitForTimeout(500);
    }

    for (let i = 0; i < 6; i++) {
      const g = await editGeometry();
      if (g.handleVisible) break;
      await steerToward(g.handle);
    }

    let g = await editGeometry();
    expect(g.handleVisible).toBe(true);

    // Zoom a level centered on the handle per double-click until the edge
    // clears both icons. The click pair toggles selection twice (net
    // unchanged) and the icon keeps its DOM across repaints.
    for (let i = 0; i < 4 && g.gap < 140; i++) {
      await page
        .locator("#alignment-map-root .alignment-handle")
        .first()
        .dblclick();
      await page.waitForTimeout(600);
      g = await editGeometry();
    }

    for (let i = 0; i < 6 && !g.midInStage; i++) {
      await steerToward(g.mid);
      g = await editGeometry();
    }

    expect(g.gap).toBeGreaterThan(100);
    expect(g.midInStage).toBe(true);
    await page.mouse.click(g.mid.x, g.mid.y);
    await expect(
      page.locator("#alignment-map-root .alignment-handle"),
    ).toHaveCount(2);

    // Shift-drag a box across both handles. The insert lands beside the
    // click point, so both handles sit near the stage center already;
    // steer once more if either drifted out of view.
    for (let i = 0; i < 3; i++) {
      const rects = await page
        .locator("#alignment-map-root .alignment-handle")
        .evaluateAll((els) =>
          els.map((el) => {
            const r = el.getBoundingClientRect();
            return {
              x: (r.left + r.right) / 2,
              y: (r.top + r.bottom) / 2,
            };
          }),
        );
      const inView = rects.every(
        (p) => p.x > 0 && p.x < 1440 && p.y > 0 && p.y < 1000,
      );
      if (inView) break;
      const g2 = await editGeometry();
      await steerToward(g2.handle);
    }
    const box = await page
      .locator("#alignment-map-root .alignment-handle")
      .evaluateAll((els) => {
        const rects = els.map((el) => el.getBoundingClientRect());
        const xs = rects.flatMap((r) => [r.left, r.right]);
        const ys = rects.flatMap((r) => [r.top, r.bottom]);
        return {
          x1: Math.min(...xs) - 10,
          y1: Math.min(...ys) - 10,
          x2: Math.max(...xs) + 10,
          y2: Math.max(...ys) + 10,
        };
      });
    await page.keyboard.down("Shift");
    await page.mouse.move(box.x1, box.y1);
    await page.mouse.down();
    await page.mouse.move(box.x2, box.y2, { steps: 5 });
    await page.mouse.up();
    await page.keyboard.up("Shift");
    await expect(
      page.locator("#alignment-map-root .alignment-handle-dot.is-selected"),
    ).toHaveCount(2);
    await captureViewport(page, "multiselect-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    await page.setViewportSize({ width: 320, height: 900 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    const editNarrow = page.locator("#alignment-map-root [data-pa-edit]");
    await expect(editNarrow).toBeEnabled({ timeout: 15000 });
    await editNarrow.click();
    await expect(
      page.locator("#alignment-map-root .alignment-handle"),
    ).toHaveCount(1);
    await captureFullPage(page, "editing-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

test.describe("point list", () => {
  test("opens the keyboard point list and moves a located point at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    await expect(
      page.locator("#alignment-map-root .pa-stop-pin").first(),
    ).toBeVisible({ timeout: 15000 });

    // Section 1 is selected by default and saved: enter Edit points, then
    // open the keyboard list from the section detail.
    const edit = page.locator("#alignment-map-root [data-pa-edit]");
    await expect(edit).toBeEnabled({ timeout: 15000 });
    await edit.click();
    await expect(
      page.locator("#alignment-map-root .alignment-handle"),
    ).toHaveCount(1);

    const toggle = page.locator("#alignment-point-list-toggle");
    await expect(toggle).toBeVisible({ timeout: 15000 });
    await toggle.click();
    const rows = page.locator("#alignment-point-list .pa-point-row");
    await expect(rows).toHaveCount(1);
    await expect(page.locator("#alignment-point-list")).toContainText(
      "Arrow keys move a focused map point",
    );
    await expect(toggle).toHaveAttribute("aria-expanded", "true");

    // Checking the row selects the map handle; Locate focuses it.
    await page.locator('#alignment-point-list [data-point-check="0"]').check();
    await expect(
      page.locator("#alignment-map-root .alignment-handle-dot.is-selected"),
    ).toHaveCount(1);
    await expect(page.locator("#alignment-point-list")).toContainText(
      "Delete points (1)",
    );
    await page.locator('#alignment-point-list [data-focus-point="0"]').click();
    await expect(
      page.locator("#alignment-map-root .alignment-handle:focus"),
    ).toHaveCount(1);

    // ArrowRight on the focused handle commits a draft move: Undo enables.
    await page
      .locator("#alignment-map-root .alignment-handle")
      .first()
      .press("ArrowRight");
    await expect(page.locator("#alignment-map-root [data-pa-undo]")).toBeEnabled();
    await expect(
      page.locator("#alignment-map-root .alignment-handle:focus"),
    ).toHaveCount(1);
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "point-list-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    await page.setViewportSize({ width: 320, height: 900 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    const editNarrow = page.locator("#alignment-map-root [data-pa-edit]");
    await expect(editNarrow).toBeEnabled({ timeout: 15000 });
    await editNarrow.click();
    await page.locator("#alignment-point-list-toggle").click();
    await expect(
      page.locator("#alignment-point-list .pa-point-row"),
    ).toHaveCount(1);
    await page.locator('#alignment-point-list [data-focus-point="0"]').click();
    await expect(
      page.locator("#alignment-map-root .alignment-handle:focus"),
    ).toHaveCount(1);
    await captureFullPage(page, "point-list-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

test.describe("section actions", () => {
  test("shows More section actions, Draw manually and the Simplify dialog at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_ACTIONS_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    await expect(
      page.locator("#alignment-map-root .pa-stop-pin").first(),
    ).toBeVisible({ timeout: 15000 });

    // Section 1 is selected by default with three saved interior points:
    // open More section actions and read the saved-section buttons.
    await page.locator("#alignment-detail summary").click();
    await expect(page.locator("#alignment-clear")).toBeVisible();
    await expect(page.locator("#alignment-delete-open")).toBeVisible();
    await expect(page.locator("#alignment-simplify-open")).toBeVisible();
    await expect(page.locator("#alignment-detail")).toContainText(
      "More section actions",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "actions-1440");

    // The Simplify dialog opens with the 10 m balanced default selected.
    await page.locator("#alignment-simplify-open").click();
    await expect(
      page.locator("#alignment-simplify-dialog"),
    ).toBeVisible({ timeout: 15000 });
    await expect(page.locator("#alignment-simplify-dialog")).toContainText(
      "Simplify this section",
    );
    await expect(page.locator("#alignment-simplify-dialog")).toContainText(
      "Maximum path deviation",
    );
    await expect(
      page.locator("#alignment-simplify-tolerance"),
    ).toHaveValue("10");
    // The confirm panel plays a 150 ms entry fade; capture only once it
    // settles at full opacity, never mid-animation.
    await page.waitForFunction(
      () => {
        const panel = document.querySelector(
          "#alignment-simplify-dialog > div > div",
        );
        return panel && getComputedStyle(panel).opacity === "1";
      },
      { timeout: 5000 },
    );
    await captureViewport(page, "simplify-dialog-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    // A missing section offers Draw manually instead of More actions.
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await page.locator("#alignment-section-3").click();
    await expect(page.locator("#alignment-draw")).toBeVisible({
      timeout: 15000,
    });
    await expect(page.locator("#alignment-draw")).toContainText(
      "Draw manually",
    );

    await page.setViewportSize({ width: 320, height: 900 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_ACTIONS_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    await page.locator("#alignment-detail summary").click();
    await expect(page.locator("#alignment-clear")).toBeVisible({
      timeout: 15000,
    });
    await captureFullPage(page, "actions-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

test.describe("draft guards", () => {
  test("shows Unsaved badges, the discard dialog and the task-switch guard at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_ACTIONS_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    await expect(
      page.locator("#alignment-map-root .pa-stop-pin").first(),
    ).toBeVisible({ timeout: 15000 });

    // Section 1 is selected by default with saved geometry: clearing its
    // interior points through the real section action creates a hook
    // draft, which the server mirrors as Unsaved badges and a dirty
    // guard (no map pixel math needed for the badge states).
    await page.locator("#alignment-detail summary").click();
    await expect(page.locator("#alignment-clear")).toBeVisible();
    await page.locator("#alignment-clear").click();
    await expect(page.locator("#alignment-status")).toContainText(
      "Unsaved changes",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-section-status-1")).toContainText(
      "Unsaved",
    );
    await expect(page.locator("#alignment-discard")).toBeVisible();
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "unsaved-1440");

    // The in-place discard dialog carries the prototype copy; keeping
    // editing preserves the dirty badges.
    await page.locator("#alignment-discard").click();
    await expect(page.locator("#alignment-discard-dialog")).toContainText(
      "Discard unsaved changes?",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-discard-dialog")).toContainText(
      "Your saved path will stay unchanged.",
    );
    // The confirm panel plays a 150 ms entry fade; capture only once it
    // settles at full opacity, never mid-animation.
    await page.waitForFunction(
      () => {
        const panel = document.querySelector(
          "#alignment-discard-dialog > div > div",
        );
        return panel && getComputedStyle(panel).opacity === "1";
      },
      { timeout: 5000 },
    );
    await captureViewport(page, "discard-dialog-1440");
    await page.locator("#alignment-discard-dialog-cancel").click();
    await expect(page.locator("#alignment-status")).toContainText(
      "Unsaved changes",
    );

    // A dirty task switch reuses the existing navigation discard
    // dialog instead of patching away the draft.
    await page.locator("#pattern-task-stops").click();
    await expect(page.locator("#discard-changes-dialog")).toContainText(
      "Discard unsaved changes?",
      { timeout: 15000 },
    );
    await page.locator("#discard-changes-dialog-cancel").click();
    await expect(page.locator("#alignment-task")).toBeVisible();
    await expect(page.locator("#alignment-status")).toContainText(
      "Unsaved changes",
    );
    expect(await bodyFitsViewport(page)).toBe(true);

    // A fresh load starts clean; clearing again proves the phone stack
    // keeps the badges without overflow.
    await page.setViewportSize({ width: 320, height: 900 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_ACTIONS_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await page.locator("#alignment-detail summary").click();
    await expect(page.locator("#alignment-clear")).toBeVisible({
      timeout: 15000,
    });
    await page.locator("#alignment-clear").click();
    await expect(page.locator("#alignment-status")).toContainText(
      "Unsaved changes",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-section-status-1")).toContainText(
      "Unsaved",
    );
    await captureFullPage(page, "unsaved-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

test.describe("alignment map", () => {
  test("shows section lines on the Leaflet map at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    // Two saved sections plus the missing dashed connector, and one pin
    // per stop visit run.
    await expect(
      page.locator("#alignment-map-root .pa-stop-pin").first(),
    ).toBeVisible({ timeout: 15000 });
    await expect(page.locator("#alignment-map-root")).toContainText(
      "Hide stop labels",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "map-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    await page.setViewportSize({ width: 320, height: 900 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    await captureFullPage(page, "map-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });

  test("shows the tile-failure notice when tiles return 500", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await page.route("**/map/tiles/**", async (route) => {
      await route.fulfill({ status: 500, body: "tile boom" });
    });
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(page.locator("#alignment-notice")).toContainText(
      "The background map couldn't load",
      { timeout: 20000 },
    );
    await expect(page.locator("#alignment-notice")).toContainText(
      "Your map line and stop list are still available.",
    );
    // The sections stay usable behind the notice.
    await expect(page.locator("#alignment-section-2")).toBeVisible();
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "map-error-1440");

    // The refused tiles surface exactly one console resource error; nothing
    // else may fail.
    expect(problems.some((p) => p.includes("500"))).toBe(true);
    expect(problems.filter((p) => !p.includes("500"))).toEqual([]);
  });
});

test.describe("save dialogs", () => {
  test("shows the scope dialog and the conflict dialog at desktop and phone widths", async ({
    page,
    context,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    // Section 1 of BROWSER-ALIGN-A is shared with BROWSER-ALIGN-B (and the
    // loop copy), so clearing its interior points and saving opens the
    // scope dialog with "Only this pattern" checked by default.
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${ALIGN_PATTERN}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });

    await page.locator("#alignment-section-1").click();
    await page.locator("#alignment-detail summary").click();
    await expect(page.locator("#alignment-clear")).toBeVisible();
    await page.locator("#alignment-clear").click();
    await expect(page.locator("#alignment-status")).toContainText(
      "Unsaved changes",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-save")).toBeEnabled();
    await page.locator("#alignment-save").click();
    // The dialog chrome (title, footer buttons) always renders; pin the
    // open state and the review body so the assertion cannot pass on a
    // closed dialog.
    await expect(page.locator("#alignment-save-dialog")).toHaveAttribute(
      "data-open",
      "true",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-save-dialog")).toContainText(
      "Who should use this path?",
    );
    await expect(
      page.locator("#alignment-save-scope-1-local"),
    ).toBeChecked();
    await expect(page.locator("#alignment-save-dialog")).toContainText(
      "BROWSER-ALIGN-B",
    );
    // The confirm panel plays a 150 ms entry fade; capture only once it
    // settles at full opacity, never mid-animation.
    await page.waitForFunction(
      () => {
        const panel = document.querySelector(
          "#alignment-save-dialog > div > div",
        );
        return panel && getComputedStyle(panel).opacity === "1";
      },
      { timeout: 5000 },
    );
    await captureViewport(page, "scope-dialog-1440");

    await page.setViewportSize({ width: 320, height: 900 });
    await captureFullPage(page, "scope-dialog-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    // Keep the draft but close the dialog: a second editor saves the same
    // shared section first, so this tab's next save conflicts.
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator("#alignment-save-dialog-cancel").click();
    await expect(page.locator("#alignment-status")).toContainText(
      "Unsaved changes",
    );

    const second = await context.newPage();
    second.on("pageerror", (error) =>
      problems.push(`second pageerror: ${error.message}`),
    );
    second.on("console", (message) => {
      if (message.type() === "error")
        problems.push(`second console: ${message.text()}`);
    });
    await stubTiles(second);
    await logIn(second);
    await second.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/BROWSER-ALIGN-B?task=alignment`,
    );
    await second.waitForSelector("#alignment-task", { timeout: 15000 });
    await second.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(second);
    await second.locator("#alignment-section-1").click();
    await second.locator("#alignment-detail summary").click();
    await expect(second.locator("#alignment-clear")).toBeVisible();
    await second.locator("#alignment-clear").click();
    await expect(second.locator("#alignment-status")).toContainText(
      "Unsaved changes",
      { timeout: 15000 },
    );
    await second.locator("#alignment-save").click();
    await expect(second.locator("#alignment-save-dialog")).toHaveAttribute(
      "data-open",
      "true",
      { timeout: 15000 },
    );
    await expect(second.locator("#alignment-save-dialog")).toContainText(
      "Who should use this path?",
    );
    await second.locator("#alignment-save-scope-1-shared").check();
    await second.locator("#alignment-save-dialog-confirm").click();
    await expect(second.locator("#status")).toContainText(
      "Map line saved.",
      { timeout: 15000 },
    );
    await second.close();

    await page.locator("#alignment-save").click();
    await expect(page.locator("#alignment-conflict-dialog")).toHaveAttribute(
      "data-open",
      "true",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-conflict-dialog")).toContainText(
      "Review the newer shared path",
    );
    await expect(page.locator("#alignment-conflict-dialog")).toContainText(
      "A newer shared path was saved",
    );
    await expect(page.locator("#alignment-conflict-dialog")).toContainText(
      "Keep as local draft",
    );
    await page.waitForFunction(
      () => {
        const panel = document.querySelector(
          "#alignment-conflict-dialog > div > div",
        );
        return panel && getComputedStyle(panel).opacity === "1";
      },
      { timeout: 5000 },
    );
    await captureViewport(page, "conflict-dialog-1440");

    await page.setViewportSize({ width: 320, height: 900 });
    await captureFullPage(page, "conflict-dialog-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

test.describe("imported shapes", () => {
  test("reviews imported shapes and converts them into drafts", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    // The divergent pattern keeps two imported shapes (one trip on the
    // second): the notice names both and the dialog lists each with its
    // trip count and length.
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/BROWSER-ALIGN-IMPORTED?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });

    await expect(page.locator("#alignment-notice")).toContainText(
      "This pattern uses 2 imported shapes",
    );
    await expect(page.locator("#alignment-review-import")).toContainText(
      "Compare shapes",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "imported-1440");

    await page.locator("#alignment-review-import").click();
    await expect(page.locator("#alignment-import-dialog")).toHaveAttribute(
      "data-open",
      "true",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-import-dialog")).toContainText(
      "Choose an imported path",
    );
    await expect(page.locator("#alignment-import-dialog")).toContainText(
      "IMP-ALIGN-1",
    );
    await expect(page.locator("#alignment-import-dialog")).toContainText(
      "IMP-ALIGN-2",
    );
    await expect(page.locator("#alignment-import-dialog")).toContainText(
      "Saving the replacement would affect all 2 trips.",
    );
    await page.locator("#alignment-import-shape-IMP-ALIGN-2").check();
    await expect(
      page.locator("#alignment-import-shape-IMP-ALIGN-2"),
    ).toBeChecked();
    await page.waitForFunction(
      () => {
        const panel = document.querySelector(
          "#alignment-import-dialog > div > div",
        );
        return panel && getComputedStyle(panel).opacity === "1";
      },
      { timeout: 5000 },
    );
    await captureViewport(page, "import-dialog-1440");
    await page.locator("#alignment-import-dialog-cancel").click();
    await expect(page.locator("#alignment-import-dialog")).toHaveAttribute(
      "data-open",
      "false",
      { timeout: 15000 },
    );

    // The single-shape pattern converts its far shape into a flagged
    // draft: the section stays a straight amber line with an unsaved
    // badge until it is reviewed and saved.
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/BROWSER-ALIGN-IMPORTED-SINGLE?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });

    await expect(page.locator("#alignment-notice")).toContainText(
      "Imported path · original shape retained",
    );
    await page.locator("#alignment-review-import").click();
    await expect(page.locator("#alignment-import-dialog")).toHaveAttribute(
      "data-open",
      "true",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-import-dialog")).toContainText(
      "Review imported path",
    );
    await expect(page.locator("#alignment-import-dialog")).toContainText(
      "IMP-ALIGN-3",
    );
    await expect(page.locator("#alignment-import-dialog")).toContainText(
      "3 imported points",
    );
    await page.locator("#alignment-import-dialog-confirm").click();
    await expect(page.locator("#alignment-status")).toContainText(
      "Unsaved changes",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-section-status-1")).toContainText(
      "Unsaved",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-save")).toBeEnabled();
    await page.locator("#alignment-map-root").scrollIntoViewIfNeeded();
    await captureViewport(page, "import-draft-1440");

    await page.setViewportSize({ width: 320, height: 900 });
    await captureFullPage(page, "imported-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

/**
 * Manual editing journeys (spec 12, step 30, EV-29).
 *
 * One Playwright journey through the REAL production composition
 * (Playwright → local Phoenix server on 4002 with BROWSER_E2E=true →
 * RoutePatternLive → PatternAlignment hook → review/apply → exporter
 * download): draw the missing section, edit points, use the keyboard list,
 * take section actions, save through the scope dialog, and prove the drawn
 * midpoint lands axis-ordered in the exported shapes.txt. Tiles are stubbed
 * at the browser boundary; the midpoint and scope assertions run against
 * the real server and database.
 *
 * The 1440 px journey mutates BROWSER-ALIGN-A (sections 1–3); the 320 px
 * journey uses the BROWSER-ALIGN-A-B copy so viewports never share modified
 * records. Read-only states reuse BROWSER-ALIGN-IMPORTED, BROWSER-ALIGN-LOOP
 * and BROWSER-ALIGN-LONG. Tests run in file order (workers: 1) and build on
 * each other's saved state; do not reorder them.
 */
test.describe("manual editing journeys", () => {
  // Seed stops (test/support/browser_seed.exs): AL_S3 is
  // (40.714800, -74.004000), AL_S4 is (40.715800, -74.003000). Add midpoint
  // averages the anchors, the materializer rounds to 6 decimals, and the
  // exporter writes the Decimals verbatim — so the drawn point lands in
  // shapes.txt as lat 40.715300 / lon -74.003500 when axis order holds.
  const MID_LAT = "40.715300";
  const MID_LON = "-74.003500";

  const JOURNEY_PATTERN = "BROWSER-ALIGN-A";
  const JOURNEY_SIBLING = "BROWSER-ALIGN-B";
  // The -B copy of A for the 320 px run: same visits, but its first two
  // sections resolve through the shared paths, so only its third section
  // is missing for the phone draw-and-save journey.
  const JOURNEY_NARROW = "BROWSER-ALIGN-A-B";

  // Full-version export download, copied from route_patterns.spec.js. The
  // export link changes only once the rebuilt archive is ready, so the
  // poll doubles as build completion.
  async function downloadExport(page) {
    await page.goto("/gtfs/" + (await getVersionId(page)) + "/export");
    await page.waitForSelector("#start-export", { timeout: 15000 });
    await waitForLiveView(page);

    const previousHref = await page
      .locator("#export-download-link")
      .getAttribute("href");

    await page.locator("#start-export").click();
    await expect
      .poll(() => page.locator("#export-download-link").getAttribute("href"), {
        timeout: 120000,
      })
      .not.toBe(previousHref);

    const downloadPromise = page.waitForEvent("download");
    await page.locator("#export-download-link").click();
    const download = await downloadPromise;
    return readFileSync(await download.path());
  }

  function findShapeRow(shapesText, lat, lon) {
    const lines = shapesText.trim().split("\n");
    const header = lines[0].split(",");
    const latIdx = header.indexOf("shape_pt_lat");
    const lonIdx = header.indexOf("shape_pt_lon");
    if (latIdx === -1 || lonIdx === -1) {
      throw new Error("shapes.txt is missing its axis columns");
    }
    return lines
      .slice(1)
      .map((line) => line.split(","))
      .find((cols) => cols[latIdx] === lat && cols[lonIdx] === lon);
  }

  // The confirm panel plays a 150 ms entry fade; capture only once it
  // settles at full opacity, never mid-animation.
  async function settleDialog(page, dialogId) {
    await page.waitForFunction(
      (id) => {
        const panel = document.querySelector(`#${id} > div > div`);
        return panel && getComputedStyle(panel).opacity === "1";
      },
      dialogId,
      { timeout: 5000 },
    );
  }

  async function openAlignment(page, patternId) {
    const versionId = await getVersionId(page);
    await page.goto(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${patternId}?task=alignment`,
    );
    await page.waitForSelector("#alignment-task", { timeout: 15000 });
    await page.waitForSelector("#alignment-sections", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#alignment-map-root .leaflet-container"),
    ).toBeVisible({ timeout: 15000 });
    // Stop pins render only once the hook has drawn its model, so this is
    // the readiness signal for hook-dispatched actions (Draw, Clear):
    // without it a fast click can land before the model arrives and
    // silently no-op.
    await expect(
      page.locator("#alignment-map-root .pa-stop-pin").first(),
    ).toBeVisible({ timeout: 15000 });
  }

  // Clicks Save and confirms through the scope dialog when the review
  // needs one (a pair used by several patterns does). The dialog keeps
  // "Only this pattern" checked by default; the caller asserts that
  // default before confirming when the journey owns it.
  async function saveThroughScope(page, position) {
    await page.locator("#alignment-save").click();
    await expect(page.locator("#alignment-save-dialog")).toHaveAttribute(
      "data-open",
      "true",
      { timeout: 15000 },
    );
    await expect(
      page.locator(`#alignment-save-scope-${position}-local`),
    ).toBeChecked();
    await page.locator("#alignment-save-dialog-confirm").click();
    await expect(page.locator("#status")).toContainText(
      "Map line saved.",
      { timeout: 15000 },
    );
  }

  test("draws the missing section, adds its midpoint and saves it", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);

    // Section 3 (Align Market → Align Harbor) is the pattern's only
    // missing section: the detail offers Draw manually as its primary
    // action and no Generate control renders (CR-10).
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openAlignment(page, JOURNEY_PATTERN);
    await page.locator("#alignment-section-3").click();
    await expect(page.locator("#alignment-draw")).toBeVisible({
      timeout: 15000,
    });
    await expect(page.locator("#alignment-draw")).toContainText(
      "Draw manually",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "journey-partial-1440");

    // Draw manually drops a straight set draft and enters Edit points;
    // the keyboard list (now rendered for editable missing sections too)
    // offers Add midpoint as the first interior point.
    await page.locator("#alignment-draw").click();
    await expect(page.locator("#alignment-map-root")).toContainText(
      "Click the line to add a point",
    );
    await expect(page.locator("#alignment-point-list-toggle")).toBeVisible({
      timeout: 15000,
    });
    await page.locator("#alignment-point-list-toggle").click();
    await expect(page.locator("#alignment-point-list")).toContainText(
      "No interior points yet",
    );
    await page.locator("#alignment-point-list [data-add-midpoint]").click();
    await expect(
      page.locator("#alignment-point-list .pa-point-row"),
    ).toHaveCount(1);
    await expect(page.locator("#alignment-status")).toContainText(
      "Unsaved changes",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-section-status-3")).toContainText(
      "Unsaved",
    );
    await expect(page.locator("#alignment-save")).toBeEnabled();
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "journey-editing-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    // The S3 → S4 pair is also used by the -B copy, GEN-2 and the long
    // pattern, so the review asks for scope with "Only this pattern"
    // checked; the dialog names a sibling user of the shared pair.
    await page.locator("#alignment-save").click();
    await expect(page.locator("#alignment-save-dialog")).toHaveAttribute(
      "data-open",
      "true",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-save-dialog")).toContainText(
      "Who should use this path?",
    );
    await expect(
      page.locator("#alignment-save-scope-3-local"),
    ).toBeChecked();
    await expect(page.locator("#alignment-save-dialog")).toContainText(
      "BROWSER-ALIGN-A-B",
    );
    await settleDialog(page, "alignment-save-dialog");
    await captureViewport(page, "journey-scope-dialog-1440");
    await page.locator("#alignment-save-dialog-confirm").click();
    await expect(page.locator("#status")).toContainText(
      "Map line saved.",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-section-status-3")).toContainText(
      "✓ Saved",
    );

    expect(problems).toEqual([]);
  });

  test("exports the drawn midpoint with axis-ordered coordinates", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    await page.setViewportSize({ width: 1440, height: 1000 });

    // The full-version export carries the drawn shape: one shapes.txt row
    // holds the midpoint with the latitude in the latitude column (INV-1).
    const zip = await downloadExport(page);
    const shapes = readZipTextMember(zip, "shapes.txt");
    const header = shapes.trim().split("\n")[0].split(",");
    expect(header).toContain("shape_pt_lat");
    expect(header).toContain("shape_pt_lon");
    expect(findShapeRow(shapes, MID_LAT, MID_LON)).toBeTruthy();

    expect(problems).toEqual([]);
  });

  test("inserts a point by clicking the line and restores it with Undo", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);

    // Section 1's saved interior differs between a fresh seed (one point)
    // and a full-file run (the save-dialogs journey leaves it straight),
    // so straighten it through the real section action only when handles
    // exist: the insert must start from zero either way.
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openAlignment(page, JOURNEY_PATTERN);
    await page.locator("#alignment-section-1").click();
    const edit = page.locator("#alignment-map-root [data-pa-edit]");
    await expect(edit).toBeEnabled({ timeout: 15000 });
    await edit.click();
    const handles = page.locator("#alignment-map-root .alignment-handle");
    if ((await handles.count()) > 0) {
      await page.locator("#alignment-detail summary").click();
      await expect(page.locator("#alignment-clear")).toBeVisible({
        timeout: 15000,
      });
      await page.locator("#alignment-clear").click();
      await expect(page.locator("#alignment-section-status-1")).toContainText(
        "Unsaved",
        { timeout: 15000 },
      );
    }
    await expect(handles).toHaveCount(0);

    // The map renders vectors on canvas (`preferCanvas`), so the click
    // target is the stop-1 → stop-2 pin midpoint. Click only when two
    // consecutive reads agree: right after a fit or zoom the pins and the
    // canvas line disagree for a frame while the animation settles, and a
    // click in that window can land on the neighbouring section's
    // sweeping line (selecting it instead of inserting). Both pins must
    // also be on screen, or the midpoint slides off the section's edge.
    async function pinEdge() {
      return page.evaluate(() => {
        const root = document.querySelector("#alignment-map-root");
        const icons = [...root.querySelectorAll(".pa-div-icon")];
        const center = (rect) => ({
          x: (rect.left + rect.right) / 2,
          y: (rect.top + rect.bottom) / 2,
        });
        const at = (text) => {
          const el = icons.find(
            (node) =>
              node.querySelector(".pa-stop-pin")?.textContent.trim() === text,
          );
          return el ? center(el.getBoundingClientRect()) : null;
        };
        const a = at("1");
        const b = at("2");
        if (!a || !b) return null;
        const stage = root.querySelector("[data-pa-stage]");
        const stageRect = stage.getBoundingClientRect();
        const stageAt = center(stageRect);
        const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
        const under = document.elementFromPoint(mid.x, mid.y);
        const onScreen = (p) =>
          p.x > stageRect.left &&
          p.x < stageRect.right &&
          p.y > stageRect.top &&
          p.y < stageRect.bottom;
        return {
          stage: stageAt,
          mid,
          gap: Math.hypot(a.x - b.x, a.y - b.y),
          pinsVisible: onScreen(a) && onScreen(b),
          midClear: Boolean(
            under?.closest?.("[data-pa-stage]") &&
              !under?.closest?.(".alignment-handle") &&
              !under?.closest?.(".pa-div-icon"),
          ),
        };
      });
    }

    async function settledEdge() {
      let prev = null;
      for (let i = 0; i < 8; i++) {
        const cur = await pinEdge();
        if (
          cur &&
          cur.midClear &&
          cur.pinsVisible &&
          prev &&
          Math.hypot(cur.mid.x - prev.mid.x, cur.mid.y - prev.mid.y) < 2
        ) {
          return cur;
        }
        prev = cur;
        await page.waitForTimeout(400);
      }
      return null;
    }

    // Drags the pin midpoint toward the stage center so the next zoom
    // spreads the edge around the viewport middle. The press always
    // travels a real pan leg: releasing where it pressed would
    // synthesize a map click on the line.
    async function centerPinMid() {
      const g = await pinEdge();
      if (!g) return;
      const clamp = (v) => Math.max(-300, Math.min(300, v));
      const dx = clamp(g.stage.x - g.mid.x);
      const dy = clamp(g.stage.y - g.mid.y);
      if (Math.hypot(dx, dy) < 50) return;
      await page.mouse.move(g.stage.x, g.stage.y);
      await page.mouse.down();
      await page.mouse.move(g.stage.x + dx, g.stage.y + dy, { steps: 10 });
      await page.mouse.up();
      await page.waitForTimeout(500);
    }

    let clicked = false;
    for (let i = 0; i < 10 && !clicked; i++) {
      const found = await settledEdge();
      if (found && found.gap >= 140) {
        await page.mouse.click(found.mid.x, found.mid.y);
        clicked = true;
      } else {
        await centerPinMid();
        await page.locator("#alignment-map-root [data-pa-zoom-in]").click();
        await page.waitForTimeout(600);
      }
    }
    expect(clicked).toBe(true);

    await expect(
      page.locator("#alignment-map-root .alignment-handle"),
    ).toHaveCount(1, { timeout: 15000 });
    // The click must have hit section 1's own line: a neighbouring
    // section's line would have selected that section instead.
    await expect(page.locator("#alignment-section-1")).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    await page.locator("#alignment-map-root [data-pa-undo]").click();
    // Undo removes the inserted point and the handle count returns to the
    // straight baseline (a prior clear draft, if any, stays on the stack,
    // so only the count is asserted).
    await expect(handles).toHaveCount(0, { timeout: 15000 });

    expect(problems).toEqual([]);
  });

  test("saves the shared section locally and keeps the sibling exported", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);

    // Section 1 shares its straight path with the sibling pattern: add a
    // midpoint through the keyboard list and save it as this pattern's own.
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openAlignment(page, JOURNEY_PATTERN);
    await page.locator("#alignment-section-1").click();
    const edit = page.locator("#alignment-map-root [data-pa-edit]");
    await expect(edit).toBeEnabled({ timeout: 15000 });
    await edit.click();
    await page.locator("#alignment-point-list-toggle").click();
    // The saved interior count differs between a fresh seed and a full-file
    // run, so the midpoint assertion is relative: exactly one row added.
    const sharedRows = page.locator("#alignment-point-list .pa-point-row");
    const sharedBefore = await sharedRows.count();
    await page.locator("#alignment-point-list [data-add-midpoint]").click();
    await expect(sharedRows).toHaveCount(sharedBefore + 1);
    await expect(page.locator("#alignment-status")).toContainText(
      "Unsaved changes",
      { timeout: 15000 },
    );

    await saveThroughScope(page, 1);
    await expect(page.locator("#alignment-section-status-1")).toContainText(
      "✓ Saved",
    );

    // The sibling keeps its shared straight path and stays exported.
    await openAlignment(page, JOURNEY_SIBLING);
    await expect(page.locator("#alignment-status")).toContainText(
      "✓ Exported",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-section-status-1")).toContainText(
      "✓ Saved",
    );

    expect(problems).toEqual([]);
  });

  test("moves a focused point with the keyboard and restores it with Undo", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);

    // Section 1 holds saved interior points in every run state; if a
    // previous journey left it straight, seed one draft midpoint first.
    // Locate focuses the first handle, one ArrowRight commits a single
    // 2 px draft move, and one Undo restores exactly.
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openAlignment(page, JOURNEY_PATTERN);
    await page.locator("#alignment-section-1").click();
    const edit = page.locator("#alignment-map-root [data-pa-edit]");
    await expect(edit).toBeEnabled({ timeout: 15000 });
    await edit.click();
    await page.locator("#alignment-point-list-toggle").click();
    const keyRows = page.locator("#alignment-point-list .pa-point-row");
    if ((await keyRows.count()) === 0) {
      await page.locator("#alignment-point-list [data-add-midpoint]").click();
      await expect(keyRows).toHaveCount(1);
    }
    await page.locator('#alignment-point-list [data-point-check="0"]').check();
    await page.locator('#alignment-point-list [data-focus-point="0"]').click();
    await expect(
      page.locator("#alignment-map-root .alignment-handle:focus"),
    ).toHaveCount(1);

    const handleCenter = () =>
      page.evaluate(() => {
        const rect = document
          .querySelector("#alignment-map-root .alignment-handle")
          .getBoundingClientRect();
        return { x: (rect.left + rect.right) / 2, y: (rect.top + rect.bottom) / 2 };
      });

    const before = await handleCenter();
    const handle = page.locator("#alignment-map-root .alignment-handle").first();
    await handle.press("ArrowRight");
    await expect(page.locator("#alignment-map-root [data-pa-undo]")).toBeEnabled();
    const moved = await handleCenter();
    expect(moved.x - before.x).toBeGreaterThan(1);
    expect(moved.x - before.x).toBeLessThan(3.5);
    expect(Math.abs(moved.y - before.y)).toBeLessThan(1);

    await page.locator("#alignment-map-root [data-pa-undo]").click();
    const restored = await handleCenter();
    expect(Math.abs(restored.x - before.x)).toBeLessThan(1.5);
    expect(Math.abs(restored.y - before.y)).toBeLessThan(1.5);
    await expect(
      page.locator("#alignment-map-root [data-pa-undo]"),
    ).toBeDisabled();

    expect(problems).toEqual([]);
  });

  test("keeps the draft offline and saves it after reconnect", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);

    // Section 2 holds saved local points: another midpoint dirties
    // the draft, then the socket drops with the draft intact.
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openAlignment(page, JOURNEY_PATTERN);
    await page.locator("#alignment-section-2").click();
    const edit = page.locator("#alignment-map-root [data-pa-edit]");
    await expect(edit).toBeEnabled({ timeout: 15000 });
    await edit.click();
    await page.locator("#alignment-point-list-toggle").click();
    const offlineRows = page.locator("#alignment-point-list .pa-point-row");
    const offlineBefore = await offlineRows.count();
    await page.locator("#alignment-point-list [data-add-midpoint]").click();
    await expect(offlineRows).toHaveCount(offlineBefore + 1);
    await expect(page.locator("#alignment-section-status-2")).toContainText(
      "Unsaved",
      { timeout: 15000 },
    );

    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator("#alignment-save")).toBeDisabled({
      timeout: 15000,
    });
    // The draft badge survives the disconnect: no server roundtrip runs
    // while the socket is down, so nothing can clean it.
    await expect(page.locator("#alignment-section-status-2")).toContainText(
      "Unsaved",
    );
    await expect(page.locator("#pattern-connectivity")).toBeVisible();
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "journey-offline-1440");

    await page.evaluate(() => window.liveSocket.connect());
    await waitForLiveView(page);
    await expect(page.locator("#alignment-save")).toBeEnabled({
      timeout: 15000,
    });
    // Section 2 is a pattern-local override, so the review applies
    // directly with no scope dialog; the reconnect announcement already
    // proved the roundtrip above.
    await expect(page.locator("#status")).toContainText(
      "Reconnected. Your edits are ready to save.",
      { timeout: 15000 },
    );
    await page.locator("#alignment-save").click();
    await expect(page.locator("#status")).toContainText(
      "Map line saved.",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-section-status-2")).toContainText(
      "✓ Saved",
    );

    expect(problems).toEqual([]);
  });

  test("renders the imported, loop and long patterns", async ({ page }) => {
    test.setTimeout(180_000);
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    await page.setViewportSize({ width: 1440, height: 1000 });

    // The divergent imported pattern keeps its notice and dialog.
    await openAlignment(page, "BROWSER-ALIGN-IMPORTED");
    await expect(page.locator("#alignment-notice")).toContainText(
      "This pattern uses 2 imported shapes",
    );
    await page.locator("#alignment-review-import").click();
    await expect(page.locator("#alignment-import-dialog")).toHaveAttribute(
      "data-open",
      "true",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-import-dialog")).toContainText(
      "Choose an imported path",
    );
    await settleDialog(page, "alignment-import-dialog");
    await captureViewport(page, "journey-imported-dialog-1440");
    await page.locator("#alignment-import-dialog-cancel").click();
    await expect(page.locator("#alignment-import-dialog")).toHaveAttribute(
      "data-open",
      "false",
      { timeout: 15000 },
    );
    expect(await bodyFitsViewport(page)).toBe(true);

    // The loop's repeated stop shares one pin labelled with both visits.
    await openAlignment(page, "BROWSER-ALIGN-LOOP");
    await expect(page.locator("#alignment-map-root")).toContainText("1 / 4", {
      timeout: 15000,
    });
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "journey-loop-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    // The 200-visit pattern renders one row per section.
    await openAlignment(page, "BROWSER-ALIGN-LONG");
    await expect(
      page.locator("#alignment-sections > button[id^='alignment-section-']"),
    ).toHaveCount(199, { timeout: 30000 });
    await captureViewport(page, "journey-long-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });

  test("draws and saves the missing section at phone width", async ({
    page,
  }) => {
    test.setTimeout(180_000);
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);

    // The -B copy shares the first two sections' saved paths, so its
    // third section is the missing one — and the phone journey never
    // touches the records the desktop journey saved.
    await page.setViewportSize({ width: 320, height: 900 });
    await openAlignment(page, JOURNEY_NARROW);
    await page.locator("#alignment-section-3").click();
    await expect(page.locator("#alignment-draw")).toContainText(
      "Draw manually",
      { timeout: 15000 },
    );
    await captureFullPage(page, "journey-partial-320");

    await page.locator("#alignment-draw").click();
    await expect(page.locator("#alignment-point-list-toggle")).toBeVisible({
      timeout: 15000,
    });
    await page.locator("#alignment-point-list-toggle").click();
    await page.locator("#alignment-point-list [data-add-midpoint]").click();
    await expect(
      page.locator("#alignment-point-list .pa-point-row"),
    ).toHaveCount(1);
    await saveThroughScope(page, 3);
    await expect(page.locator("#alignment-section-status-3")).toContainText(
      "✓ Saved",
    );
    await captureFullPage(page, "journey-saved-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});
