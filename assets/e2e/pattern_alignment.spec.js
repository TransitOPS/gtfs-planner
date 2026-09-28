import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import { mkdirSync } from "node:fs";
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
    await expect(page.locator("#alignment-title")).toHaveText("Alignment");
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
    await expect(page.locator("#alignment-title")).toHaveText("Alignment");
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
      "Your alignment and stop list are still available.",
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
