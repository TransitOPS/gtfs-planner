import { test, expect } from "@playwright/test";

const ADMIN_USER = {
  email: "browser-test@gtfs-planner.test",
  password: "BrowserTest123!",
};

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

async function loginAsAdmin(page, path = "/admin/organizations") {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', ADMIN_USER.email);
  await page.fill('input[name="user[password]"]', ADMIN_USER.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL("**/admin/organizations");
  if (path !== "/admin/organizations") {
    await page.goto(path);
  }
}

async function loginAsEditor(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR_USER.email);
  await page.fill('input[name="user[password]"]', EDITOR_USER.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL("**/");
}

async function getGtfsVersionId(page) {
  const href = await page
    .locator('#app-header nav a[href*="/gtfs/"]')
    .first()
    .getAttribute("href");
  const match = href && href.match(/\/gtfs\/([^/]+)\//);
  if (!match) throw new Error("No /gtfs/ version link found: " + href);
  return match[1];
}

async function navigateToGtfsPage(page, versionId, subpath = "routes") {
  await page.goto(`/gtfs/${versionId}/${subpath}`);
  await page.waitForSelector("table");
}

// ── Shell and navigation at different viewports ──
test.describe("Shell and navigation responsive behavior", () => {
  test("320px viewport: no body overflow, all tasks visible", async ({ page }) => {
    await loginAsAdmin(page);
    await page.setViewportSize({ width: 320, height: 568 });

    await page.waitForSelector("#app-header nav");

    const bodyOverflow = await page.evaluate(() => {
      return document.body.scrollWidth <= window.innerWidth;
    });
    expect(bodyOverflow).toBe(true);

    // Check all navigation tasks are visible
    const navTasks = page.locator("#app-header nav a");
    const count = await navTasks.count();
    expect(count).toBeGreaterThan(0);

    // Verify each task is visible (not hidden by overflow)
    for (let i = 0; i < count; i++) {
      const task = navTasks.nth(i);
      const box = await task.boundingBox();
      expect(box).not.toBeNull();
      expect(box.width).toBeGreaterThan(0);
      expect(box.height).toBeGreaterThanOrEqual(44);
    }
  });

  test("768px viewport: shell wraps correctly", async ({ page }) => {
    await page.setViewportSize({ width: 768, height: 1024 });
    await loginAsAdmin(page);

    const bodyOverflow = await page.evaluate(() => {
      return document.body.scrollWidth <= window.innerWidth;
    });
    expect(bodyOverflow).toBe(true);

    const header = page.locator("#app-header");
    await expect(header).toBeVisible();
  });

  test("desktop viewport: shell layout is correct", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await loginAsAdmin(page);

    const bodyOverflow = await page.evaluate(() => {
      return document.body.scrollWidth <= window.innerWidth;
    });
    expect(bodyOverflow).toBe(true);
  });

  test("200% zoom: content reflows without overflow", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await loginAsAdmin(page);

    // Use CDP to set page scale factor (Chromium's zoom mechanism)
    const client = await page.context().newCDPSession(page);
    await client.send("Emulation.setPageScaleFactor", { pageScaleFactor: 2.0 });

    const bodyOverflow = await page.evaluate(() => {
      return document.body.scrollWidth <= window.innerWidth;
    });
    expect(bodyOverflow).toBe(true);

    // Reset zoom
    await client.send("Emulation.setPageScaleFactor", { pageScaleFactor: 1.0 });
    await client.detach();
  });
});

// ── Organizations trial (stacked table) ──
test.describe("Organizations trial responsive behavior", () => {
  test("stacked table at 320px: one representation, long names wrap", async ({ page }) => {
    await loginAsAdmin(page);
    await page.setViewportSize({ width: 320, height: 568 });

    // Wait for table to be visible
    await page.waitForSelector("table");

    // Check table structure
    const table = page.locator("table").first();
    await expect(table).toBeVisible();

    // Check only one tbody
    const tbodyCount = await page.locator("tbody#organizations").count();
    expect(tbodyCount).toBe(1);

    // Check rows exist
    const rows = page.locator("tbody#organizations tr");
    const rowCount = await rows.count();
    expect(rowCount).toBeGreaterThan(0);

    // Check no horizontal overflow
    const bodyOverflow = await page.evaluate(() => {
      return document.body.scrollWidth <= window.innerWidth;
    });
    expect(bodyOverflow).toBe(true);

    // Check long organization name wraps (from browser seed)
    const longOrg = page.locator("text=Metropolitan Regional Transit Authority");
    if (await longOrg.count() > 0) {
      const box = await longOrg.boundingBox();
      expect(box).not.toBeNull();
      // Should wrap to multiple lines or fit within viewport
      expect(box.width).toBeLessThanOrEqual(320);
    }
  });

  test("organization name is primary link", async ({ page }) => {
    await loginAsAdmin(page);

    // Find first organization row
    const firstRow = page.locator("tbody#organizations tr").first();
    const nameLink = firstRow.locator("a.link-primary").first();
    await expect(nameLink).toBeVisible();

    // Check it has the organization name
    const text = await nameLink.textContent();
    expect(text.trim().length).toBeGreaterThan(0);
  });

  test("keyboard navigation follows visual order", async ({ page }) => {
    await loginAsAdmin(page);

    // Tab through the page
    await page.keyboard.press("Tab");
    await page.keyboard.press("Tab");
    await page.keyboard.press("Tab");

    // Check focus is visible
    const focusedElement = await page.evaluate(() => {
      const el = document.activeElement;
      if (!el) return null;
      const rect = el.getBoundingClientRect();
      return {
        tag: el.tagName,
        visible: rect.width > 0 && rect.height > 0,
      };
    });

    expect(focusedElement).not.toBeNull();
    expect(focusedElement.visible).toBe(true);
  });
});

// ── Routes trial (scroll table) ──
test.describe("Routes trial responsive behavior", () => {
  test("scroll table at 320px: local overflow, no body clipping", async ({
    page,
  }) => {
    await loginAsEditor(page);
    const versionId = await getGtfsVersionId(page);
    await navigateToGtfsPage(page, versionId);
    await page.setViewportSize({ width: 320, height: 568 });

    const table = page.locator("table").first();
    await expect(table).toBeVisible();

    const tbodyCount = await page.locator("tbody#routes").count();
    expect(tbodyCount).toBe(1);

    const container = page.locator("#routes-container");
    const overflow = await container.evaluate((el) => {
      return window.getComputedStyle(el).overflowX;
    });
    expect(overflow).toBe("auto");

    const bodyOverflow = await page.evaluate(() => {
      return document.body.scrollWidth <= window.innerWidth;
    });
    expect(bodyOverflow).toBe(true);
  });

  test("route badge renders with safe colors", async ({ page }) => {
    await loginAsEditor(page);
    const versionId = await getGtfsVersionId(page);
    await navigateToGtfsPage(page, versionId);

    const badges = page.locator("tbody#routes span[style*='background-color']");
    const count = await badges.count();

    if (count > 0) {
      const firstBadge = badges.first();
      await expect(firstBadge).toBeVisible();

      const text = await firstBadge.textContent();
      expect(text.trim().length).toBeGreaterThan(0);
    }
  });

  test("long route names wrap correctly", async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 568 });
    await loginAsEditor(page);
    const versionId = await getGtfsVersionId(page);
    await navigateToGtfsPage(page, versionId);

    const longRoute = page.locator("td[data-label='Short Name']").first();
    if (await longRoute.count() > 0) {
      const box = await longRoute.boundingBox();
      expect(box).not.toBeNull();
      expect(box.width).toBeLessThanOrEqual(320);
    }
  });
});

// ── Version switcher ──
test.describe("Version switcher behavior", () => {
  test("version switcher is present on GTFS pages", async ({ page }) => {
    await loginAsEditor(page);
    const versionId = await getGtfsVersionId(page);
    await navigateToGtfsPage(page, versionId);

    const switcher = page.locator("#gtfs-version-switcher");
    await expect(switcher).toBeVisible();
  });

  test("version switcher select has 44px target", async ({ page }) => {
    await loginAsEditor(page);
    const versionId = await getGtfsVersionId(page);
    await navigateToGtfsPage(page, versionId);

    const select = page.locator("#gtfs-version-select");
    const box = await select.boundingBox();
    expect(box).not.toBeNull();
    expect(box.height).toBeGreaterThanOrEqual(44);
  });
});

// ── Reduced motion ──
test.describe("Reduced motion behavior", () => {
  test("reduced motion: animations are immediate", async ({ page }) => {
    // Set reduced motion preference
    await page.emulateMedia({ reducedMotion: "reduce" });

    await loginAsAdmin(page);

    // Check that motion-safe classes are disabled
    const skeleton = page.locator(".motion-safe\\:animate-pulse");
    if (await skeleton.count() > 0) {
      const animation = await skeleton.evaluate((el) => {
        return window.getComputedStyle(el).animationName;
      });
      // Should be "none" under reduced motion
      expect(animation).toBe("none");
    }
  });
});

// ── Focus and targets ──
test.describe("Focus and target sizes", () => {
  test("all interactive elements have visible focus", async ({ page }) => {
    await loginAsAdmin(page);

    // Find all focusable elements
    const focusable = page.locator(
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    );

    const count = await focusable.count();
    expect(count).toBeGreaterThan(0);

    // Check a sample of elements for focus visibility
    for (let i = 0; i < Math.min(count, 5); i++) {
      const element = focusable.nth(i);
      await element.focus();

      const hasFocusStyles = await element.evaluate((el) => {
        const styles = window.getComputedStyle(el);
        // Check for focus-visible or outline
        return (
          styles.outlineStyle !== "none" ||
          styles.boxShadow !== "none" ||
          el.classList.contains("focus-visible:ring-2")
        );
      });

      // At least some focus indication should be present
      expect(hasFocusStyles).toBe(true);
    }
  });

  test("navigation links have 44px minimum target", async ({ page }) => {
    await loginAsAdmin(page);

    const navLinks = page.locator("#app-header nav a");
    const count = await navLinks.count();

    for (let i = 0; i < count; i++) {
      const link = navLinks.nth(i);
      const box = await link.boundingBox();
      expect(box).not.toBeNull();
      expect(box.height).toBeGreaterThanOrEqual(44);
    }
  });
});

// ── Data view contracts ──
test.describe("Data view one-representation contract", () => {
  test("organizations table has one tbody, no duplicated rows", async ({
    page,
  }) => {
    await loginAsAdmin(page);

    const tbodyCount = await page.locator("tbody#organizations").count();
    expect(tbodyCount).toBe(1);

    // Check for duplicate IDs
    const duplicateIds = await page.evaluate(() => {
      const ids = Array.from(document.querySelectorAll("[id]")).map(
        (el) => el.id,
      );
      const uniqueIds = new Set(ids);
      return ids.length !== uniqueIds.size;
    });

    expect(duplicateIds).toBe(false);
  });

  test("routes table has one tbody, no duplicated rows", async ({ page }) => {
    await loginAsEditor(page);
    const versionId = await getGtfsVersionId(page);
    await navigateToGtfsPage(page, versionId);

    const tbodyCount = await page.locator("tbody#routes").count();
    expect(tbodyCount).toBe(1);

    const duplicateIds = await page.evaluate(() => {
      const ids = Array.from(document.querySelectorAll("[id]")).map(
        (el) => el.id,
      );
      const uniqueIds = new Set(ids);
      return ids.length !== uniqueIds.size;
    });

    expect(duplicateIds).toBe(false);
  });
});
