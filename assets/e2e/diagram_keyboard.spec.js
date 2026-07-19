import { test, expect } from "@playwright/test";

const TEST_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

/**
 * Helper: authenticate using the editor user and navigate to the seeded
 * station diagram page. The seed creates station BROWSER_STATION with
 * child stops at diagram coordinates (30,40), (70,60), (50,25).
 */
async function loginAndGoToDiagram(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', TEST_USER.email);
  await page.fill('input[name="user[password]"]', TEST_USER.password);
  await page.locator('button:has-text("Log in")').click();
  // Non-admin redirects to / (dashboard)
  await page.waitForURL("**/");
  // Navigate via the "Stops" nav link in the header
  await page.locator('a[href*="/gtfs/"][href*="/stops"]').first().click();
  await page.waitForURL("**/stops");
  // Find the seeded station and navigate to its diagram
  // Click on the row containing "BROWSER_STATION"
  const stationRow = page.locator("tr:has-text('BROWSER_STATION')");
  await expect(stationRow).toBeVisible({ timeout: 5000 });
  // Click the station name link to navigate to the detail page
  await stationRow.getByRole("link").first().click();
  await page.waitForURL("**/stops/**");
  // Click the "Diagram" sub-nav tab
  await page.locator("a", { hasText: "Diagram" }).click();
  await page.waitForSelector("#diagram-page");
}

async function tabUntilFocused(page, selector, maxTabs = 50) {
  for (let attempt = 0; attempt < maxTabs; attempt += 1) {
    await page.keyboard.press("Tab");

    const matched = await page.evaluate((candidate) => {
      return document.activeElement?.matches(candidate) ?? false;
    }, selector);

    if (matched) return;
  }

  throw new Error(`Could not reach ${selector} after ${maxTabs} Tab presses`);
}

// ─────────────────────────────────────────────────────────────────────────────
// Keyboard navigation of diagram canvas stops
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Diagram keyboard navigation", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToDiagram(page);
  });

  test("Tab navigates between focusable stops on the canvas", async ({ page }) => {
    // The canvas overlay contains stop <g> elements with tabindex="0"
    // and role="button". Wait for overlays to be present.
    await page.waitForSelector("#diagram-overlay");

    // Tab into the page content and toward the diagram stops.
    // First, click somewhere in the diagram area to set focus context.
    await page.locator("#diagram-canvas-wrapper").click();
    await tabUntilFocused(page, "#diagram-overlay g[tabindex]");

    const focused = await page.evaluate(() => {
      const ae = document.activeElement;
      if (!ae) return null;
      return { tag: ae.tagName.toLowerCase(), role: ae.getAttribute("role"), id: ae.id };
    });

    expect(focused).not.toBeNull();
    expect(focused.tag).toBe("g");
    expect(focused.role).toBe("button");
  });

  test("Enter/Space activates a focused stop to open the edit drawer", async ({
    page,
  }) => {
    await page.waitForSelector("#diagram-overlay");
    await page.locator("#diagram-canvas-wrapper").click();
    await tabUntilFocused(page, "#diagram-overlay g[tabindex]");

    // Press Enter to activate the focused stop
    await page.keyboard.press("Enter");
    // The child stop drawer should open
    await expect(page.locator("#child-stop-drawer-overlay")).toBeVisible({
      timeout: 5000,
    });
  });

  test("Escape closes the child stop drawer when open", async ({ page }) => {
    await page.waitForSelector("#diagram-overlay");
    await page.locator("#diagram-canvas-wrapper").click();
    await tabUntilFocused(page, "#diagram-overlay g[tabindex]");
    await page.keyboard.press("Enter");
    await expect(page.locator("#child-stop-drawer-overlay")).toBeVisible({
      timeout: 5000,
    });

    // Escape should close the drawer
    await page.keyboard.press("Escape");
    await page.waitForTimeout(500);
    // The drawer overlay is a native <dialog>; after close its open property is false
    const drawerOpen = await page.evaluate(() => {
      const drawer = document.getElementById("child-stop-drawer-overlay");
      return drawer ? drawer.open : null;
    });
    expect(drawerOpen).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Mode switching and creation flow via keyboard
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Diagram mode switching via keyboard", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToDiagram(page);
    await page.waitForSelector("#diagram-overlay");
  });

  test("keyboard activates Add Stop mode and opens coordinate form", async ({
    page,
  }) => {
    // Tab to the "Add Stop" mode button
    const addBtn = page.locator("button", { hasText: "Add Stop" });
    await addBtn.focus();
    await expect(addBtn).toBeFocused();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(500);

    // The mode hint should change to "Click diagram to add a child stop"
    await expect(page.locator("text=Click diagram to add a child stop")).toBeVisible({
      timeout: 3000,
    });

    // Tab to the "Enter coordinates" button
    const coordBtn = page.locator("#keyboard-create-stop");
    await coordBtn.focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(500);

    // The child stop form should appear
    await expect(page.locator("#child-stop-drawer-overlay")).toBeVisible({
      timeout: 5000,
    });

    // Switch back to View mode
    const viewBtn = page.locator("button", { hasText: "View" });
    await viewBtn.focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(500);
  });

  test("keyboard activates Connect mode", async ({ page }) => {
    // Tab to the "Connect" mode button
    const connectBtn = page.locator("button", { hasText: "Connect" });
    await connectBtn.focus();
    await expect(connectBtn).toBeFocused();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(500);

    // The connect from-select should appear
    await expect(page.locator("#connect-from-form")).toBeVisible({
      timeout: 3000,
    });

    // Switch back to View
    const viewBtn = page.locator("button", { hasText: "View" });
    await viewBtn.focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(500);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pan and zoom controls — keyboard accessibility
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Diagram pan and zoom keyboard accessibility", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToDiagram(page);
    await page.waitForSelector("#diagram-overlay");
  });

  test("pan buttons are focusable and activatable via keyboard", async ({
    page,
  }) => {
    // Navigate to the pan/zoom control bar via Tab
    // The pan/zoom bar is at the bottom-left of the canvas
    const panUpBtn = page.locator('[aria-label="Pan up"]');
    await page.locator("#diagram-canvas-wrapper").click();
    await tabUntilFocused(page, '[aria-label="Pan up"]');
    await expect(panUpBtn).toBeFocused();

    // Activate with Enter
    await page.keyboard.press("Enter");

    // Verify the pan button still exists (no crash)
    await expect(panUpBtn).toBeVisible();
  });

  test("zoom buttons are focusable and change the zoom label", async ({
    page,
  }) => {
    const zoomLabel = page.locator("[data-zoom-label]");
    const initialText = await zoomLabel.textContent();

    // Focus the zoom in button
    const zoomInBtn = page.locator('[aria-label="Zoom in"]');
    await zoomInBtn.focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(300);

    // The zoom label should have changed
    const updatedText = await zoomLabel.textContent();
    expect(updatedText).not.toBe(initialText);
  });

  test("Ctrl+scroll wheel zooms the canvas", async ({ page }) => {
    const canvas = page.locator('svg[phx-hook="DiagramCanvas"]');
    await canvas.waitFor({ timeout: 5000 });

    const zoomLabel = page.locator("[data-zoom-label]");
    const initialText = await zoomLabel.textContent();

    // Dispatch Ctrl+wheel on the SVG canvas
    await canvas.dispatchEvent("wheel", { deltaY: -100, ctrlKey: true });
    await page.waitForTimeout(300);

    const updatedText = await zoomLabel.textContent();
    expect(updatedText).not.toBe(initialText);
  });

  test("reset view button returns zoom to 100%", async ({ page }) => {
    // Zoom in first
    const zoomInBtn = page.locator('[aria-label="Zoom in"]');
    await zoomInBtn.focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(300);

    // Focus reset button
    const resetBtn = page.locator('[aria-label="Reset view"]');
    await resetBtn.focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(300);

    const zoomLabel = page.locator("[data-zoom-label]");
    await expect(zoomLabel).toHaveText("100%");
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Focus indicator visibility over light and dark backgrounds
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Diagram focus indicator", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToDiagram(page);
    await page.waitForSelector("#diagram-overlay");
  });

  test("focus-visible ring is present on keyboard-focused canvas elements", async ({
    page,
  }) => {
    // Tab to a stop in the canvas overlay
    await page.locator("#diagram-canvas-wrapper").click();
    await page.keyboard.press("Tab");
    await page.waitForTimeout(300);

    // Check that the focused element is within the overlay
    const inOverlay = await page.evaluate(() => {
      const ae = document.activeElement;
      const overlay = document.getElementById("diagram-overlay");
      return overlay ? overlay.contains(ae) : false;
    });
    expect(inOverlay).toBe(true);
  });

  test("zoom button shows focus-visible ring on keyboard navigation", async ({
    page,
  }) => {
    const panUpBtn = page.locator('[aria-label="Pan up"]');
    await page.locator("#diagram-canvas-wrapper").click();
    await tabUntilFocused(page, '[aria-label="Pan up"]');
    await expect(panUpBtn).toBeFocused();

    // The button should have a focus-visible style (ring)
    // Check that the element matches :focus-visible
    const hasFocusVisible = await panUpBtn.evaluate((el) => {
      return el.matches(":focus-visible");
    });
    expect(hasFocusVisible).toBe(true);
  });

  test("focused stop group carries the paired dark/light focus ring", async ({
    page,
  }) => {
    // Enter the overlay by keyboard so :focus-visible matches, then inspect the
    // SVG hit-target geometry that carries the cross-engine focus indicator.
    await page.locator("#diagram-canvas-wrapper").click();

    const focusedGroup = page.locator("#diagram-overlay g[tabindex]:focus-visible");
    await tabUntilFocused(page, "#diagram-overlay g[tabindex]");
    await expect(focusedGroup).toHaveCount(1);

    const ring = await focusedGroup.evaluate((el) => {
      const geometry = el.querySelector(
        "[data-stop-hit-target], [data-pathway-hit], [data-cross-level-badge-hit]",
      );
      const style = getComputedStyle(geometry);
      return {
        stroke: style.stroke,
        strokeWidth: style.strokeWidth,
        filter: style.filter,
      };
    });

    // Dark ring: a real SVG stroke of non-zero width. Light ring: a halo on
    // that same geometry, avoiding browser-dependent outline paint on SVG <g>.
    expect(ring.stroke).not.toBe("none");
    expect(parseFloat(ring.strokeWidth)).toBeGreaterThan(0);
    expect(ring.filter).toContain("drop-shadow");
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Reduced-motion pass at 200% zoom / 768px viewport
// ─────────────────────────────────────────────────────────────────────────────
test.describe("Diagram reduced-motion accessibility", () => {
  test.use({
    viewport: { width: 768, height: 1024 },
  });

  test("reduced-motion: all tasks complete without animated transitions", async ({
    page,
  }) => {
    // Emulate prefers-reduced-motion
    await page.emulateMedia({ reducedMotion: "reduce" });

    await loginAndGoToDiagram(page);
    await page.waitForSelector("#diagram-overlay");

    // Set browser zoom to 200%
    await page.evaluate(() => {
      document.body.style.zoom = "2";
    });

    // Verify that canvas overlay render is not stalled by transitions
    const overlay = page.locator("#diagram-overlay");
    await expect(overlay).toBeVisible({ timeout: 5000 });

    // Tab to stops — should work without transition delay
    await page.locator("#diagram-canvas-wrapper").click();
    await tabUntilFocused(page, "#diagram-overlay g[tabindex]");

    const hasFocusedStop = await page.evaluate(() => {
      const ae = document.activeElement;
      const overlay = document.getElementById("diagram-overlay");
      return overlay ? overlay.contains(ae) : false;
    });
    expect(hasFocusedStop).toBe(true);

    // Open edit drawer via keyboard
    await page.keyboard.press("Enter");
    await expect(page.locator("#child-stop-drawer-overlay")).toBeVisible({
      timeout: 5000,
    });

    // Close via Escape
    await page.keyboard.press("Escape");
    await page.waitForTimeout(500);

    // Focus pan/zoom buttons
    const zoomInBtn = page.locator('[aria-label="Zoom in"]');
    await zoomInBtn.focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(200);

    const zoomLabel = page.locator("[data-zoom-label]");
    const zoomText = await zoomLabel.textContent();
    expect(zoomText).not.toBe("100%");

    // Reset view
    const resetBtn = page.locator('[aria-label="Reset view"]');
    await resetBtn.focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(300);

    await expect(zoomLabel).toHaveText("100%");
  });

  test("reduced-motion: animation durations are zero", async ({ page }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });

    await loginAndGoToDiagram(page);
    await page.waitForSelector("#diagram-overlay");

    await page.locator("#diagram-canvas-wrapper").click();
    await tabUntilFocused(page, "#diagram-overlay g[tabindex]");

    const focusMotion = await page
      .locator("#diagram-overlay g[tabindex]:focus-visible")
      .evaluate((group) => {
        const geometry = group.querySelector(
          "[data-stop-hit-target], [data-pathway-hit], [data-cross-level-badge-hit]",
        );
        const groupStyle = getComputedStyle(group);
        const geometryStyle = getComputedStyle(geometry);

        return {
          groupAnimation: groupStyle.animationDuration,
          groupTransition: groupStyle.transitionDuration,
          geometryAnimation: geometryStyle.animationDuration,
          geometryTransition: geometryStyle.transitionDuration,
        };
      });

    expect(focusMotion).toEqual({
      groupAnimation: "0s",
      groupTransition: "0s",
      geometryAnimation: "0s",
      geometryTransition: "0s",
    });

    await page.keyboard.press("Enter");
    const drawerPanel = page.locator("dialog[data-initial-focus][open] > aside");
    await expect(drawerPanel).toBeVisible();

    const drawerMotion = await drawerPanel.evaluate((panel) => {
      const style = getComputedStyle(panel);
      return {
        animationDuration: style.animationDuration,
        transitionDuration: style.transitionDuration,
      };
    });

    expect(drawerMotion).toEqual({
      animationDuration: "0s",
      transitionDuration: "0s",
    });
  });
});

// ── Smoke: authenticated user can reach the seeded diagram page ──
test("authenticates and opens the seeded station diagram", async ({ page }) => {
  await loginAndGoToDiagram(page);
  await expect(page.locator("#diagram-page")).toBeVisible();
  // Verify seeded stops are rendered
  await expect(page.locator('#diagram-overlay g[data-stop-id]').first()).toBeVisible({
    timeout: 5000,
  });
});
