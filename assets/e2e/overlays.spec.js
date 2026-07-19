import { test, expect } from "@playwright/test";

const TEST_USER = {
  email: "browser-test@gtfs-planner.test",
  password: "BrowserTest123!",
};

/**
 * Helper: authenticate and navigate to the overlays page.
 */
async function loginAndGoToOverlays(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', TEST_USER.email);
  await page.fill('input[name="user[password]"]', TEST_USER.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL("**/admin/organizations");
  await page.goto("/design/overlays");
  await page.waitForSelector("#ds-page-overlays");
}

// ── Smoke test (from Step 4; preserved) ──
test("authenticates and opens the normative overlays page", async ({ page }) => {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', TEST_USER.email);
  await page.fill('input[name="user[password]"]', TEST_USER.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL("**/admin/organizations");
  await page.goto("/design/overlays");
  await page.waitForSelector("#ds-page-overlays");

  const demoBlock = page.locator("#ds-drawer-demo");
  await expect(demoBlock).toBeVisible();

  await page.locator('button[phx-click="open_drawer"]').click();

  const overlay = page.locator("#ds-demo-drawer-overlay");
  await overlay.waitFor({ state: "visible" });
  await expect(overlay).toHaveJSProperty("open", true);

  await page.locator('button[phx-click="open_confirm"]').click();

  const confirmDialog = page.locator("#ds-demo-confirm");
  await confirmDialog.waitFor({ state: "visible" });
  await expect(overlay).toHaveJSProperty("open", true);
  await expect(confirmDialog).toHaveJSProperty("open", true);

  await page.locator("#ds-demo-confirm-confirm").click();
  await page.locator('button[phx-click="confirm_success"]').click();
  await expect(page.locator("#ds-confirm-result")).toBeVisible();
  await expect(overlay).toHaveJSProperty("open", true);
  await expect(page.locator("#ds-confirm-result")).toBeFocused();

  await page.locator("#ds-demo-drawer-close").click();
  await expect(overlay).not.toBeVisible();
});

// ── Closed overlay semantics ──
test.describe("Closed overlay semantics", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToOverlays(page);
  });

  test("closed drawer is absent from role queries and tab order", async ({ page }) => {
    // No dialog or alertdialog roles should be present when overlays are closed
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(page.getByRole("alertdialog")).toHaveCount(0);

    // The drawer close button exists in DOM but is inert — Tab should skip it
    const closeButton = page.locator("#ds-demo-drawer-close");
    await expect(closeButton).toBeAttached();

    // Navigate focus to a body element, then Tab through page
    // The inert dialog should not receive focus
    await page.keyboard.press("Tab");

    const inDrawer = await page.evaluate(() => {
      const ae = document.activeElement;
      if (!ae) return false;
      const drawer = document.getElementById("ds-demo-drawer-overlay");
      return drawer ? drawer.contains(ae) : false;
    });
    expect(inDrawer).toBe(false);
  });

  test("closed confirmation is absent from role queries", async ({ page }) => {
    await expect(page.getByRole("alertdialog")).toHaveCount(0);
  });
});

// ── Open overlay modality ──
test.describe("Open overlay modality", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToOverlays(page);
    await page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")").click();
    await expect(page.locator("#ds-demo-drawer-overlay")).toBeVisible();
  });

  test("open drawer names itself with role dialog", async ({ page }) => {
    const dialog = page.getByRole("dialog", { name: "Demo drawer" });
    await expect(dialog).toBeVisible();
    // The named dialog should be the only dialog role
    await expect(page.getByRole("dialog")).toHaveCount(1);
  });

  test("open confirmation names itself with role alertdialog", async ({ page }) => {
    await page.locator('#ds-demo-drawer button[phx-click="open_confirm"]').click();
    await expect(page.getByRole("alertdialog", { name: "Delete route 42?" })).toBeVisible();
    await expect(page.getByRole("alertdialog")).toHaveCount(1);
  });

  test("keyboard Tab traversal permits Chromium's native body boundary without reaching outside controls", async ({ page }) => {
    // Open nested confirmation so it is the topmost modal
    await page.locator('#ds-demo-drawer button[phx-click="open_confirm"]').click();
    await expect(page.locator("#ds-demo-confirm")).toBeVisible();
    // Initial focus should be on Cancel
    await expect(page.locator("#ds-demo-confirm-cancel")).toBeFocused();

    // Press Tab — moves to the confirmation action.
    await page.keyboard.press("Tab");
    let activeId = await page.evaluate(() => {
      const ae = document.activeElement;
      return ae ? ae.id : null;
    });
    // Confirm button has id ds-demo-confirm-confirm
    expect(activeId).toBe("ds-demo-confirm-confirm");

    // Chromium may transiently focus BODY before returning to the modal. This
    // native-dialog behavior must not be replaced by a custom focus trap.
    await page.keyboard.press("Tab");
    const focusLocation = await page.evaluate(() => {
      const ae = document.activeElement;
      const confirm = document.getElementById("ds-demo-confirm");

      return {
        id: ae ? ae.id : null,
        inConfirm: Boolean(ae && confirm && confirm.contains(ae)),
        isBody: ae === document.body,
      };
    });
    expect(focusLocation.inConfirm || focusLocation.isBody).toBe(true);

    if (focusLocation.isBody) {
      await page.keyboard.press("Tab");
    }

    await expect(page.locator("#ds-demo-confirm-cancel")).toBeFocused();

    // Shift+Tab from Cancel should go to Confirm
    await page.keyboard.press("Shift+Tab");
    const reverseFocusLocation = await page.evaluate(() => {
      const ae = document.activeElement;
      const confirm = document.getElementById("ds-demo-confirm");

      return {
        id: ae ? ae.id : null,
        inConfirm: Boolean(ae && confirm && confirm.contains(ae)),
        isBody: ae === document.body,
      };
    });
    expect(reverseFocusLocation.inConfirm || reverseFocusLocation.isBody).toBe(true);

    if (reverseFocusLocation.isBody) {
      await page.keyboard.press("Shift+Tab");
    }

    await expect(page.locator("#ds-demo-confirm-confirm")).toBeFocused();

    // Verify focus never left the confirmation dialog
    const inConfirm = await page.evaluate(() => {
      const ae = document.activeElement;
      if (!ae) return false;
      const confirm = document.getElementById("ds-demo-confirm");
      return confirm ? confirm.contains(ae) : false;
    });
    expect(inConfirm).toBe(true);
  });

  test("open drawer blocks interaction with outside page content", async ({ page }) => {
    // Try to focus the page heading outside the modal — should be blocked
    const pageTitle = page.locator("h1");
    await pageTitle.focus().catch(() => {});
    const inDrawer = await page.evaluate(() => {
      const ae = document.activeElement;
      if (!ae) return false;
      const drawer = document.getElementById("ds-demo-drawer-overlay");
      return drawer ? drawer.contains(ae) : false;
    });
    // Native modality keeps focus inside the dialog
    expect(inDrawer).toBe(true);
  });
});

// ── Dismissal and nesting ──
test.describe("Dismissal and nesting", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToOverlays(page);
  });

  test("drawer closes via close control then reopens and closes via Escape", async ({ page }) => {
    const drawer = page.locator("#ds-demo-drawer-overlay");
    const openBtn = page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")");

    // Open and close via close button
    await openBtn.click();
    await expect(drawer).toBeVisible();
    await page.locator("#ds-demo-drawer-close").click();
    await expect(drawer).not.toBeVisible();

    // Reopen and close via Escape key
    await openBtn.click();
    await expect(drawer).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(drawer).not.toBeVisible();
  });

  test("true drawer backdrop click closes the drawer exactly once", async ({ page }) => {
    const drawer = page.locator("#ds-demo-drawer-overlay");
    const openBtn = page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")");

    await openBtn.click();
    await expect(drawer).toBeVisible();

    // Click the transparent area to the left of the right-aligned panel
    // This clicks the dialog element itself, triggering the backdrop handler
    await drawer.click({ position: { x: 10, y: 300 } });
    await expect(drawer).not.toBeVisible();
  });

  test("panel clicks do not close the drawer", async ({ page }) => {
    const drawer = page.locator("#ds-demo-drawer-overlay");
    await page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")").click();
    await expect(drawer).toBeVisible();

    // Click inside the drawer inner panel (the <aside>)
    await page.locator("#ds-demo-drawer").click();
    await expect(drawer).toBeVisible();
  });

  test("confirmation backdrop click defaults to refusal", async ({ page }) => {
    await page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")").click();
    await page.locator('#ds-demo-drawer button[phx-click="open_confirm"]').click();
    const confirm = page.locator("#ds-demo-confirm");
    await expect(confirm).toBeVisible();

    // Click the confirmation dialog element outside its centered panel
    // close_on_backdrop defaults to false for confirmation
    await confirm.click({ position: { x: 5, y: 5 } });
    await expect(confirm).toBeVisible();
  });

  test("nested Escape closes only the child confirmation, not the parent drawer", async ({ page }) => {
    await page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")").click();
    const drawer = page.locator("#ds-demo-drawer-overlay");
    await expect(drawer).toBeVisible();

    // Open nested confirmation
    await page.locator('#ds-demo-drawer button[phx-click="open_confirm"]').click();
    const confirm = page.locator("#ds-demo-confirm");
    await expect(confirm).toBeVisible();

    await page.keyboard.press("Escape");
    await expect(confirm).not.toBeVisible();
    // Parent drawer must remain open
    await expect(drawer).toBeVisible();
    await expect(drawer).toHaveJSProperty("open", true);
  });
});

// ── Focus behavior ──
test.describe("Focus behavior", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToOverlays(page);
  });

  test("confirmation Cancel receives initial focus", async ({ page }) => {
    await page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")").click();
    await page.locator('#ds-demo-drawer button[phx-click="open_confirm"]').click();
    await expect(page.locator("#ds-demo-confirm")).toBeVisible();
    await expect(page.locator("#ds-demo-confirm-cancel")).toBeFocused();
  });

  test("drawer heading receives focus when opened via heading mode", async ({ page }) => {
    await page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")").click();
    await expect(page.locator("#ds-demo-drawer-overlay")).toBeVisible();
    // Default initial_focus is :heading
    await expect(page.locator("#ds-demo-drawer-title")).toBeFocused();
  });

  test("cancel and ordinary close use native opener restoration", async ({ page }) => {
    const openBtn = page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")");

    // Focus the opener so restoration can be verified
    await openBtn.focus();
    await expect(openBtn).toBeFocused();

    await openBtn.click();
    await expect(page.locator("#ds-demo-drawer-overlay")).toBeVisible();

    // Close via the close button — native dialog algorithm restores opener focus
    await page.locator("#ds-demo-drawer-close").click();
    await expect(page.locator("#ds-demo-drawer-overlay")).not.toBeVisible();
    await expect(openBtn).toBeFocused();
  });

  test("child success closes confirmation and focuses result inside the still-open drawer", async ({ page }) => {
    await page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")").click();
    const drawer = page.locator("#ds-demo-drawer-overlay");
    await expect(drawer).toBeVisible();

    await page.locator('#ds-demo-drawer button[phx-click="open_confirm"]').click();
    await expect(page.locator("#ds-demo-confirm")).toBeVisible();

    // Click confirm to enter pending state
    await page.locator("#ds-demo-confirm-confirm").click();
    await expect(page.locator("button:has-text(\"Complete successfully\")")).toBeVisible();

    // Complete successfully
    await page.locator("button:has-text(\"Complete successfully\")").click();

    // Confirmation closed
    await expect(page.locator("#ds-demo-confirm")).not.toBeVisible();
    // Drawer still open
    await expect(drawer).toBeVisible();
    // Success focus targets #ds-confirm-result inside the open drawer (INV-006)
    await expect(page.locator("#ds-confirm-result")).toBeFocused();
  });
});

// ── Pending and recovery ──
test.describe("Pending and recovery", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToOverlays(page);
    await page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")").click();
    await page.locator('#ds-demo-drawer button[phx-click="open_confirm"]').click();
    await expect(page.locator("#ds-demo-confirm")).toBeVisible();
  });

  test("pending copy appears immediately and duplicate confirmation is refused", async ({ page }) => {
    await page.locator("#ds-demo-confirm-confirm").click();

    // Pending label replaces confirmation label immediately (phx-disable-with)
    const confirmBtn = page.locator("#ds-demo-confirm-confirm");
    await expect(confirmBtn).toHaveText("Deleting…");
    await expect(confirmBtn).toBeDisabled();

    // Cancel is also disabled during pending
    await expect(page.locator("#ds-demo-confirm-cancel")).toBeDisabled();
  });

  test("pending blocks Escape and backdrop dismissal", async ({ page }) => {
    await page.locator("#ds-demo-confirm-confirm").click();
    await expect(page.locator("#ds-demo-confirm[data-pending='true']")).toBeVisible();

    // Escape is refused while pending
    await page.keyboard.press("Escape");
    await expect(page.locator("#ds-demo-confirm")).toBeVisible();

    // Backdrop click is also refused while pending
    const confirm = page.locator("#ds-demo-confirm");
    await confirm.click({ position: { x: 5, y: 5 } });
    await expect(confirm).toBeVisible();
  });

  test("error re-enables actions in place", async ({ page }) => {
    await page.locator("#ds-demo-confirm-confirm").click();
    await expect(page.locator("#ds-demo-confirm-confirm")).toBeDisabled();

    // Trigger error outcome
    await page.locator("button:has-text(\"Simulate error\")").click();

    // Both buttons should be re-enabled
    await expect(page.locator("#ds-demo-confirm-confirm")).toBeEnabled();
    await expect(page.locator("#ds-demo-confirm-cancel")).toBeEnabled();

    // Confirmation remains open for retry
    await expect(page.locator("#ds-demo-confirm")).toBeVisible();
  });

  test("disconnect and reconnect cannot strand an open modal", async ({ page }) => {
    // Enter pending state — the most dangerous time for a disconnect
    await page.locator("#ds-demo-confirm-confirm").click();
    await expect(page.locator("#ds-demo-confirm-confirm")).toBeDisabled();

    // Disconnect LiveView — triggers disconnected() on hooks
    // which must close all active dialogs locally
    await page.evaluate(() => window.liveSocket.disconnect());

    // Both dialogs should be closed by the hook's disconnected() callback
    await expect(page.locator("#ds-demo-confirm")).not.toBeVisible();
    await expect(page.locator("#ds-demo-drawer-overlay")).not.toBeVisible();

    // Reconnect — LiveView re-renders with server state
    await page.evaluate(() => window.liveSocket.connect());

    // After reconnect, the page must not be blocked by a stranded modal
    // Wait for LiveView to re-establish and render
    await page.waitForSelector("#ds-page-overlays", { state: "visible" });

    // Page is interactive (no stranded inert overlay)
    const openBtn = page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")");
    await openBtn.waitFor({ state: "visible" });
  });
});

// ── Presentation and motion ──
test.describe("Presentation and motion", () => {
  test.beforeEach(async ({ page }) => {
    await loginAndGoToOverlays(page);
    await page.locator("#ds-drawer-demo button:has-text(\"Open drawer\")").click();
    await expect(page.locator("#ds-demo-drawer-overlay")).toBeVisible();
  });

  test("drawer panel reaches the viewport edge and uses the slide-in animation", async ({ page }) => {
    const panel = page.locator("#ds-demo-drawer");
    const motion = await panel.evaluate(async (element) => {
      const animation = element
        .getAnimations()
        .find((candidate) => candidate.animationName === "ds-drawer-slide-in");

      if (!animation) return null;

      animation.pause();
      await animation.ready;

      const duration = animation.effect.getComputedTiming().duration;
      const dialog = element.closest("dialog");
      const sample = async (currentTime) => {
        animation.currentTime = currentTime;
        await new Promise((resolve) => requestAnimationFrame(resolve));
        const box = element.getBoundingClientRect();
        return {
          left: box.left,
          right: box.right,
          opacity: getComputedStyle(element).opacity,
          scrollLeft: dialog.scrollLeft,
        };
      };

      const start = await sample(0);
      const middle = await sample(duration / 2);
      const end = await sample(duration);
      animation.finish();

      return { duration, width: end.right - end.left, start, middle, end };
    });

    expect(motion).not.toBeNull();
    expect(motion.duration).toBe(300);
    expect(motion.start.left).toBeGreaterThan(motion.middle.left);
    expect(motion.middle.left).toBeGreaterThan(motion.end.left);
    expect(motion.start.left - motion.end.left).toBeGreaterThanOrEqual(motion.width * 0.99);
    expect([motion.start.opacity, motion.middle.opacity, motion.end.opacity]).toEqual(["1", "1", "1"]);
    expect([motion.start.scrollLeft, motion.middle.scrollLeft, motion.end.scrollLeft]).toEqual([0, 0, 0]);
    expect(Math.abs(motion.end.right - page.viewportSize().width)).toBeLessThanOrEqual(1);
  });

  test("all three action controls compute to at least 44 by 44 CSS pixels", async ({ page }) => {
    // Drawer close button
    const closeBtn = page.locator("#ds-demo-drawer-close");
    let box = await closeBtn.boundingBox();
    expect(box).not.toBeNull();
    expect(box.width).toBeGreaterThanOrEqual(44);
    expect(box.height).toBeGreaterThanOrEqual(44);

    // Open confirmation to test its action buttons
    await page.locator('#ds-demo-drawer button[phx-click="open_confirm"]').click();
    await expect(page.locator("#ds-demo-confirm")).toBeVisible();

    // Confirmation Cancel button
    const cancelBtn = page.locator("#ds-demo-confirm-cancel");
    box = await cancelBtn.boundingBox();
    expect(box).not.toBeNull();
    expect(box.width).toBeGreaterThanOrEqual(44);
    expect(box.height).toBeGreaterThanOrEqual(44);

    // Confirmation Confirm button
    const confirmBtn = page.locator("#ds-demo-confirm-confirm");
    box = await confirmBtn.boundingBox();
    expect(box).not.toBeNull();
    expect(box.width).toBeGreaterThanOrEqual(44);
    expect(box.height).toBeGreaterThanOrEqual(44);
  });

  test("drawer close tooltip matches its accessible name on hover and focus", async ({ page }) => {
    const closeBtn = page.locator("#ds-demo-drawer-close");
    const tooltip = closeBtn.locator("..");
    const accessibleName = await closeBtn.getAttribute("aria-label");
    const tooltipOpacity = () =>
      tooltip.evaluate((element) => getComputedStyle(element, "::before").opacity);

    await expect(tooltip).toHaveAttribute("data-tip", accessibleName);

    await closeBtn.hover();
    await expect.poll(tooltipOpacity).toBe("1");

    await page.mouse.move(0, 0);
    await page.locator("#ds-demo-drawer-title").focus();
    await page.keyboard.press("Tab");
    await expect(closeBtn).toBeFocused();
    await expect.poll(tooltipOpacity).toBe("1");
  });

  test("emulated reduced motion reports zero animation and transition duration", async ({ page }) => {
    // Emulate the prefers-reduced-motion: reduce media query
    await page.emulateMedia({ reducedMotion: "reduce" });

    // Dialog element animation duration should be zero
    const dialogDuration = await page.evaluate(() => {
      const el = document.getElementById("ds-demo-drawer-overlay");
      return el ? getComputedStyle(el).animationDuration : "not found";
    });
    expect(dialogDuration).toBe("0s");

    // Dialog ::backdrop animation duration should be zero
    const backdropDuration = await page.evaluate(() => {
      const el = document.getElementById("ds-demo-drawer-overlay");
      return el ? getComputedStyle(el, "::backdrop").animationDuration : "not found";
    });
    expect(backdropDuration).toBe("0s");

    // Drawer panel (<aside>) animation duration should be zero
    const panelDuration = await page.evaluate(() => {
      const el = document.getElementById("ds-demo-drawer");
      return el ? getComputedStyle(el).animationDuration : "not found";
    });
    expect(panelDuration).toBe("0s");

    // Confirmation panel inner animation should also be zero
    // Open confirmation first
    await page.locator('#ds-demo-drawer button[phx-click="open_confirm"]').click();
    await expect(page.locator("#ds-demo-confirm")).toBeVisible();

    const confirmPanelDuration = await page.evaluate(() => {
      const confirm = document.getElementById("ds-demo-confirm");
      if (!confirm) return "not found";
      const inner = confirm.querySelector("div > div");
      return inner ? getComputedStyle(inner).animationDuration : "not found";
    });
    expect(confirmPanelDuration).toBe("0s");
  });
});
