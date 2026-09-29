import { test, expect } from "@playwright/test";

/**
 * Paste timetable shell (step 21) plus the Change schedule drawer (step 22).
 *
 * The full paste journey lands in step 31; this file proves the shell
 * renders its schedule line and the drawer patches the schedule while the
 * paste stays. The fixture route comes from
 * `test/support/browser_seed.exs`: BROWSER_PASTE (route 12, Downtown –
 * Riverside) with the Weekday calendar, outbound BPS-MAIN and inbound
 * BPS-INBOUND patterns.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const PASTE_ROUTE = "BROWSER_PASTE";

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR_USER.email);
  await page.fill('input[name="user[password]"]', EDITOR_USER.password);
  await page.locator('button:has-text("Log in")').click();
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

function pastePath(versionId, routeId) {
  return `/gtfs/${versionId}/routes/${routeId}/schedules/paste`;
}

test.describe("Paste timetable shell", () => {
  test("the schedule line shows the Weekday outbound main pattern", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await expect(page.locator("#timetable-paste")).toBeVisible();
    await expect(page.locator("#paste-title")).toHaveText("Paste timetable");
    await expect(page.locator("#paste-scope-calendar")).toContainText("Weekday");
    await expect(page.locator("#paste-scope-direction")).toContainText("Outbound");
    await expect(page.locator("#paste-scope-pattern")).toContainText(
      "Central Station → Riverside Terminal",
    );
    await expect(page.locator("#paste-scope-open")).toContainText("Change schedule");
  });
});

test.describe("Change schedule drawer", () => {
  test("changing the direction refilters the patterns and patches the schedule", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await expect(page.locator("#paste-scope-pattern")).toContainText(
      "Central Station → Riverside Terminal",
    );

    await page.click("#paste-scope-open");
    await expect(page.locator("#paste-scope-drawer")).toBeVisible();
    await expect(page.locator("#paste-scope-form")).toBeVisible();
    await expect(page.locator("#paste-scope-calendar-field")).toBeFocused();
    await expect(page.locator("#paste-scope-calendar-field")).toContainText("Weekday");
    await expect(page.locator("#paste-scope-pattern-field")).toContainText(
      "Central Station → Riverside Terminal",
    );

    // Inbound refilters the patterns away from the outbound ones.
    await page.click("label:has(#paste-scope-direction-field-1)");
    await expect(page.locator("#paste-scope-pattern-field")).toContainText(
      "Riverside Terminal → Central Station",
    );
    await expect(page.locator("#paste-scope-pattern-field")).not.toContainText(
      "Central Station → Riverside Terminal",
    );

    await page.click("#paste-scope-apply");
    await expect(page).toHaveURL(/direction=1/);
    await expect(page.locator("#paste-scope-direction")).toContainText("Inbound");
    await expect(page.locator("#paste-scope-pattern")).toContainText(
      "Riverside Terminal → Central Station",
    );
  });

  test("Escape closes the drawer and returns focus to Change schedule", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.click("#paste-scope-open");
    await expect(page.locator("#paste-scope-drawer")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.locator("#paste-scope-open")).toBeFocused();
  });
});
