import { test, expect } from "@playwright/test";

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser E2E Version";
const NEW_RUN_ID = "00000000-0000-4000-8000-000000000901";
const LEGACY_STATION_RUN_ID = "00000000-0000-4000-8000-000000000902";
const LEGACY_VALIDATION_RUN_ID = "00000000-0000-4000-8000-000000000905";

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function versionId(page) {
  const id = await page.evaluate((name) => {
    const option = Array.from(document.querySelectorAll("[data-version-option]")).find((button) =>
      button.textContent.trim().startsWith(name),
    );
    return option?.dataset.versionId ?? null;
  }, VERSION_NAME);

  if (!id) throw new Error(`${VERSION_NAME} is missing from the version switcher`);
  return id;
}

test.describe("Reachability result routes", () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
  });

  test("renders completed pathways-router station results", async ({ page }) => {
    const id = await versionId(page);
    await page.goto(`/gtfs/${id}/station-reachability/${NEW_RUN_ID}?stop_id=BROWSER_STATION`);

    await expect(page.locator("#station-reachability-results")).toBeVisible();
    await expect(page.getByText("Reachability results", { exact: true })).toBeVisible();
    await expect(page.locator("#pair-matrix")).toBeVisible();
  });

  test("renders legacy station results through the read-only boundary", async ({ page }) => {
    const id = await versionId(page);
    await page.goto(`/gtfs/${id}/station-reachability/${LEGACY_STATION_RUN_ID}?stop_id=BROWSER_STATION`);

    await expect(page.locator("#legacy-reachability-results")).toBeVisible();
    await expect(page.getByText("Retired engine", { exact: true })).toBeVisible();
    await expect(page.getByText("Legacy browser test", { exact: true })).toBeVisible();
  });

  test("renders legacy pathways results on the validation route", async ({ page }) => {
    const id = await versionId(page);
    await page.goto(`/gtfs/${id}/validation/${LEGACY_VALIDATION_RUN_ID}`);

    await expect(page.locator("#pathways-case-results")).toBeVisible();
  });
});
