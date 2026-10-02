// Transfer helper policy journey (EV-5).
//
// Runs against the freshly seeded browser database the repository's Playwright
// configuration already uses (`bin/test-browser`, workers: 1, retries: 0) with
// `BROWSER_E2E=true`, and drives the real page: router → `TransfersLive` → the
// helper pack → `Transfers.apply_reviewed_policy_change/2` → PostgreSQL. Only
// the Esri tile hosts and the OpenRouter endpoint are faked, both at the network
// boundary, so no journey reaches the internet.
//
// The policy journey is the ordinary operator path the helper adds to this page:
// the draft they are writing becomes the one selection the helper may read, the
// prepared card hands its proposal to this page's own review, and only
// "Apply reviewed change" writes. Nothing here asserts the helper's prose; the
// review, the counts and the stored rule are the answer.
//
// The fixtures come from `test/support/browser_seed.exs`. The "Browser Transfers
// Version" carries the transfer network the journey writes one more rule into, so
// the seeded counts stay readable. `test/support/agents/browser_open_router.ex`
// scripts the provider: it prepares the page's own `selection-1` from the pack's
// real source snapshot, so a change in the page's draft is what the tool reads.
//
// Test titles keep the prefix branch review greps: policy.
import { test, expect } from "@playwright/test";

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "[redacted]",
};

const TRANSFERS_VERSION = "Browser Transfers Version";

// A 1x1 opaque PNG, so the tile layers succeed without a network request.
const ONE_PX_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC";

const TILE_ROUTE = "**/map/tiles/**";

const DESKTOP = { width: 1440, height: 1000 };
const PHONE = { width: 375, height: 812 };

test.describe.configure({ mode: "serial" });

let pageErrors = [];

test.beforeEach(async ({ page }) => {
  pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error));

  await page.route(TILE_ROUTE, (route) =>
    route.fulfill({
      status: 200,
      contentType: "image/png",
      body: Buffer.from(ONE_PX_PNG_BASE64, "base64"),
    }),
  );
});

test.afterEach(() => {
  expect(pageErrors).toEqual([]);
});

test.describe("transfer policy helper", () => {
  test("policy: the panel sits beside the editor and the draft becomes the source", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openDraft(page);

    await page.locator("#transfer-policy-select").click();

    // The source is the operator's own draft, shown back before they ask for
    // anything: the direction, the type and the seconds they typed.
    await expect(page.locator("#transfer-policy-selections")).toContainText(
      "BXF_CEN_C",
    );
    await expect(page.locator("#transfer-policy-selections")).toContainText(
      "BXF_MUS",
    );
    await expect(page.locator("#transfer-policy-selections")).toContainText(
      "300 seconds",
    );

    // The draft is still on screen: staging a selection saves nothing.
    await expect(page.locator("#transfer-editor")).toBeVisible();
    await expect(page.locator("#transfer-min-time")).toHaveValue("300");

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();
    await expect(page.locator("#agent-panel")).toContainText(
      "Transfers · " + TRANSFERS_VERSION,
    );

    // The panel takes its own column on a wide screen; the editor keeps the rest.
    await expect(page.locator("#transfer-editor")).toBeVisible();
    const fitsViewport = await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    );
    expect(fitsViewport).toBe(true);

    await capture(page, testInfo, "policy-source-1440x1000");

    // Clearing the selection takes the source away with it, so the panel has
    // nothing to read until the operator supplies one again.
    await page.locator("#transfer-policy-clear").click();
    await expect(page.locator("#transfer-policy-selections")).toHaveCount(0);

    await page.locator("#transfer-policy-select").click();
    await expect(page.locator("#transfer-policy-selections")).toHaveCount(1);

    await page.setViewportSize(PHONE);
    await capture(page, testInfo, "policy-source-375x812");
  });

  test("policy: the prepared card opens this page's review and only its confirm writes", async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openDraft(page);
    await stageDraft(page);

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();

    // Helper sessions live in the server process, so start a fresh one.
    await page.locator("#agent-new-conversation").click();

    await page
      .locator("#agent-composer-input")
      .fill("Give riders five minutes to change at Central Bay C");
    await page.locator("#agent-send").click();

    const reviewButton = page.locator('[id^="agent-review-prepared-"]').last();
    await expect(reviewButton).toHaveText("Review prepared transfer rule", {
      timeout: 30_000,
    });
    await expect(page.locator("#transfers-count")).toHaveText(
      "8 transfer rules",
      { timeout: 30_000 },
    );

    await reviewButton.click();

    // The review names the direction the operator wrote, in this version, and the
    // seconds their own draft carried.
    const review = page.locator("#transfer-policy-review");
    await expect(review).toBeVisible();
    await expect(page.locator("#transfer-policy-after")).toContainText("BXF_CEN_C");
    await expect(page.locator("#transfer-policy-after")).toContainText("BXF_MUS");
    await expect(page.locator("#transfer-policy-after")).toContainText(
      "300 seconds",
    );

    // Nothing is written until the reviewer confirms it.
    await expect(page.locator("#transfers-count")).toHaveText("8 transfer rules");

    await capture(page, testInfo, "policy-review-1440x1000");

    await page.locator("#transfer-policy-confirm").click();

    await expect(page.locator("#transfer-policy-status")).toContainText(
      "Saved transfer type 2",
      { timeout: 30_000 },
    );
    await expect(page.locator("#transfers-count")).toHaveText("9 transfer rules");

    // The receipt belongs to the entry that prepared this rule, settled by the
    // session's own event rather than by the page.
    await expect(page.locator('[id^="agent-prepared-"]').last()).toContainText(
      "Applied",
    );

    await capture(page, testInfo, "policy-saved-1440x1000");

    // The rule the operator reviewed is the one stored, in the direction they
    // wrote it.
    await expect(
      page.locator("#transfers").getByText("Transfer Central · Bay C"),
    ).toBeVisible();
  });

  test("policy: skipping a proposal writes nothing and says so", async ({
    page,
  }) => {
    await page.setViewportSize(DESKTOP);
    await openDraft(page);
    await stageDraft(page);

    await page.locator("#agent-helper-open").click();
    await expect(page.locator("#agent-panel")).toBeVisible();
    await page.locator("#agent-new-conversation").click();

    await page
      .locator("#agent-composer-input")
      .fill("Check what a transfer at Central Bay C would change");
    await page.locator("#agent-send").click();

    // The read prepares nothing, so the conversation settles with prose only and
    // no review button appears.
    await expect(page.locator("#agent-entries")).toContainText(
      "I prepared the transfer rule. Review it before applying.",
      { timeout: 30_000 },
    );

    // The page's own counts still read as an untouched version.
    await expect(page.locator("#transfers-count")).toHaveText("8 transfer rules");
    await expect(page.locator("#transfer-policy-review")).toHaveCount(0);
  });
});

// Signs in, reaches the seeded transfers version and opens a new draft whose
// direction and time this journey reviews.
async function openDraft(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR_USER.email);
  await page.fill('input[name="user[password]"]', EDITOR_USER.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));

  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: TRANSFERS_VERSION });
  await expect(option).toHaveCount(1);
  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${TRANSFERS_VERSION} is missing its version ID`);

  await page.goto(`/gtfs/${versionId}/transfers`);
  await page.waitForSelector("#transfers-create, #transfers-first-use-create", {
    timeout: 15_000,
  });

  await page.locator("#transfers-create").click();
  await expect(page.locator("#transfer-editor")).toBeVisible();
}

// Writes the draft this journey offers the helper: Bay C to the museum, a type 2
// rule with five minutes. The values go in the page's own editor.
async function stageDraft(page) {
  await pickStop(page, "from", "Transfer Central · Bay C");
  await pickStop(page, "to", "Transfer Museum");
  await page.locator("#transfer-min-time").fill("300");
  await page.locator("#transfer-policy-select").click();
  await expect(page.locator("#transfer-policy-selections")).toHaveCount(1);
}

async function pickStop(page, side, label) {
  const input = page.locator(`#transfer_${side}_stop_id_text_input`);

  await input.click();
  await input.fill(label);

  const option = page
    .locator(`#transfer-${side}-stop ul div[data-idx]`)
    .filter({ hasText: label })
    .first();
  await expect(option).toBeVisible();
  await option.click();
  await expect(input).toHaveValue(label);
}

async function capture(page, testInfo, name, subject) {
  if (subject) await subject.scrollIntoViewIfNeeded();
  await page.screenshot({
    path: testInfo.outputPath(`${name}.png`),
    animations: "disabled",
  });
}