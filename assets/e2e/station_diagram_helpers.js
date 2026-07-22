import { expect } from "@playwright/test";

const DIAGRAM_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

export async function loginAndGoToDiagram(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', DIAGRAM_USER.email);
  await page.fill('input[name="user[password]"]', DIAGRAM_USER.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL("**/");

  const diagramVersion = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: "Browser E2E Version" });
  await expect(diagramVersion).toHaveCount(1);

  const versionId = await diagramVersion.getAttribute("data-version-id");
  if (!versionId) throw new Error("Browser E2E Version is missing its version ID");

  await page.goto(`/gtfs/${versionId}/stops`);
  await page.waitForURL("**/stops");

  const stationRow = page.locator("tr:has-text('BROWSER_STATION')");
  await expect(stationRow).toBeVisible();
  await stationRow.getByRole("link").first().click();
  await page.waitForURL("**/stops/**");
  await page.getByRole("link", { name: "Floorplans" }).click();
  await expect(page.locator("#diagram-page")).toBeVisible();
}

export async function selectDiagramMode(page, mode) {
  const radio = page.locator(`#diagram-mode input[value="${mode}"]`);
  await page.locator(`label[for="diagram-mode-option-${mode}"]`).click();
  await expect(radio).toBeChecked();
}

export const onePixelPng = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLqXQAAAABJRU5ErkJggg==",
  "base64",
);
