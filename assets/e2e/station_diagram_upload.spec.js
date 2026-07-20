import { test, expect } from "@playwright/test";
import { loginAndGoToDiagram, onePixelPng } from "./station_diagram_helpers";

test.describe("Station diagram replacement", () => {
  test("requires confirmation and cancellation retains the referenced diagram", async ({ page }) => {
    await loginAndGoToDiagram(page);

    const currentDiagram = page.locator("#diagram-canvas-wrapper svg image");
    const priorSource = await currentDiagram.getAttribute("href");

    await page.locator("#diagram-upload-form-sub-nav input[type=file]").setInputFiles({
      name: "replacement.png",
      mimeType: "image/png",
      buffer: onePixelPng,
    });

    await expect(page.locator("#diagram-replacement-confirmation")).toBeVisible();
    await page.getByRole("button", { name: "Cancel" }).click();
    await expect(page.locator("#diagram-replacement-confirmation")).toBeHidden();
    await expect(currentDiagram).toHaveAttribute("href", priorSource);
    await expect(page.locator("#station-sub-nav-upload")).toBeFocused();
  });

  test("rejects an invalid replacement before it can replace the existing diagram", async ({ page }) => {
    await loginAndGoToDiagram(page);
    const currentDiagram = page.locator("#diagram-canvas-wrapper svg image");
    const priorSource = await currentDiagram.getAttribute("href");

    await page.locator("#diagram-upload-form-sub-nav input[type=file]").setInputFiles({
      name: "not-a-diagram.png",
      mimeType: "image/png",
      buffer: Buffer.from("not a PNG"),
    });
    await expect(page.locator("#diagram-replacement-confirmation")).toBeVisible();
    await page
      .locator("#diagram-replacement-confirmation-confirm")
      .click();

    await expect(page.locator("#diagram-replacement-confirmation")).toBeHidden();
    await expect(page.locator("#station-sub-nav")).toContainText(
      "The selected file is not a valid PNG or JPEG diagram.",
    );
    await expect(currentDiagram).toHaveAttribute("href", priorSource);
  });
});
