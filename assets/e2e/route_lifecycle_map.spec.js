import { test, expect } from "@playwright/test";

/**
 * Route map workload timing (spec 16, step 32 — EV-8's exact second procedure).
 *
 * The browser half of the map-workload gate: on the deterministic 500-route
 * workload version seeded by `test/support/browser_seed.exs` ("Browser Map
 * Workload", routes BROWSER_MW_000 plus BROWSER_MW_001..499), this spec
 * measures the Details map render latency, the local color-picker feedback
 * (AC-19's declared under-100 ms bound) and the context pagination (AC-27)
 * on the declared workload. The ExUnit half — payload bytes, SQL query counts
 * and the fixed-geometry trip-multiplicity invariance — lives in
 * `test/gtfs_planner/gtfs/routes/map_performance_test.exs`.
 *
 * Measurements on this fixture establish mechanism and growth shape, not
 * deployed production capacity (R7). The only declared latency bound here is
 * the local preview's 100 ms; render and pagination timings are recorded and
 * attached to the report for the EV-8 artifact, never asserted against an
 * invented production limit.
 *
 * The tile HTTP boundary is the allowed external double: map tiles are
 * stubbed, every other surface is the real production composition.
 */

const TILE_PATTERN = /\/map\/tiles\//;

// Credentials mirrored from test/support/browser_seed.exs (test-only).
const WORKLOAD_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const WORKLOAD_VERSION_NAME = "Browser Map Workload";
const CURRENT_ROUTE = "BROWSER_MW_000";
const CONTEXT_ROUTES = 499;
const PAGE_SIZE = 50;
const PAGES = (CONTEXT_ROUTES - (CONTEXT_ROUTES % PAGE_SIZE)) / PAGE_SIZE + 1;

// A 2x2 transparent PNG served for every tile request.
function pngTile() {
  return Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP8z8DwnwEJMDEgAQBe" +
      "4QEKd3hXFAAAAABJRU5ErkJggg==",
    "base64",
  );
}

async function awaitConnected(page) {
  await page.waitForSelector("[data-phx-main].phx-connected");
}

async function logIn(page, user = WORKLOAD_USER) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function workloadVersionId(page) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: WORKLOAD_VERSION_NAME });

  await expect(option).toHaveCount(1);

  const id = await option.getAttribute("data-version-id");
  if (!id) {
    throw new Error("Browser Map Workload version is missing its version ID");
  }
  return id;
}

async function openWorkloadMap(page) {
  await page.route(TILE_PATTERN, (route) =>
    route.fulfill({ status: 200, body: pngTile(), contentType: "image/png" }),
  );
  await logIn(page);
  const version = await workloadVersionId(page);
  await page.goto(`/gtfs/${version}/routes/${CURRENT_ROUTE}`);
  await awaitConnected(page);
  await expect(page.locator("#route-map-frame")).toBeVisible();
}

function attachText(testInfo, name, lines) {
  testInfo.attach(name, {
    body: lines.join("\n"),
    contentType: "text/plain",
  });
}

test.describe("Route map workload", () => {
  test("the workload map renders the complete current route", async ({
    page,
  }, testInfo) => {
    await page.route(TILE_PATTERN, (route) =>
      route.fulfill({ status: 200, body: pngTile(), contentType: "image/png" }),
    );
    await logIn(page);
    const version = await workloadVersionId(page);

    const started = Date.now();
    await page.goto(`/gtfs/${version}/routes/${CURRENT_ROUTE}`);
    await awaitConnected(page);
    await expect(page.locator("#route-map-frame")).toBeVisible();

    // The complete current route drew: both patterns' geometry and the
    // imported shape variant are on the map, beside their pattern rows.
    await expect(page.locator("#route-map path").first()).toBeVisible();
    const renderMs = Date.now() - started;

    await expect(
      page.locator("#route-map-pattern-list [data-map-highlight]"),
    ).toHaveCount(2);
    const pathCount = await page.locator("#route-map path").count();
    expect(pathCount).toBeGreaterThan(0);

    attachText(testInfo, "map-workload-render.txt", [
      `route ${CURRENT_ROUTE} on the ${WORKLOAD_VERSION_NAME} version (500 routes)`,
      `render to first map geometry: ${renderMs} ms (recorded, no declared bound)`,
      `map paths drawn: ${pathCount}, pattern rows: 2`,
      "fixture-scale mechanism measurement, not deployed capacity (R7)",
    ]);
  });

  test("color picker feedback stays under 100 ms on the workload", async ({
    page,
  }, testInfo) => {
    await openWorkloadMap(page);

    // The draft is cancelled afterwards, so the journey writes nothing.
    const savedColor = await page.locator("#route-details-color").inputValue();

    let requests = 0;
    page.on("request", () => (requests += 1));

    // The typed color must reach the heading badge locally: measure the
    // repaint inside the page from the input event, frame-accurately.
    const feedbackMs = await page.evaluate(() => {
      const input = document.querySelector("#route-details-color");
      const badge = document.querySelector("#route-details-badge > span");
      if (!input || !badge) throw new Error("preview controls missing");

      const before = getComputedStyle(badge).backgroundColor;
      const started = performance.now();

      input.value = "5BC5F2";
      input.dispatchEvent(new Event("input", { bubbles: true }));

      return new Promise((resolve, reject) => {
        const deadline = started + 5000;
        const tick = () => {
          if (getComputedStyle(badge).backgroundColor !== before) {
            resolve(performance.now() - started);
          } else if (performance.now() > deadline) {
            reject(new Error("the color preview never updated the badge"));
          } else {
            requestAnimationFrame(tick);
          }
        };
        requestAnimationFrame(tick);
      });
    });

    expect(feedbackMs).toBeLessThan(100);
    expect(requests).toBe(0);

    attachText(testInfo, "map-workload-preview-latency.txt", [
      `local color preview feedback: ${feedbackMs.toFixed(1)} ms (declared bound: 100 ms)`,
      `network requests during the feedback window: ${requests}`,
      "fixture: the 500-route workload version (AC-19 on the declared fixture)",
    ]);

    // The editor reveals the save bar on blur: focus, blur, then cancel so
    // the journey restores the saved identity and writes nothing.
    const color = page.locator("#route-details-color");
    await color.focus();
    await color.blur();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();

    await page.locator("#route-details-discard").click();
    await expect(color).toHaveValue(savedColor);
    await expect(page.locator("#route-details-save-bar")).toBeHidden();
  });

  test("context pagination exhausts the 499 other workload routes", async ({
    page,
  }, testInfo) => {
    await openWorkloadMap(page);

    const firstPageStarted = Date.now();
    await page.locator("#route-map-context-toggle").check();
    await expect(page.locator("#route-map-context-status")).toContainText(
      "Showing the first 50 nearby routes. More are in this view.",
    );
    await expect(page.locator(".route-map-context-badge")).toHaveCount(
      PAGE_SIZE,
    );
    const firstPageMs = Date.now() - firstPageStarted;

    const pageTimings = [{ page: 1, ms: firstPageMs }];

    for (let shown = PAGE_SIZE; shown < CONTEXT_ROUTES; shown += PAGE_SIZE) {
      const started = Date.now();
      await page.locator("#route-map-context-more").click();

      if (shown + PAGE_SIZE < CONTEXT_ROUTES) {
        await expect(page.locator("#route-map-context-status")).toContainText(
          `Showing the first ${shown + PAGE_SIZE} nearby routes`,
        );
      } else {
        await expect(page.locator("#route-map-context-status")).toContainText(
          `Showing all ${CONTEXT_ROUTES} nearby routes in this view.`,
        );
      }

      pageTimings.push({
        page: pageTimings.length + 1,
        ms: Date.now() - started,
      });
    }

    // The full context is present: every other route exactly once, in
    // deterministic order, never the current route.
    const context = JSON.parse(
      await page.locator("#route-map").getAttribute("data-map-context"),
    );
    expect(context.routes.length).toBe(CONTEXT_ROUTES);

    const ids = context.routes.map((route) => route.route_id);
    expect(new Set(ids).size).toBe(CONTEXT_ROUTES);
    expect(ids).toEqual([...ids].sort());
    expect(ids).not.toContain(CURRENT_ROUTE);

    await expect(page.locator("#route-map-context-more")).toHaveCount(0);
    await expect(page.locator(".route-map-context-badge")).toHaveCount(
      CONTEXT_ROUTES,
    );

    attachText(testInfo, "map-workload-context-pagination.txt", [
      `context pagination on the ${CONTEXT_ROUTES + 1}-route workload (${PAGES} pages)`,
      ...pageTimings.map(
        ({ page, ms }) => `page ${page}: ${ms} ms (click to strip update)`,
      ),
      `total context routes shown: ${CONTEXT_ROUTES}`,
      "fixture-scale mechanism measurement, not deployed capacity (R7)",
    ]);
  });
});
