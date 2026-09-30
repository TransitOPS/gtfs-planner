import { test, expect } from "@playwright/test";
import {
  loginAndGoToDiagram,
  selectDiagramMode,
} from "./station_diagram_helpers";

const VIEWPORTS = [
  { width: 1440, height: 900 },
  { width: 900, height: 700 },
];
const ZOOM_TARGETS = [100, 250];

// Tolerance for sub-pixel rounding in getBoundingClientRect.
const EPSILON = 0.5;

async function openDiagram(page, viewport) {
  await page.setViewportSize(viewport);
  await loginAndGoToDiagram(page);
  // The overlay keeps its 100x100 placeholder viewBox until the plan loads.
  await page.waitForFunction(() => {
    const overlay = document.querySelector("#diagram-overlay");
    const label = overlay?.querySelector("[data-stop-label]");
    return (
      overlay?.getAttribute("viewBox") !== "0 0 100 100" &&
      Boolean(label?.getAttribute("font-size"))
    );
  });
}

async function zoomTo(page, percent) {
  const zoomLabel = page.locator("[data-zoom-label]");
  const current = async () => parseInt(await zoomLabel.textContent(), 10);

  for (let clicks = 0; (await current()) < percent && clicks < 10; clicks += 1) {
    await page.locator('[data-zoom="in"]').click();
  }

  expect(await current()).toBeGreaterThanOrEqual(percent);
}

// On-screen geometry of the overlay's points, in CSS pixels.
async function measureOverlay(page) {
  return page.evaluate(() => {
    const overlay = document.querySelector("#diagram-overlay");
    const pxPerUnit = overlay.getScreenCTM().a;
    const size = (element) => {
      const rect = element.getBoundingClientRect();
      return { width: rect.width, height: rect.height };
    };

    const labels = [...overlay.querySelectorAll("[data-stop-label]")]
      .filter((label) => label.getAttribute("display") !== "none")
      .map((label) => {
        const rect = label.getBoundingClientRect();
        return {
          text: label.textContent.trim().replace(/\s+/g, " "),
          fontPx: parseFloat(label.getAttribute("font-size")) * pxPerUnit,
          left: rect.left,
          top: rect.top,
          right: rect.right,
          bottom: rect.bottom,
          height: rect.height,
        };
      });

    return {
      labels,
      markers: [...overlay.querySelectorAll("[data-stop-marker]")].map((marker) => ({
        type: marker.getAttribute("data-location-type"),
        ...size(marker),
      })),
      hitTargets: [...overlay.querySelectorAll("[data-stop-hit-target]")].map(size),
    };
  });
}

function overlapping(labels) {
  const pairs = [];

  labels.forEach((a, index) => {
    labels.slice(index + 1).forEach((b) => {
      const overlaps =
        a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

      if (overlaps) pairs.push([a.text, b.text]);
    });
  });

  return pairs;
}

async function addPoint(page, { name, x, y }) {
  await selectDiagramMode(page, "add");
  await page.locator("#keyboard-create-stop").click();
  await expect(page.locator("#child-stop-drawer-overlay")).toHaveAttribute(
    "data-open",
    "true",
  );
  await page.fill("#child-stop-form input[name='stop_name']", name);
  await page.fill("#child-stop-form input[name='x']", `${x}`);
  await page.fill("#child-stop-form input[name='y']", `${y}`);
  await page.locator("#child-stop-form button[type='submit']").click();
  await expect(page.locator("#child-stop-drawer-overlay")).not.toHaveAttribute(
    "data-open",
    "true",
  );
  await selectDiagramMode(page, "view");
  await expect(
    page.locator(`#diagram-overlay g[data-stop-id][data-label-text="${name}"]`),
  ).toHaveCount(1);
}

async function deletePoint(page, name) {
  await page
    .locator("button[phx-click='edit_child_stop']", { hasText: name })
    .first()
    .click();
  await page.locator("#delete-child-stop-button").click();
  await page.locator("#station-diagram-confirmation-confirm").click();
  await expect(
    page.locator(`#diagram-overlay g[data-stop-id][data-label-text="${name}"]`),
  ).toHaveCount(0);
}

test.describe("Station diagram legibility", () => {
  for (const viewport of VIEWPORTS) {
    const size = `${viewport.width}x${viewport.height}`;

    test(`draws point names at 11px or larger at 100% and 250% zoom in a ${size} window`, async ({
      page,
    }) => {
      await openDiagram(page, viewport);

      for (const percent of ZOOM_TARGETS) {
        await zoomTo(page, percent);

        const { labels } = await measureOverlay(page);
        expect(labels.length, `visible labels at ${percent}%`).toBeGreaterThan(0);

        for (const label of labels) {
          expect(label.fontPx, `${label.text} font size at ${percent}%`).toBeGreaterThanOrEqual(
            11 - EPSILON,
          );
          expect(label.height, `${label.text} box height at ${percent}%`).toBeGreaterThanOrEqual(
            11 - EPSILON,
          );
        }
      }
    });

    test(`draws markers at 12px or larger and hit targets at 24px or larger at 100% and 250% zoom in a ${size} window`, async ({
      page,
    }) => {
      await openDiagram(page, viewport);

      for (const percent of ZOOM_TARGETS) {
        await zoomTo(page, percent);

        const { markers, hitTargets } = await measureOverlay(page);
        expect(markers.length).toBeGreaterThan(0);
        expect(hitTargets.length).toBeGreaterThan(0);

        for (const marker of markers) {
          expect(marker.width, `type ${marker.type} marker width at ${percent}%`).toBeGreaterThanOrEqual(
            12 - EPSILON,
          );
          expect(marker.height, `type ${marker.type} marker height at ${percent}%`).toBeGreaterThanOrEqual(
            12 - EPSILON,
          );
        }

        for (const hitTarget of hitTargets) {
          expect(hitTarget.width, `hit target width at ${percent}%`).toBeGreaterThanOrEqual(
            24 - EPSILON,
          );
          expect(hitTarget.height, `hit target height at ${percent}%`).toBeGreaterThanOrEqual(
            24 - EPSILON,
          );
        }
      }
    });
  }

  test("paints an entrance's name and hit target like any other point's", async ({
    page,
  }) => {
    await openDiagram(page, VIEWPORTS[0]);

    const paint = await page.evaluate(() => {
      const fill = (selector) =>
        getComputedStyle(document.querySelector(selector)).fill;
      const group = (type) =>
        `#diagram-overlay g[data-stop-id]:has([data-stop-marker][data-location-type="${type}"])`;

      return {
        platformLabel: fill(`${group(0)} [data-stop-label]`),
        entranceLabel: fill(`${group(2)} [data-stop-label]`),
        entranceHitTarget: fill(`${group(2)} [data-stop-hit-target]`),
      };
    });

    expect(paint.entranceLabel).toBe(paint.platformLabel);
    expect(paint.entranceHitTarget).toBe("rgba(0, 0, 0, 0)");
  });

  test("keeps the names of two nearby points from overlapping", async ({ page }) => {
    const nearby = [
      { name: "Legibility Point North", x: 12, y: 12 },
      { name: "Legibility Point South", x: 13, y: 13.5 },
    ];

    await openDiagram(page, VIEWPORTS[0]);

    try {
      for (const point of nearby) await addPoint(page, point);

      for (const percent of ZOOM_TARGETS) {
        await zoomTo(page, percent);

        const { labels } = await measureOverlay(page);
        expect(overlapping(labels), `overlapping labels at ${percent}%`).toEqual([]);
        // A crowded name may hide, but not both.
        expect(
          labels.filter((label) => label.text.startsWith("Legibility Point")).length,
          `visible nearby labels at ${percent}%`,
        ).toBeGreaterThan(0);
      }
    } finally {
      // The seeded database is shared with later specs; leave it as found.
      await page.locator('[aria-label="Reset view"]').click();
      for (const { name } of nearby) {
        if (await page.locator(`g[data-label-text="${name}"]`).count()) {
          await deletePoint(page, name);
        }
      }
    }
  });

  test("acts on the point nearest the pointer where two hit targets overlap", async ({
    page,
  }) => {
    const north = { name: "Overlap Point North", x: 12, y: 12 };
    const south = { name: "Overlap Point South", x: 13, y: 13.5 };
    const group = (name) => `#diagram-overlay g[data-stop-id][data-label-text="${name}"]`;

    await openDiagram(page, VIEWPORTS[0]);

    try {
      // South is added last, so its hit target is painted over North's.
      await addPoint(page, north);
      await addPoint(page, south);
      await page.locator('[aria-label="Reset view"]').click();

      const centers = await page.evaluate(
        ([northGroup, southGroup]) => {
          const center = (selector) => {
            const rect = document
              .querySelector(`${selector} [data-stop-hit-target]`)
              .getBoundingClientRect();
            return {
              x: rect.left + rect.width / 2,
              y: rect.top + rect.height / 2,
              half: rect.width / 2,
            };
          };
          return { north: center(northGroup), south: center(southGroup) };
        },
        [group(north.name), group(south.name)],
      );

      // A quarter of the way from North to South: inside both 24px targets,
      // nearer North.
      const pointer = {
        x: centers.north.x + (centers.south.x - centers.north.x) * 0.25,
        y: centers.north.y + (centers.south.y - centers.north.y) * 0.25,
      };
      for (const { x, y, half } of [centers.north, centers.south]) {
        expect(Math.abs(pointer.x - x)).toBeLessThan(half);
        expect(Math.abs(pointer.y - y)).toBeLessThan(half);
      }
      const paintedOnTop = await page.evaluate(
        ({ x, y }) => document.elementFromPoint(x, y).closest("g[data-stop-id]")?.dataset.labelText,
        pointer,
      );
      expect(paintedOnTop).toBe(south.name);

      await page.mouse.click(pointer.x, pointer.y);

      await expect(page.locator(group(north.name))).toHaveAttribute(
        "data-stop-state",
        "selected",
      );
      await expect(page.locator(group(south.name))).toHaveAttribute(
        "data-stop-state",
        "active",
      );
    } finally {
      // Selecting a point opened its edit drawer.
      await page.keyboard.press("Escape");
      await expect(page.locator("#child-stop-drawer-overlay")).not.toHaveAttribute(
        "data-open",
        "true",
      );
      // The seeded database is shared with later specs; leave it as found.
      await page.locator('[aria-label="Reset view"]').click();
      for (const { name } of [north, south]) {
        if (await page.locator(`g[data-label-text="${name}"]`).count()) {
          await deletePoint(page, name);
        }
      }
    }
  });
});
