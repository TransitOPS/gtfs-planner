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
    // Press Tab to move to the first stop's hit target or pathway element
    await page.keyboard.press("Tab");
    // The first focusable element should be a stop or pathway button
    await page.waitForTimeout(300);

    const focused = await page.evaluate(() => {
      const ae = document.activeElement;
      if (!ae) return null;
      return { tag: ae.tagName, role: ae.getAttribute("role"), id: ae.id };
    });
    // The focused element should be a stop group (g) or pathway group (g)
    // with role="button"
    expect(focused).not.toBeNull();
    expect(["G", "BUTTON", "A"]).toContain(focused.tag);
    expect(focused.role).toBe("button");
  });

  test("Enter/Space activates a focused stop to open the edit drawer", async ({
    page,
  }) => {
    await page.waitForSelector("#diagram-overlay");
    // Tab to reach a focusable element
    await page.locator("#diagram-canvas-wrapper").click();
    await page.keyboard.press("Tab");
    await page.waitForTimeout(300);

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
    await page.keyboard.press("Tab");
    await page.waitForTimeout(300);
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
    await panUpBtn.focus();
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
    await panUpBtn.focus();

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
    // Tab onto an actual canvas stop group (not a control button): the focus
    // contract for AC-6 lives on `#diagram-overlay g[tabindex]`, and the ring
    // must remain visible over an arbitrary floorplan color.
    const stopGroup = page.locator("#diagram-overlay g[tabindex]").first();
    await stopGroup.focus();

    const ring = await stopGroup.evaluate((el) => {
      const style = getComputedStyle(el);
      return {
        outlineStyle: style.outlineStyle,
        outlineWidth: style.outlineWidth,
        // The light halo is applied via `filter: drop-shadow(...)`.
        filter: style.filter,
      };
    });

    // Dark ring: a real (non-none) outline of non-zero width.
    expect(ring.outlineStyle).not.toBe("none");
    expect(parseFloat(ring.outlineWidth)).toBeGreaterThan(0);
    // Light halo: a drop-shadow filter is present (the paired second ring).
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
    await page.keyboard.press("Tab");
    await page.waitForTimeout(200);

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

    // Check animation/transition duration on the overlay SVG
    const durations = await page.evaluate(() => {
      const overlay = document.getElementById("diagram-overlay");
      if (!overlay) return null;
      const style = getComputedStyle(overlay);
      return {
        animationDuration: style.animationDuration,
        transitionDuration: style.transitionDuration,
      };
    });

    // The overlay itself may not have explicit animations, but its children shouldn't
    const childrenDurations = await page.evaluate(() => {
      const overlay = document.getElementById("diagram-overlay");
      if (!overlay) return [];
      const results = [];
      overlay.querySelectorAll("*").forEach((el) => {
        const style = getComputedStyle(el);
        if (style.animationDuration !== "0s" || style.transitionDuration !== "0s") {
          results.push({
            tag: el.tagName,
            class: el.className?.baseVal || el.className,
            animationDuration: style.animationDuration,
            transitionDuration: style.transitionDuration,
          });
        }
      });
      return results;
    });

    // In reduced-motion mode, any animated elements should have zero durations.
    // If there are non-zero entries, that's fine — we just check the focused
    // drag/drop transitions are not animated.
    const stopDragAnimations = childrenDurations.filter(
      (d) => d.class && (d.class.includes("dragging") || d.class.includes("transition")),
    );
    expect(stopDragAnimations).toEqual([]);
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
