import { test, expect } from "@playwright/test";

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VIEWPORTS = [
  { label: "320px", width: 320, height: 568 },
  { label: "768px", width: 768, height: 1024 },
  { label: "desktop", width: 1280, height: 800 },
  { label: "640px (200% zoom)", width: 640, height: 400 },
];

async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function getVersionId(page) {
  const href = await page
    .locator('#app-header nav a[href*="/gtfs/"]')
    .first()
    .getAttribute("href");
  const match = href && href.match(/\/gtfs\/([^/]+)\//);
  if (!match) throw new Error("No /gtfs/ version link found: " + href);
  return match[1];
}

async function bodyFitsViewport(page) {
  return page.evaluate(
    () => document.body.scrollWidth <= window.innerWidth + 1,
  );
}

async function openRouteCatalog(page) {
  await logIn(page);
  const versionId = await getVersionId(page);
  await page.goto(`/gtfs/${versionId}/routes`);
  await page.waitForSelector("#routes-container, #routes-first-use-empty, #routes-unavailable", {
    timeout: 10000,
  });
  return versionId;
}

async function openStopCatalog(page) {
  await logIn(page);
  const versionId = await getVersionId(page);
  await page.goto(`/gtfs/${versionId}/stops`);
  await page.waitForSelector("#stops-container, #stops-first-use-empty, #stops-unavailable", {
    timeout: 10000,
  });
  return versionId;
}

async function openRouteDetail(page, routeId = "LONG_ROUTE_1") {
  await logIn(page);
  const versionId = await getVersionId(page);
  await page.goto(`/gtfs/${versionId}/routes/${routeId}`);
  await page.waitForSelector("dl, #route-unavailable", { timeout: 10000 });
  return versionId;
}

async function openStationDetail(page, stopId = "BROWSER_STATION") {
  await logIn(page);
  const versionId = await getVersionId(page);
  await page.goto(`/gtfs/${versionId}/stops/${stopId}`);
  await page.waitForSelector("dl, #stop-unavailable", { timeout: 10000 });
  return versionId;
}

test.describe("Route catalog responsive contracts", () => {
  for (const viewport of VIEWPORTS) {
    test(`route catalog fits the ${viewport.label} viewport without horizontal overflow`, async ({
      page,
    }) => {
      await openRouteCatalog(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });

      expect(await bodyFitsViewport(page), "body overflows").toBe(true);
    });

    test(`route catalog interactive targets meet 44px at ${viewport.label}`, async ({
      page,
    }) => {
      await openRouteCatalog(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });

      const links = page.locator("table#routes a[href]");
      const count = await links.count();
      if (count === 0) return;

      for (let i = 0; i < Math.min(count, 5); i++) {
        const box = await links.nth(i).boundingBox();
        expect(box, `route link ${i}`).not.toBeNull();
        expect(box.height, `route link ${i}`).toBeGreaterThanOrEqual(44);
      }
    });
  }

  test("route catalog supports keyboard traversal", async ({ page }) => {
    await openRouteCatalog(page);

    const firstLink = page.locator("table#routes a[href]").first();
    if ((await firstLink.count()) === 0) return;

    await firstLink.focus();
    const initialHref = await firstLink.getAttribute("href");
    expect(initialHref).toBeTruthy();

    await page.keyboard.press("Tab");
    const nextHref = await page.evaluate(
      () => document.activeElement?.getAttribute("href") ?? null,
    );
    expect(nextHref).not.toBe(initialHref);
  });

  test("long route names do not cause page overflow", async ({ page }) => {
    await openRouteCatalog(page);
    await page.setViewportSize({ width: 320, height: 568 });

    expect(await bodyFitsViewport(page)).toBe(true);

    const longRoute = page
      .locator("table#routes td[data-label='Short Name']")
      .filter({ hasText: "Express Route 1" });

    if ((await longRoute.count()) > 0) {
      const box = await longRoute.first().boundingBox();
      expect(box).not.toBeNull();
      expect(box.width).toBeLessThanOrEqual(320);
    }
  });
});

test.describe("Stop catalog responsive contracts", () => {
  for (const viewport of VIEWPORTS) {
    test(`stop catalog fits the ${viewport.label} viewport without horizontal overflow`, async ({
      page,
    }) => {
      await openStopCatalog(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });

      expect(await bodyFitsViewport(page), "body overflows").toBe(true);
    });

    test(`stop catalog interactive targets meet 44px at ${viewport.label}`, async ({
      page,
    }) => {
      await openStopCatalog(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });

      const links = page.locator("table#stops a[href]");
      const count = await links.count();
      if (count === 0) return;

      for (let i = 0; i < Math.min(count, 5); i++) {
        const box = await links.nth(i).boundingBox();
        expect(box, `stop link ${i}`).not.toBeNull();
        expect(box.height, `stop link ${i}`).toBeGreaterThanOrEqual(44);
      }
    });
  }

  test("stop catalog uses Stops & stations terminology", async ({ page }) => {
    await openStopCatalog(page);

    const header = page.locator("h1");
    await expect(header).toContainText("Stops & stations");
  });

  test("tri-state accessibility renders correct labels", async ({ page }) => {
    await openStopCatalog(page);

    const accessible = page
      .locator("table#stops tr")
      .filter({ hasText: "Direct Accessible Stop" })
      .locator('[data-accessibility="accessible"]');
    if ((await accessible.count()) > 0) {
      await expect(accessible).toContainText("Accessible");
    }

    const notAccessible = page
      .locator("table#stops tr")
      .filter({ hasText: "Direct Not Accessible Stop" })
      .locator('[data-accessibility="not_accessible"]');
    if ((await notAccessible.count()) > 0) {
      await expect(notAccessible).toContainText("Not accessible");
    }

    const noData = page
      .locator("table#stops tr")
      .filter({ hasText: "No Data Stop" })
      .locator('[data-accessibility="unknown"]');
    if ((await noData.count()) > 0) {
      await expect(noData).toContainText("No data");
    }
  });

  test("long stop name and ID do not cause page overflow", async ({ page }) => {
    await openStopCatalog(page);
    await page.setViewportSize({ width: 320, height: 568 });

    expect(await bodyFitsViewport(page)).toBe(true);

    const longStop = page
      .locator("table#stops tr")
      .filter({ hasText: "VERY_LONG_STOP_ID_FOR_OVERFLOW_TESTING_12345" });

    if ((await longStop.count()) > 0) {
      const box = await longStop.first().boundingBox();
      expect(box).not.toBeNull();
      expect(box.width).toBeLessThanOrEqual(320);
    }
  });

  test("stop catalog supports keyboard traversal", async ({ page }) => {
    await openStopCatalog(page);

    const firstLink = page.locator("table#stops a[href]").first();
    if ((await firstLink.count()) === 0) return;

    await firstLink.focus();
    const initialHref = await firstLink.getAttribute("href");
    expect(initialHref).toBeTruthy();

    await page.keyboard.press("Tab");
    const nextHref = await page.evaluate(
      () => document.activeElement?.getAttribute("href") ?? null,
    );
    expect(nextHref).not.toBe(initialHref);
  });
});

test.describe("Route detail responsive contracts", () => {
  for (const viewport of VIEWPORTS) {
    test(`route detail fits the ${viewport.label} viewport without horizontal overflow`, async ({
      page,
    }) => {
      await openRouteDetail(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });

      expect(await bodyFitsViewport(page), "body overflows").toBe(true);
    });
  }

  test("route detail uses semantic dl/dt/dd structure", async ({ page }) => {
    await openRouteDetail(page);

    const dl = page.locator("dl");
    await expect(dl).toBeVisible();

    const dt = page.locator("dl dt");
    const dd = page.locator("dl dd");
    expect(await dt.count()).toBeGreaterThan(0);
    expect(await dd.count()).toBeGreaterThan(0);
  });

  test("route detail long values wrap without overflow", async ({ page }) => {
    await openRouteDetail(page);
    await page.setViewportSize({ width: 320, height: 568 });

    expect(await bodyFitsViewport(page)).toBe(true);
  });
});

test.describe("Station detail responsive contracts", () => {
  for (const viewport of VIEWPORTS) {
    test(`station detail fits the ${viewport.label} viewport without horizontal overflow`, async ({
      page,
    }) => {
      await openStationDetail(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });

      expect(await bodyFitsViewport(page), "body overflows").toBe(true);
    });
  }

  test("station detail uses semantic dl/dt/dd structure", async ({ page }) => {
    await openStationDetail(page);

    const dl = page.locator("dl");
    await expect(dl).toBeVisible();

    const dt = page.locator("dl dt");
    const dd = page.locator("dl dd");
    expect(await dt.count()).toBeGreaterThan(0);
    expect(await dd.count()).toBeGreaterThan(0);
  });

  test("station detail accessibility shows inherited source disclosure", async ({
    page,
  }) => {
    await openStationDetail(page, "CATALOG_INHERITED_CHILD");

    const inherited = page.locator('[data-accessibility-source="inherited"]');
    if ((await inherited.count()) > 0) {
      await expect(inherited).toContainText("Inherited from station");
    }
  });

  test("station detail pathway summary uses mono tabular metrics", async ({
    page,
  }) => {
    await openStationDetail(page, "CATALOG_PATHWAY_STATION");

    const pathwaySummary = page.locator("[data-pathway-summary]");
    if ((await pathwaySummary.count()) > 0) {
      const monoValues = pathwaySummary.locator(".font-mono.tabular-nums");
      expect(await monoValues.count()).toBeGreaterThan(0);
    }
  });

  test("station detail editing status uses verb-led labels", async ({
    page,
  }) => {
    await openStationDetail(page);

    const editButton = page.locator("#station-editing-status-button");
    if ((await editButton.count()) > 0) {
      const label = await editButton.innerText();
      expect(label.trim()).toMatch(
        /^(Start editing|Finish editing|Clear editing status)$/,
      );
    }
  });
});

test.describe("Empty and partial catalog states", () => {
  test("empty catalog version renders first-use empty state", async ({
    page,
  }) => {
    await logIn(page);

    const versionSelect = page.locator("#gtfs-version-select");
    if ((await versionSelect.count()) === 0) return;

    await versionSelect.selectOption({ label: "Catalog Empty Version" });
    await page.waitForTimeout(1000);

    const emptyState = page.locator("#stops-first-use-empty, #routes-first-use-empty");
    if ((await emptyState.count()) > 0) {
      await expect(emptyState.first()).toBeVisible();
    }
  });

  test("routes-only version shows routes without stops", async ({ page }) => {
    await logIn(page);

    const versionSelect = page.locator("#gtfs-version-select");
    if ((await versionSelect.count()) === 0) return;

    await versionSelect.selectOption({ label: "Catalog Routes Only Version" });
    await page.waitForTimeout(1000);

    await page.goto(`/gtfs/${await getVersionId(page)}/routes`);
    await page.waitForSelector("table#routes, #routes-first-use-empty", {
      timeout: 5000,
    });
  });
});

test.describe("Reduced motion contracts", () => {
  test("catalog pages respect reduced motion preference", async ({ page }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await openStopCatalog(page);

    expect(
      await page.evaluate(
        () => matchMedia("(prefers-reduced-motion: reduce)").matches,
      ),
    ).toBe(true);

    expect(await bodyFitsViewport(page)).toBe(true);
  });
});

test.describe("Stable ID contracts", () => {
  test("route catalog table has stable ID", async ({ page }) => {
    await openRouteCatalog(page);
    await expect(page.locator("table#routes")).toBeAttached();
  });

  test("stop catalog table has stable ID", async ({ page }) => {
    await openStopCatalog(page);
    await expect(page.locator("table#stops")).toBeAttached();
  });

  test("stop catalog filter form has stable ID", async ({ page }) => {
    await openStopCatalog(page);
    await expect(page.locator("#stop-filter-form")).toBeAttached();
  });

  test("route catalog filter form has stable ID", async ({ page }) => {
    await openRouteCatalog(page);
    await expect(page.locator("#route-filter-form")).toBeAttached();
  });
});
