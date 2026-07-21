import { test, expect } from "@playwright/test";
import {
  VIEWPORTS,
  bodyFitsViewport,
  readPendingStates,
  watchPendingState,
} from "./browser_helpers.js";

// Administration design contracts (Package 12, AC-1/2/7..13).
//
// Every scenario runs against the real Phoenix server, the production router,
// the production LiveViews, the shipped overlay hook, and the database-backed
// fixtures created by `test/support/browser_seed.exs`. Nothing is faked.
//
// The mutating scenarios own dedicated seeded rows, so they never disturb the
// users the other browser specs rely on. They do assume the standard
// `mise run prepare:browser` reset+seed before a run.

const ORG_ADMIN = {
  email: "admin-contracts@gtfs-planner.test",
  password: "AdminContracts123!",
};

const SYSTEM_ADMIN = {
  email: "browser-test@gtfs-planner.test",
  password: "BrowserTest123!",
};

const ADMIN_ORG_NAME = "Admin Contracts Org";

const MEMBERS = {
  active: "contracts-active@gtfs-planner.test",
  multiRole: "contracts-multirole@gtfs-planner.test",
  longEmail:
    "contracts-very-long-email-address-for-responsive-verification@long-domain-name-for-administration.gtfs-planner.test",
  deactivateTarget: "contracts-deactivate-target@gtfs-planner.test",
  deactivated: "contracts-deactivated@gtfs-planner.test",
  pending: "contracts-pending@gtfs-planner.test",
};

async function logIn(page, user) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function openMembers(page) {
  await logIn(page, ORG_ADMIN);
  await page.goto("/admin/users");
  await page.waitForSelector("#members-state tbody#members");
}

async function openOrganizations(page) {
  await logIn(page, SYSTEM_ADMIN);
  await page.goto("/admin/organizations");
  await page.waitForSelector("#organizations-state tbody#organizations");
}

async function adminOrgDetailPath(page) {
  const href = await page
    .getByRole("link", { name: ADMIN_ORG_NAME, exact: true })
    .getAttribute("href");
  if (!href) throw new Error(`No detail link for ${ADMIN_ORG_NAME}`);
  return href;
}

function rowAction(page, label) {
  return page.locator(`[aria-label="${label}"]`);
}

async function activeElementId(page) {
  return page.evaluate(() => document.activeElement?.id ?? null);
}

/** Waits out the 300ms slide-in so geometry is measured at rest. */
async function settleOverlay(page, id) {
  await page
    .locator(id)
    .evaluate((el) =>
      Promise.all(el.getAnimations({ subtree: true }).map((a) => a.finished)),
    );
}

// ── Routing and authorization (AC-1, AC-2) ──
test.describe("Administration routing and authorization", () => {
  test("the retired user detail route returns 404 for an authenticated admin", async ({
    page,
  }) => {
    await logIn(page, ORG_ADMIN);

    const response = await page.goto(
      "/admin/users/00000000-0000-0000-0000-000000000000",
    );

    expect(response.status()).toBe(404);
  });

  test("the retained organization-admin routes resolve for an organization admin", async ({
    page,
  }) => {
    await logIn(page, ORG_ADMIN);

    for (const path of [
      "/admin/users",
      "/admin/users/invite",
      "/admin/users/organization-settings",
    ]) {
      const response = await page.goto(path);
      expect(response.status(), path).toBe(200);
      await expect(page.locator("#members-state")).toBeAttached();
    }
  });

  test("an organization admin cannot reach system-admin organization routes", async ({
    page,
  }) => {
    await logIn(page, ORG_ADMIN);
    await page.goto("/admin/organizations");

    await expect(page).not.toHaveURL(/\/admin\/organizations/);
    await expect(page.locator("#organizations-state")).toHaveCount(0);
  });

  test("the member list never renders a member of another organization", async ({
    page,
  }) => {
    await openMembers(page);

    const body = await page.locator("body").innerText();
    expect(body).toContain(MEMBERS.active);
    expect(body).not.toContain(SYSTEM_ADMIN.email);
    expect(body).not.toContain("diagram-test@gtfs-planner.test");
  });
});

// ── Shared member presentation (AC-7) ──
test.describe("Shared member presentation", () => {
  test.beforeEach(async ({ page }) => {
    await openMembers(page);
  });

  test("members render in one streamed stacked table with stable row IDs", async ({
    page,
  }) => {
    await expect(page.locator("tbody#members")).toHaveCount(1);
    await expect(page.locator("table.ds-stack-table")).toHaveCount(1);

    const rowIds = await page
      .locator("tbody#members tr")
      .evaluateAll((rows) => rows.map((row) => row.id));

    expect(rowIds.length).toBeGreaterThanOrEqual(6);
    for (const id of rowIds) expect(id).toMatch(/^member-[0-9a-f-]{36}$/);
    expect(new Set(rowIds).size).toBe(rowIds.length);
  });

  test("status uses the shared colour-plus-text vocabulary", async ({
    page,
  }) => {
    const statusFor = async (email) =>
      page
        .locator("tbody#members tr")
        .filter({ hasText: email })
        .locator('[data-role="member-status"]')
        .innerText();

    expect((await statusFor(MEMBERS.active)).trim()).toBe("Active");
    expect((await statusFor(MEMBERS.deactivated)).trim()).toBe("Deactivated");
    expect((await statusFor(MEMBERS.pending)).trim()).toBe(
      "Invitation pending",
    );
  });

  test("a multi-role member renders one neutral chip per role", async ({
    page,
  }) => {
    const chips = page
      .locator("tbody#members tr")
      .filter({ hasText: MEMBERS.multiRole })
      .locator('[data-role="member-role"]');

    await expect(chips).toHaveCount(2);
    await expect(chips.nth(0)).toHaveText("Pathways Studio Admin");
    await expect(chips.nth(1)).toHaveText("Pathways Studio Editor");
  });

  test("row actions carry row-specific accessible names and pending labels", async ({
    page,
  }) => {
    const resend = rowAction(page, `Resend invite to ${MEMBERS.pending}`);
    const activate = rowAction(page, `Activate ${MEMBERS.deactivated}`);
    const deactivate = rowAction(page, `Deactivate ${MEMBERS.active}`);

    await expect(resend).toHaveAttribute("phx-disable-with", "Resending invite…");
    await expect(activate).toHaveAttribute("phx-disable-with", "Activating user…");
    await expect(deactivate).toHaveAttribute(
      "phx-disable-with",
      "Deactivating user…",
    );

    // Status decides which mutation a row offers, so the pair is exclusive.
    await expect(
      rowAction(page, `Activate ${MEMBERS.active}`),
    ).toHaveCount(0);
    await expect(
      rowAction(page, `Deactivate ${MEMBERS.deactivated}`),
    ).toHaveCount(0);
  });
});

// ── Organization-admin invitation by keyboard (AC-9, AC-12) ──
test.describe("Organization-admin invitation workflow", () => {
  test.beforeEach(async ({ page }) => {
    await openMembers(page);
  });

  test("the invite drawer opens by keyboard, focuses Email, and keeps the member list behind it", async ({
    page,
  }) => {
    await page.locator("#invite-user-trigger").focus();
    await page.keyboard.press("Enter");

    const overlay = page.locator("#invite-drawer-overlay");
    await expect(overlay).toBeVisible();
    await expect(page.getByRole("dialog", { name: "User invitation" })).toBeVisible();
    await expect(page.locator("#invite-email")).toBeFocused();

    // AC-12: the index stays rendered behind the drawer.
    await expect(page.locator("tbody#members tr").first()).toBeAttached();
    await expect(page).toHaveURL(/\/admin\/users\/invite$/);
  });

  test("Escape closes the invite drawer, returns to the index route, and restores trigger focus", async ({
    page,
  }) => {
    await page.locator("#invite-user-trigger").focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#invite-drawer-overlay")).toBeVisible();

    await page.keyboard.press("Escape");

    await expect(page.locator("#invite-drawer-overlay")).not.toBeVisible();
    await expect(page).toHaveURL(/\/admin\/users$/);
    await expect(page.locator("#invite-user-trigger")).toBeFocused();
  });

  test("Cancel closes the invite drawer and restores trigger focus", async ({
    page,
  }) => {
    await page.locator("#invite-user-trigger").focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#invite-drawer-overlay")).toBeVisible();

    await page.locator('#invite-drawer a:has-text("Cancel")').click();

    await expect(page.locator("#invite-drawer-overlay")).not.toBeVisible();
    await expect(page).toHaveURL(/\/admin\/users$/);
    await expect(page.locator("#invite-user-trigger")).toBeFocused();
  });

  test("an invalid email keeps the drawer open, retains the value, and focuses the email field", async ({
    page,
  }) => {
    await page.goto("/admin/users/invite");
    await expect(page.locator("#invite-email")).toBeFocused();

    await page.keyboard.type("not-an-email");
    await page.locator("#invite-roles-pathways_studio_editor").check();
    await page.locator('#invite-form button[type="submit"]').click();

    await expect(page.locator("#invite-drawer-overlay")).toBeVisible();
    await expect(page.locator("#invite-email")).toHaveAttribute(
      "aria-invalid",
      "true",
    );
    await expect(page.locator("#invite-email")).toHaveValue("not-an-email");
    await expect(page.locator("#invite-email")).toBeFocused();
    await expect(page.locator("#invite-roles-pathways_studio_editor")).toBeChecked();
  });

  test("a missing role selection reports on the roles group and focuses a control inside it", async ({
    page,
  }) => {
    await page.goto("/admin/users/invite");
    await expect(page.locator("#invite-email")).toBeFocused();

    // Fill and blur, so the email control is settled and valid before submit.
    await page.locator("#invite-email").fill(`roleless-${Date.now()}@gtfs-planner.test`);
    await page.keyboard.press("Tab");
    await expect(page.locator("#invite-email")).toHaveAttribute(
      "aria-invalid",
      "false",
    );

    await page.locator('#invite-form button[type="submit"]').click();

    await expect(page.locator("#invite-drawer-overlay")).toBeVisible();
    await expect(page.locator("#invite-roles-error")).toHaveText(
      /must select at least one role/,
    );
    await expect(page.locator("#invite-roles")).toHaveAttribute(
      "aria-invalid",
      "true",
    );
    await expect(page.locator("#invite-roles")).toHaveAttribute(
      "aria-describedby",
      /invite-roles-error/,
    );

    // AC-9: focus moves to the first invalid control, which for a grouped
    // control is the first checkbox inside the invalid group.
    await expect(
      page.locator("#invite-roles-pathways_studio_admin"),
    ).toBeFocused();
  });

  test("a keyboard invitation adds a pending member row and reports object-specific success", async ({
    page,
  }) => {
    const email = `invited-${Date.now()}@gtfs-planner.test`;

    await page.locator("#invite-user-trigger").focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#invite-email")).toBeFocused();

    await page.keyboard.type(email);
    await page.keyboard.press("Tab");
    await page.keyboard.press("Space"); // Pathways Studio Admin
    await page.keyboard.press("Tab");
    await page.keyboard.press("Space"); // Pathways Studio Editor
    await page.keyboard.press("Tab"); // Cancel
    await page.keyboard.press("Tab"); // Send invite
    await page.keyboard.press("Enter");

    await expect(page.locator("#invite-drawer-overlay")).not.toBeVisible();
    await expect(page).toHaveURL(/\/admin\/users$/);
    await expect(page.locator("#member-action-feedback")).toContainText(
      `Invitation sent to ${email}.`,
    );

    const row = page.locator("tbody#members tr").filter({ hasText: email });
    await expect(row).toHaveCount(1);
    await expect(row.locator('[data-role="member-status"]')).toHaveText(
      /Invitation pending/,
    );
    await expect(row.locator('[data-role="member-role"]')).toHaveCount(2);
    await expect(rowAction(page, `Resend invite to ${email}`)).toBeVisible();
  });

  test("inviting an existing member reports the conflict in flow and creates no row", async ({
    page,
  }) => {
    const rowsBefore = await page.locator("tbody#members tr").count();

    await page.goto("/admin/users/invite");
    await expect(page.locator("#invite-email")).toBeFocused();

    await page.keyboard.type(MEMBERS.active);
    await page.locator("#invite-roles-pathways_studio_editor").check();
    await page.locator('#invite-form button[type="submit"]').click();

    await expect(page.locator("#invite-service-error")).toBeVisible();
    await expect(page.locator("#invite-service-error")).toContainText(
      "already a member of this organization",
    );
    await expect(page.locator("#invite-drawer-overlay")).toBeVisible();

    await page.keyboard.press("Escape");
    await expect(page.locator("tbody#members tr")).toHaveCount(rowsBefore);
  });
});

// ── Row mutations, pending state, and destructive confirmation (AC-10, AC-11) ──
test.describe("Organization-admin member mutations", () => {
  test.beforeEach(async ({ page }) => {
    await openMembers(page);
  });

  test("resend invite shows its own pending label, blocks a duplicate submit, and reports per-member feedback", async ({
    page,
  }) => {
    const selector = `[aria-label="Resend invite to ${MEMBERS.pending}"]`;
    await watchPendingState(page, selector);
    await page.locator(selector).click();

    const states = await readPendingStates(page);
    const pending = states.find(
      (state) => state.disabled && state.text === "Resending invite…",
    );
    expect(
      pending,
      `no disabled "Resending invite…" state observed in ${JSON.stringify(states)}`,
    ).toBeTruthy();

    await expect(page.locator("#member-action-feedback")).toContainText(
      `Invitation resent to ${MEMBERS.pending}.`,
    );
  });

  test("activation refreshes the row to Active and swaps the offered action", async ({
    page,
  }) => {
    await rowAction(page, `Activate ${MEMBERS.deactivated}`).click();

    await expect(page.locator("#member-action-feedback")).toContainText(
      `${MEMBERS.deactivated} activated.`,
    );

    const row = page
      .locator("tbody#members tr")
      .filter({ hasText: MEMBERS.deactivated });
    await expect(row.locator('[data-role="member-status"]')).toHaveText(
      /Active/,
    );
    await expect(
      rowAction(page, `Deactivate ${MEMBERS.deactivated}`),
    ).toBeVisible();
    await expect(
      rowAction(page, `Activate ${MEMBERS.deactivated}`),
    ).toHaveCount(0);

    // Restore the seeded state so the file is re-runnable.
    await rowAction(page, `Deactivate ${MEMBERS.deactivated}`).click();
    await page.locator("#deactivate-user-dialog-confirm").click();
    await expect(
      rowAction(page, `Activate ${MEMBERS.deactivated}`),
    ).toBeVisible();
  });

  test("the deactivation dialog names the member and both consequences", async ({
    page,
  }) => {
    await rowAction(page, `Deactivate ${MEMBERS.deactivateTarget}`).click();

    const dialog = page.getByRole("alertdialog");
    await expect(dialog).toBeVisible();
    await expect(page.locator("#deactivate-user-dialog-title")).toHaveText(
      `Deactivate ${MEMBERS.deactivateTarget}?`,
    );

    const body = await page.locator("#deactivate-user-dialog-body").innerText();
    expect(body).toContain(MEMBERS.deactivateTarget);
    expect(body).toContain(`loses access to ${ADMIN_ORG_NAME}`);
    expect(body).toContain("signed out of every web and mobile session");
    expect(body).toContain("can be activated again from this list");

    await expect(page.locator("#deactivate-user-dialog-confirm")).toHaveText(
      "Deactivate user",
    );
  });

  test("Escape cancels the deactivation dialog and returns focus to the row trigger", async ({
    page,
  }) => {
    const trigger = rowAction(page, `Deactivate ${MEMBERS.deactivateTarget}`);
    const triggerId = await trigger.getAttribute("id");

    await trigger.focus();
    await page.keyboard.press("Enter");

    await expect(page.locator("#deactivate-user-dialog")).toBeVisible();
    await expect(page.locator("#deactivate-user-dialog-cancel")).toBeFocused();

    await page.keyboard.press("Escape");

    await expect(page.locator("#deactivate-user-dialog")).not.toBeVisible();
    expect(await activeElementId(page)).toBe(triggerId);

    // Cancelling clears the target: the row is untouched.
    const row = page
      .locator("tbody#members tr")
      .filter({ hasText: MEMBERS.deactivateTarget });
    await expect(row.locator('[data-role="member-status"]')).toHaveText(
      /Active/,
    );
  });

  test("confirming by keyboard deactivates the member, shows the pending label, and closes the dialog", async ({
    page,
  }) => {
    await rowAction(page, `Deactivate ${MEMBERS.deactivateTarget}`).focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#deactivate-user-dialog-cancel")).toBeFocused();

    await page.keyboard.press("Tab");
    await expect(page.locator("#deactivate-user-dialog-confirm")).toBeFocused();

    await watchPendingState(page, "#deactivate-user-dialog-confirm");
    await page.keyboard.press("Enter");

    const states = await readPendingStates(page);
    const pending = states.find(
      (state) => state.disabled && state.text === "Deactivating user…",
    );
    expect(
      pending,
      `no disabled "Deactivating user…" state observed in ${JSON.stringify(states)}`,
    ).toBeTruthy();

    await expect(page.locator("#deactivate-user-dialog")).not.toBeVisible();
    await expect(page.locator("#member-action-feedback")).toContainText(
      `${MEMBERS.deactivateTarget} deactivated.`,
    );

    const row = page
      .locator("tbody#members tr")
      .filter({ hasText: MEMBERS.deactivateTarget });
    await expect(row.locator('[data-role="member-status"]')).toHaveText(
      /Deactivated/,
    );
    const restored = rowAction(page, `Activate ${MEMBERS.deactivateTarget}`);
    await expect(restored).toBeVisible();
    // Confirmation state is cleared on success: focus lands on the new action.
    expect(await activeElementId(page)).toBe(await restored.getAttribute("id"));

    // Restore the seeded state so the file is re-runnable.
    await restored.click();
    await expect(
      rowAction(page, `Deactivate ${MEMBERS.deactivateTarget}`),
    ).toBeVisible();
  });
});

// ── System-admin organization workflows (AC-8, AC-12) ──
test.describe("System-admin organization workflows", () => {
  test.beforeEach(async ({ page }) => {
    await openOrganizations(page);
  });

  test("the create drawer opens by keyboard, refuses an invalid organization, and Escape restores trigger focus", async ({
    page,
  }) => {
    await page.locator("#create-organization-trigger").focus();
    await page.keyboard.press("Enter");

    const overlay = page.locator("#org-drawer-overlay");
    await expect(overlay).toBeVisible();
    await expect(page.locator("#organization-name")).toBeFocused();
    // AC-12: the index stays rendered behind the drawer.
    await expect(page.locator("tbody#organizations tr").first()).toBeAttached();

    const rowsBefore = await page.locator("tbody#organizations tr").count();

    // A blank required field is refused by the shipped constraint before the
    // command is sent: the drawer stays open and nothing is created.
    await page.locator('#org-form button[type="submit"]').click();
    await expect(overlay).toBeVisible();
    expect(
      await page.locator("#organization-name").evaluate((el) => el.validity.valueMissing),
    ).toBe(true);
    await expect(page.locator("tbody#organizations tr")).toHaveCount(rowsBefore);

    // A server-side conflict attaches to its own control and keeps the values.
    await page.locator("#organization-name").fill("Duplicate Alias Org");
    await page.locator("#organization-alias").fill("admin-contracts");
    await page.locator('#org-form button[type="submit"]').click();

    await expect(overlay).toBeVisible();
    await expect(page.locator("#organization-alias")).toHaveAttribute(
      "aria-invalid",
      "true",
    );
    await expect(page.locator("#organization-alias-error")).toBeVisible();
    await expect(page.locator("#organization-name")).toHaveValue(
      "Duplicate Alias Org",
    );
    await expect(page.locator("tbody#organizations tr")).toHaveCount(rowsBefore);

    await page.keyboard.press("Escape");
    await expect(overlay).not.toBeVisible();
    await expect(page).toHaveURL(/\/admin\/organizations$/);
    await expect(page.locator("#create-organization-trigger")).toBeFocused();
  });

  test("the edit drawer opens from a row action and returns focus to that row action", async ({
    page,
  }) => {
    const detailPath = await adminOrgDetailPath(page);
    const orgId = detailPath.split("/").pop();
    const trigger = page.locator(`#edit-organization-${orgId}`);

    await trigger.focus();
    await page.keyboard.press("Enter");

    await expect(page.locator("#org-drawer-overlay")).toBeVisible();
    await expect(page.locator("#organization-name")).toHaveValue(ADMIN_ORG_NAME);

    await page.keyboard.press("Escape");

    await expect(page.locator("#org-drawer-overlay")).not.toBeVisible();
    expect(await activeElementId(page)).toBe(`edit-organization-${orgId}`);
  });

  test("organization detail keeps the record behind the invite drawer and Cancel returns to it", async ({
    page,
  }) => {
    const detailPath = await adminOrgDetailPath(page);
    await page.goto(detailPath);
    await page.waitForSelector("#members-state tbody#members");

    await expect(page.locator("#organization-id")).toHaveText(
      /^[0-9a-f-]{36}$/,
    );

    await page.locator("#invite-member-trigger").focus();
    await page.keyboard.press("Enter");

    await expect(page.locator("#invite-drawer-overlay")).toBeVisible();
    await expect(page.locator("#invite-email")).toBeFocused();
    // The detail record and its member list stay rendered behind the drawer.
    await expect(page.locator("#organization-id")).toBeAttached();
    await expect(page.locator("tbody#members tr").first()).toBeAttached();

    await page.locator('#invite-drawer a:has-text("Cancel")').click();

    await expect(page.locator("#invite-drawer-overlay")).not.toBeVisible();
    await expect(page).toHaveURL(new RegExp(`${detailPath}$`));
    await expect(page.locator("#invite-member-trigger")).toBeFocused();
  });

  test("the same member vocabulary renders on the system-admin surface", async ({
    page,
  }) => {
    await page.goto(await adminOrgDetailPath(page));
    await page.waitForSelector("#members-state tbody#members");

    await expect(page.locator("tbody#members")).toHaveCount(1);
    await expect(
      rowAction(page, `Resend invite to ${MEMBERS.pending}`),
    ).toBeVisible();
    await expect(
      page
        .locator("tbody#members tr")
        .filter({ hasText: MEMBERS.pending })
        .locator('[data-role="member-status"]'),
    ).toHaveText(/Invitation pending/);
  });

  test("an unknown organization ID renders the recovery state without echoing the ID", async ({
    page,
  }) => {
    const unknown = "11111111-2222-3333-4444-555555555555";
    await page.goto(`/admin/organizations/${unknown}`);

    await expect(page.locator("#organization-record-state")).toBeVisible();
    await expect(page.locator("#back-to-organizations")).toBeVisible();
    expect(await page.locator("body").innerText()).not.toContain(unknown);
  });

  test("a malformed organization ID renders the same recovery state", async ({
    page,
  }) => {
    await page.goto("/admin/organizations/not-a-uuid");

    await expect(page.locator("#organization-record-state")).toBeVisible();
    expect(await page.locator("body").innerText()).not.toContain("not-a-uuid");
  });
});

// ── Layout constraints at every required CSS viewport (AC-13) ──
test.describe("Administration layout constraints", () => {
  for (const viewport of VIEWPORTS) {
    test(`member administration fits the ${viewport.label} viewport with 44px targets`, async ({
      page,
    }) => {
      await openMembers(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await page.waitForSelector("tbody#members tr");

      expect(await bodyFitsViewport(page), "body overflows").toBe(true);

      // The primary task — the member list — is on screen and not clipped.
      const table = page.locator("table.ds-stack-table");
      const tableBox = await table.boundingBox();
      expect(tableBox).not.toBeNull();
      expect(tableBox.width).toBeLessThanOrEqual(viewport.width);
      expect(tableBox.width).toBeGreaterThan(0);

      // The header primary stays reachable and large enough.
      const trigger = page.locator("#invite-user-trigger");
      const triggerBox = await trigger.boundingBox();
      expect(triggerBox).not.toBeNull();
      expect(triggerBox.height).toBeGreaterThanOrEqual(44);
      expect(triggerBox.x).toBeGreaterThanOrEqual(0);
      expect(triggerBox.x + triggerBox.width).toBeLessThanOrEqual(
        viewport.width + 1,
      );

      // Every row action meets the target size and stays inside the viewport.
      const actions = page.locator("tbody#members tr [aria-label]");
      const count = await actions.count();
      expect(count).toBeGreaterThan(0);

      for (let i = 0; i < count; i++) {
        const box = await actions.nth(i).boundingBox();
        const label = await actions.nth(i).getAttribute("aria-label");
        expect(box, label).not.toBeNull();
        expect(box.height, label).toBeGreaterThanOrEqual(44);
        expect(box.width, label).toBeGreaterThanOrEqual(44);
        expect(box.x + box.width, label).toBeLessThanOrEqual(
          viewport.width + 1,
        );
      }
    });

    test(`member row actions never overlap at ${viewport.label}`, async ({
      page,
    }) => {
      await openMembers(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await page.waitForSelector("tbody#members tr");

      const overlaps = await page.evaluate(() => {
        const found = [];
        const intersects = (a, b) =>
          a.left < b.right &&
          b.left < a.right &&
          a.top < b.bottom &&
          b.top < a.bottom;

        for (const row of document.querySelectorAll("tbody#members tr")) {
          const boxes = Array.from(
            row.querySelectorAll("[aria-label]"),
          ).map((el) => ({
            label: el.getAttribute("aria-label"),
            rect: el.getBoundingClientRect(),
          }));

          for (let i = 0; i < boxes.length; i++) {
            for (let j = i + 1; j < boxes.length; j++) {
              if (intersects(boxes[i].rect, boxes[j].rect)) {
                found.push([boxes[i].label, boxes[j].label]);
              }
            }
          }
        }
        return found;
      });

      expect(overlaps).toEqual([]);
    });

    test(`the long member email reflows at ${viewport.label}`, async ({
      page,
    }) => {
      await openMembers(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await page.waitForSelector("tbody#members tr");

      const cell = page
        .locator("tbody#members tr")
        .filter({ hasText: MEMBERS.longEmail })
        .locator('td[data-label="Email"]');

      await expect(cell).toBeVisible();
      const box = await cell.boundingBox();
      expect(box).not.toBeNull();
      expect(box.width).toBeLessThanOrEqual(viewport.width);
      expect(await bodyFitsViewport(page)).toBe(true);
    });

    test(`the organization index fits the ${viewport.label} viewport`, async ({
      page,
    }) => {
      await openOrganizations(page);
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await page.waitForSelector("tbody#organizations tr");

      expect(await bodyFitsViewport(page)).toBe(true);

      const trigger = page.locator("#create-organization-trigger");
      const box = await trigger.boundingBox();
      expect(box).not.toBeNull();
      expect(box.height).toBeGreaterThanOrEqual(44);
      expect(box.x + box.width).toBeLessThanOrEqual(viewport.width + 1);
    });
  }

  test("the invite drawer stays inside a 320px viewport", async ({ page }) => {
    await openMembers(page);
    await page.setViewportSize({ width: 320, height: 568 });

    await page.locator("#invite-user-trigger").click();
    await expect(page.locator("#invite-drawer-overlay")).toBeVisible();
    await settleOverlay(page, "#invite-drawer-overlay");

    const panel = await page.locator("#invite-drawer").boundingBox();
    expect(panel.x).toBeGreaterThanOrEqual(0);
    expect(panel).not.toBeNull();
    expect(panel.width).toBeLessThanOrEqual(320);

    const close = await page.locator("#invite-drawer-close").boundingBox();
    expect(close.width).toBeGreaterThanOrEqual(44);
    expect(close.height).toBeGreaterThanOrEqual(44);

    const submit = await page
      .locator('#invite-form button[type="submit"]')
      .boundingBox();
    expect(submit.height).toBeGreaterThanOrEqual(44);
    expect(submit.x + submit.width).toBeLessThanOrEqual(321);
  });

  test("the deactivation dialog stays inside a 320px viewport with 44px actions", async ({
    page,
  }) => {
    await openMembers(page);
    await page.setViewportSize({ width: 320, height: 568 });

    await rowAction(page, `Deactivate ${MEMBERS.active}`).click();
    await expect(page.locator("#deactivate-user-dialog")).toBeVisible();
    await settleOverlay(page, "#deactivate-user-dialog");

    for (const id of [
      "#deactivate-user-dialog-cancel",
      "#deactivate-user-dialog-confirm",
    ]) {
      const box = await page.locator(id).boundingBox();
      expect(box, id).not.toBeNull();
      expect(box.height, id).toBeGreaterThanOrEqual(44);
      expect(box.width, id).toBeGreaterThanOrEqual(44);
      expect(box.x + box.width, id).toBeLessThanOrEqual(321);
    }

    await page.keyboard.press("Escape");
    await expect(page.locator("#deactivate-user-dialog")).not.toBeVisible();
  });
});

// ── Reduced motion (AC-13, C-009) ──
test.describe("Administration reduced motion", () => {
  test.beforeEach(async ({ page }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
  });

  test("the invite drawer animates for zero seconds and remains fully operable", async ({
    page,
  }) => {
    await openMembers(page);

    expect(
      await page.evaluate(
        () => matchMedia("(prefers-reduced-motion: reduce)").matches,
      ),
    ).toBe(true);

    await page.locator("#invite-user-trigger").focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#invite-drawer-overlay")).toBeVisible();
    await expect(page.locator("#invite-email")).toBeFocused();

    const durations = await page.evaluate(() => {
      const overlay = document.getElementById("invite-drawer-overlay");
      const panel = document.getElementById("invite-drawer");
      return {
        overlay: getComputedStyle(overlay).animationDuration,
        backdrop: getComputedStyle(overlay, "::backdrop").animationDuration,
        panel: getComputedStyle(panel).animationDuration,
      };
    });

    expect(durations.overlay).toBe("0s");
    expect(durations.backdrop).toBe("0s");
    expect(durations.panel).toBe("0s");

    await page.keyboard.press("Escape");
    await expect(page.locator("#invite-drawer-overlay")).not.toBeVisible();
    await expect(page.locator("#invite-user-trigger")).toBeFocused();
  });

  test("the deactivation dialog remains operable under reduced motion", async ({
    page,
  }) => {
    await openMembers(page);

    const trigger = rowAction(page, `Deactivate ${MEMBERS.multiRole}`);
    const triggerId = await trigger.getAttribute("id");
    await trigger.focus();
    await page.keyboard.press("Enter");

    await expect(page.locator("#deactivate-user-dialog")).toBeVisible();
    await expect(page.locator("#deactivate-user-dialog-cancel")).toBeFocused();

    await page.keyboard.press("Escape");
    await expect(page.locator("#deactivate-user-dialog")).not.toBeVisible();
    expect(await activeElementId(page)).toBe(triggerId);
  });
});
