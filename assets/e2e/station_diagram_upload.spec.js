import { test, expect } from "@playwright/test";
import { loginAndGoToDiagram, onePixelPng } from "./station_diagram_helpers";

async function openReplacementDrawer(page) {
  await page.locator("#level-control-trigger").click();
  await page.locator("#replace-floorplan-action").click();
  await expect(page.locator("#diagram-upload-drawer-overlay")).toHaveAttribute(
    "data-open",
    "true",
  );
}

test.describe("Station diagram replacement", () => {
  test("requires confirmation and cancellation retains the referenced diagram", async ({
    page,
  }) => {
    await loginAndGoToDiagram(page);

    const currentDiagram = page.locator("#diagram-canvas-wrapper svg image");
    const priorSource = await currentDiagram.getAttribute("href");

    await openReplacementDrawer(page);
    const replacementInput = page.locator(
      "#diagram-upload-form-replace input[type=file]",
    );
    await replacementInput.setInputFiles({
      name: "replacement.png",
      mimeType: "image/png",
      buffer: onePixelPng,
    });

    await expect(
      page.locator("#diagram-replacement-confirmation"),
    ).toBeVisible();
    await page.locator("#diagram-replacement-confirmation-cancel").click();
    await expect(
      page.locator("#diagram-replacement-confirmation"),
    ).toBeHidden();
    await expect(currentDiagram).toHaveAttribute("href", priorSource);
    await expect(replacementInput).toBeFocused();
  });

  test("rejects an invalid replacement before it can replace the existing diagram", async ({
    page,
  }) => {
    await loginAndGoToDiagram(page);
    const currentDiagram = page.locator("#diagram-canvas-wrapper svg image");
    const priorSource = await currentDiagram.getAttribute("href");

    await openReplacementDrawer(page);
    await page
      .locator("#diagram-upload-form-replace input[type=file]")
      .setInputFiles({
        name: "not-a-diagram.png",
        mimeType: "image/png",
        buffer: Buffer.from("not a PNG"),
      });
    await expect(
      page.locator("#diagram-replacement-confirmation"),
    ).toBeVisible();
    await page.locator("#diagram-replacement-confirmation-confirm").click();

    await expect(
      page.locator("#diagram-replacement-confirmation"),
    ).toBeHidden();
    await expect(page.locator("#diagram-upload-drawer")).toContainText(
      "The selected file is not a valid PNG or JPEG diagram.",
    );
    await expect(currentDiagram).toHaveAttribute("href", priorSource);
  });
});
