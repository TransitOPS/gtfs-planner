/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import FloorplanHook, {
  buildFloorplanSvg,
  closedLabelPosition,
  floorplanViewBox,
} from "../pathway_evolutions_floorplan.js";

// The seeded browser station's own shape: a non-square 100 x 80 image with
// width-normalized coordinates on both axes, one same-level walkway and one
// cross-level elevator whose far endpoint is on another level.
const STOPS = [
  { stop_id: "FP_ENTRANCE", name: "North entrance", type: 2, x: 20, y: 15 },
  { stop_id: "FP_MEZZANINE", name: "Mezzanine hall", type: 0, x: 50, y: 30 },
  { stop_id: "FP_PLATFORM", name: "Platform 1", type: 0, x: 78, y: 55 },
  { stop_id: "FP_STREET", name: "Street landing", type: 2, x: 45, y: 55 },
];

const PATHWAYS = [
  {
    id: "11111111-1111-4111-8111-111111111111",
    pathway_id: "FP/PW WALK",
    label: "Walkway · North entrance ↔ Mezzanine hall",
    closures: 0,
    from: STOPS[0],
    to: STOPS[1],
  },
  {
    id: "22222222-2222-4222-8222-222222222222",
    pathway_id: "FP/PW LIFT",
    label: "Elevator · Mezzanine hall ↔ Platform 1",
    closures: 2,
    from: STOPS[1],
    to: STOPS[2],
  },
  {
    id: "33333333-3333-4333-8333-333333333333",
    pathway_id: "FP/PW CROSS",
    label: "Elevator · Platform 1 ↔ Street landing",
    closures: 0,
    from: STOPS[2],
    to: null,
  },
];

const LIFT_ID = PATHWAYS[1].id;
const WALK_ID = PATHWAYS[0].id;
const CROSS_ID = PATHWAYS[2].id;

function render(markup) {
  const container = document.createElement("div");
  container.innerHTML = markup;
  return container;
}

function groupFor(container, uuid) {
  return container.querySelector(`[data-pathway-uuid="${uuid}"]`);
}

function buildIsland({ selectedId = "", closedIds = [], selectEvent = "select_pathway" } = {}) {
  const island = document.createElement("div");
  island.id = "closure-floorplan";
  // The production island is a LiveView-owned region: the hook renders its
  // children and the server merges only data attributes onto it.
  island.setAttribute("phx-update", "ignore");
  island.setAttribute("phx-hook", "PathwayEvolutionsFloorplan");
  island.dataset.imageUrl = "/uploads/diagrams/plan.png";
  island.dataset.imageAlt = "Floorplan of the test station";
  island.dataset.stops = JSON.stringify(STOPS);
  island.dataset.pathways = JSON.stringify(PATHWAYS);
  island.dataset.selectedId = selectedId;
  island.dataset.closedIds = JSON.stringify(closedIds);
  island.dataset.selectEvent = selectEvent;
  island.dataset.showStopNames = "false";
  island.dataset.noteId = "closure-floorplan-missing";
  island.dataset.listId = "closure-pathway-list";
  island.dataset.toggleId = "locator-toggle";
  island.innerHTML = `
    <div data-floorplan-frame>
      <img data-floorplan-image src="/uploads/diagrams/plan.png" alt="Floorplan of the test station" />
      <svg data-floorplan-svg></svg>
    </div>
    <p data-floorplan-caption></p>
  `;

  const panel = document.createElement("div");
  panel.dataset.floorplanPanel = "";
  panel.append(island);

  const missing = document.createElement("p");
  missing.id = "closure-floorplan-missing";
  missing.hidden = true;

  const list = document.createElement("div");
  list.id = "closure-pathway-list";
  list.classList.add("md:hidden");

  const toggle = document.createElement("div");
  toggle.id = "locator-toggle";

  document.body.append(panel, missing, list, toggle);
  return island;
}

function imageFor(island, { width = 100, height = 80 } = {}) {
  const image = island.querySelector("[data-floorplan-image]");
  Object.defineProperty(image, "naturalWidth", { value: width, configurable: true });
  Object.defineProperty(image, "naturalHeight", { value: height, configurable: true });
  return image;
}

function mountHook(island) {
  const hook = Object.create(FloorplanHook);
  hook.el = island;
  hook.pushEvent = vi.fn();
  hook.mounted();
  return hook;
}

function keydown(target, key) {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
}

describe("floorplanViewBox", () => {
  it("matches the image's width-normalized coordinate space", () => {
    expect(floorplanViewBox(100, 80)).toBe("0 0 100 80");
    expect(floorplanViewBox(100, 100)).toBe("0 0 100 100");
    expect(floorplanViewBox(1060, 936)).toBe("0 0 100 88.302");
  });

  it("refuses dimensions that cannot describe a real image", () => {
    expect(floorplanViewBox(0, 80)).toBeNull();
    expect(floorplanViewBox(-10, 80)).toBeNull();
    expect(floorplanViewBox(100, 0)).toBeNull();
    expect(floorplanViewBox(Number.NaN, 80)).toBeNull();
    expect(floorplanViewBox(100, Number.POSITIVE_INFINITY)).toBeNull();
  });
});

describe("closedLabelPosition", () => {
  it("keeps the Closed word clear of a stop that occupies the first candidate", () => {
    const position = closedLabelPosition(50, 30, [[48, 34, 56, 40]]);

    expect(position).toEqual({ x: 47.8, y: 36.6, anchor: "end" });
  });

  it("falls back to the first candidate when every candidate collides", () => {
    const boxes = [
      [45, 30, 58, 42],
      [40, 25, 60, 45],
      [44, 20, 62, 48],
      [45, 25, 58, 36],
      [42, 25, 55, 40],
      [43, 21, 57, 33],
    ];

    expect(closedLabelPosition(50, 30, boxes)).toEqual({ x: 52.2, y: 36.6, anchor: "start" });
  });
});

describe("buildFloorplanSvg", () => {
  it("draws a same-level pathway as a line between its two stored endpoints", () => {
    const container = render(buildFloorplanSvg({ stops: STOPS, pathways: PATHWAYS }));
    const line = groupFor(container, WALK_ID).querySelector("line.evo-fp-line");

    expect(line.getAttribute("x1")).toBe("20");
    expect(line.getAttribute("y1")).toBe("15");
    expect(line.getAttribute("x2")).toBe("50");
    expect(line.getAttribute("y2")).toBe("30");
    expect(line.getAttribute("vector-effect")).toBe("non-scaling-stroke");
  });

  it("draws a cross-level pathway as a marker at its one plotted endpoint", () => {
    const container = render(buildFloorplanSvg({ stops: STOPS, pathways: PATHWAYS }));
    const marker = groupFor(container, CROSS_ID);

    expect(marker.getAttribute("transform")).toBe("translate(78 55)");
    expect(marker.querySelector(".evo-fp-marker-icon")).not.toBeNull();
    expect(marker.querySelector("line.evo-fp-line")).toBeNull();
  });

  it("exposes labelled buttons with exactly one roving tab stop", () => {
    const container = render(
      buildFloorplanSvg({ stops: STOPS, pathways: PATHWAYS, rovingId: LIFT_ID }),
    );
    const groups = [...container.querySelectorAll("[data-pathway-uuid]")];

    expect(groups).toHaveLength(3);
    expect(groups.map((group) => group.getAttribute("tabindex"))).toEqual(["-1", "0", "-1"]);
    expect(groups.map((group) => group.getAttribute("role"))).toEqual([
      "button",
      "button",
      "button",
    ]);
    expect(groupFor(container, LIFT_ID).getAttribute("aria-label")).toBe(
      "Elevator · Mezzanine hall ↔ Platform 1, FP/PW LIFT",
    );
    expect(container.innerHTML).not.toContain("aria-hidden");
  });

  it("marks the selected pathway with aria-current and the action ink", () => {
    const container = render(
      buildFloorplanSvg({ stops: STOPS, pathways: PATHWAYS, selectedId: LIFT_ID }),
    );

    expect(groupFor(container, LIFT_ID).getAttribute("aria-current")).toBe("true");
    expect(groupFor(container, LIFT_ID).querySelector("line.evo-fp-line").className).toContain(
      "stroke-action",
    );
    expect(groupFor(container, WALK_ID).getAttribute("aria-current")).toBeNull();
  });

  it("draws a closed pathway as a dashed error line, a cross and the word Closed", () => {
    const container = render(
      buildFloorplanSvg({ stops: STOPS, pathways: PATHWAYS, closedIds: ["FP/PW LIFT"] }),
    );
    const group = groupFor(container, LIFT_ID);
    const line = group.querySelector("line.evo-fp-line");

    expect(line.className).toContain("stroke-evo-closed");
    expect(line.getAttribute("stroke-dasharray")).toBe("7 5");
    expect(group.querySelector(".evo-fp-closed-marker")).not.toBeNull();
    expect(group.querySelector(".evo-fp-closed-word").textContent).toBe("Closed");
  });

  it("marks a pathway with saved closures with a dot, never with the closed ink", () => {
    const container = render(buildFloorplanSvg({ stops: STOPS, pathways: PATHWAYS }));
    const lift = groupFor(container, LIFT_ID);

    expect(lift.querySelector(".evo-fp-dot")).not.toBeNull();
    expect(lift.querySelector("line.evo-fp-line").className).not.toContain("stroke-evo-closed");
    expect(groupFor(container, WALK_ID).querySelector(".evo-fp-dot")).toBeNull();
  });

  it("draws a closed pathway above an open pathway that shares its line", () => {
    const overlapping = [
      PATHWAYS[1],
      { ...PATHWAYS[1], id: "55555555-5555-4555-8555-555555555555", pathway_id: "FP/PW LIFT 2" },
    ];
    const container = render(
      buildFloorplanSvg({
        stops: STOPS,
        pathways: overlapping,
        closedIds: ["FP/PW LIFT 2"],
      }),
    );
    const groups = [...container.querySelectorAll("[data-pathway-uuid]")];

    expect(groups).toHaveLength(2);
    expect(groups[0].dataset.pathwayId).toBe("FP/PW LIFT");
    expect(groups[1].dataset.pathwayId).toBe("FP/PW LIFT 2");
    expect(groups[1].querySelector("line.evo-fp-line").className).toContain("stroke-evo-closed");
  });

  it("draws entrances as squares and other stops as dots, hiding a marker's own node", () => {
    const container = render(buildFloorplanSvg({ stops: STOPS, pathways: PATHWAYS }));
    const entrance = container.querySelector(".evo-fp-entrance");
    const nodes = [...container.querySelectorAll(".evo-fp-node")];

    expect(entrance.getAttribute("x")).toBe("18.5");
    expect(entrance.getAttribute("y")).toBe("13.5");
    // FP_PLATFORM is the cross-level marker's own stop, so it has no node.
    expect(nodes).toHaveLength(1);
    expect(nodes[0].parentElement.textContent).not.toContain("Platform 1");
  });

  it("adds entrance names only when the surface asks for them", () => {
    const withoutNames = render(buildFloorplanSvg({ stops: STOPS, pathways: PATHWAYS }));
    const withNames = render(
      buildFloorplanSvg({ stops: STOPS, pathways: PATHWAYS, showStopNames: true }),
    );

    expect(withoutNames.querySelectorAll(".evo-fp-stop-name")).toHaveLength(0);
    expect(withNames.querySelector(".evo-fp-stop-name").textContent).toBe("North entrance");
  });

  it("escapes a natural ID and label before they reach the markup", () => {
    const markup = buildFloorplanSvg({
      stops: [],
      pathways: [
        {
          id: "44444444-4444-4444-8444-444444444444",
          pathway_id: 'A"/<script>',
          label: 'Walkway · A ↔ B "quoted"',
          closures: 0,
          from: { stop_id: "A", name: "A", type: 0, x: 10, y: 10 },
          to: { stop_id: "B", name: "B", type: 0, x: 20, y: 20 },
        },
      ],
    });

    expect(markup).not.toContain("<script>");
    expect(markup).toContain("&quot;");
  });
});

describe("PathwayEvolutionsFloorplan", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
  });

  afterEach(() => {
    vi.restoreAllMocks();
    document.body.innerHTML = "";
  });

  it("sizes the viewBox from the image's real pixels and draws the stored coordinates", () => {
    const island = buildIsland({ selectedId: LIFT_ID });
    imageFor(island);

    mountHook(island);

    const svg = island.querySelector("[data-floorplan-svg]");
    expect(svg.getAttribute("viewBox")).toBe("0 0 100 80");
    expect(svg.querySelectorAll("[data-pathway-uuid]")).toHaveLength(3);
    expect(svg.querySelector(`[data-pathway-uuid="${WALK_ID}"]`)).not.toBeNull();
  });

  it("moves the one roving tab stop with the arrow, Home and End keys", () => {
    const island = buildIsland({ selectedId: LIFT_ID });
    imageFor(island);
    mountHook(island);

    const svg = () => island.querySelector("[data-floorplan-svg]");
    const group = (uuid) => svg().querySelector(`[data-pathway-uuid="${uuid}"]`);

    // The declared order is the server's list order: walkway, lift, cross.
    expect(group(LIFT_ID).getAttribute("tabindex")).toBe("0");

    keydown(group(LIFT_ID), "ArrowRight");
    expect(group(CROSS_ID).getAttribute("tabindex")).toBe("0");
    expect(svg().querySelectorAll('[tabindex="0"]')).toHaveLength(1);

    keydown(group(CROSS_ID), "ArrowRight");
    expect(group(WALK_ID).getAttribute("tabindex")).toBe("0");

    keydown(group(WALK_ID), "ArrowLeft");
    expect(group(CROSS_ID).getAttribute("tabindex")).toBe("0");

    keydown(group(CROSS_ID), "Home");
    expect(group(WALK_ID).getAttribute("tabindex")).toBe("0");

    keydown(group(WALK_ID), "End");
    expect(group(CROSS_ID).getAttribute("tabindex")).toBe("0");
  });

  it("asks the server to select the focused pathway on Enter and Space", () => {
    const island = buildIsland();
    imageFor(island);
    const hook = mountHook(island);

    const svg = island.querySelector("[data-floorplan-svg]");
    const lift = svg.querySelector(`[data-pathway-uuid="${LIFT_ID}"]`);

    keydown(lift, "Enter");
    expect(hook.pushEvent).toHaveBeenCalledWith("select_pathway", { id: LIFT_ID });

    keydown(svg.querySelector(`[data-pathway-uuid="${CROSS_ID}"]`), " ");
    expect(hook.pushEvent).toHaveBeenLastCalledWith("select_pathway", { id: CROSS_ID });
    expect(hook.pushEvent).toHaveBeenCalledTimes(2);
  });

  it("keeps the reader's place when a keyboard selection opens the editor", async () => {
    const island = buildIsland();
    imageFor(island);
    const hook = mountHook(island);

    const svg = island.querySelector("[data-floorplan-svg]");
    const walk = svg.querySelector(`[data-pathway-uuid="${WALK_ID}"]`);
    const calendar = document.createElement("select");
    calendar.id = "closure-calendar";
    document.body.append(calendar);

    walk.focus();
    keydown(walk, "Enter");

    // The selection's own update renders first; the server's focus move into
    // the form is dispatched after it and re-asserts itself on the next frame,
    // exactly as LiveView orders a patch and its pushed events.
    island.dataset.selectedId = WALK_ID;
    hook.updated();
    calendar.focus();

    await Promise.resolve();

    if (typeof requestAnimationFrame === "function") {
      await new Promise((resolve) => requestAnimationFrame(resolve));
    }

    expect(document.activeElement.getAttribute("data-pathway-uuid")).toBe(WALK_ID);
  });

  it("redraws the selection and the closed set from the island's data attributes", () => {
    const island = buildIsland();
    imageFor(island);
    const hook = mountHook(island);

    island.dataset.selectedId = LIFT_ID;
    island.dataset.closedIds = JSON.stringify(["FP/PW LIFT"]);
    hook.updated();

    const svg = island.querySelector("[data-floorplan-svg]");
    const lift = svg.querySelector(`[data-pathway-uuid="${LIFT_ID}"]`);

    expect(lift.getAttribute("aria-current")).toBe("true");
    expect(lift.querySelector("line.evo-fp-line").getAttribute("stroke-dasharray")).toBe("7 5");
    expect(lift.querySelector(".evo-fp-closed-word").textContent).toBe("Closed");
    // The stored coordinates are the server's; an update cannot move them.
    expect(lift.querySelector("line.evo-fp-line").getAttribute("x1")).toBe("50");
  });

  it("keeps focus on the same pathway when an update redraws the overlay", () => {
    const island = buildIsland();
    imageFor(island);
    const hook = mountHook(island);

    const svg = island.querySelector("[data-floorplan-svg]");
    const walk = svg.querySelector(`[data-pathway-uuid="${WALK_ID}"]`);
    walk.focus();

    island.dataset.selectedId = WALK_ID;
    hook.updated();

    const focused = document.activeElement;
    expect(focused.getAttribute("data-pathway-uuid")).toBe(WALK_ID);
    expect(focused.getAttribute("tabindex")).toBe("0");
  });

  it("falls back to the list with a visible note when the image fails", () => {
    const island = buildIsland();
    const image = imageFor(island);
    const hook = mountHook(island);

    Object.defineProperty(image, "naturalWidth", { value: 0, configurable: true });
    image.dispatchEvent(new Event("error"));
    hook.updated();

    expect(island.closest("[data-floorplan-panel]").hidden).toBe(true);
    expect(document.getElementById("closure-floorplan-missing").hidden).toBe(false);
    expect(document.getElementById("closure-pathway-list").classList.contains("md:hidden")).toBe(
      false,
    );
    expect(document.getElementById("locator-toggle").hidden).toBe(true);
  });

  it("highlights the existing causes instead of writing when the island is the preview", () => {
    document.body.innerHTML = `
      <div id="preview-causes">
        <ul>
          <li id="preview-cause-1" data-cause-pathway="FP/PW LIFT"></li>
          <li id="preview-cause-2" data-cause-pathway="FP/PW WALK"></li>
        </ul>
      </div>
    `;

    const island = buildIsland({ selectEvent: "" });
    island.dataset.showStopNames = "true";
    imageFor(island);
    const hook = mountHook(island);

    const svg = island.querySelector("[data-floorplan-svg]");
    const lift = svg.querySelector(`[data-pathway-uuid="${LIFT_ID}"]`);

    keydown(lift, "Enter");

    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(
      svg.querySelector(`[data-pathway-uuid="${LIFT_ID}"]`).getAttribute("data-highlighted"),
    ).toBe("true");
    expect(document.getElementById("preview-cause-1").className).toContain("evo-cause-highlight");
    expect(document.getElementById("preview-cause-2").className).not.toContain(
      "evo-cause-highlight",
    );

    keydown(svg.querySelector(`[data-pathway-uuid="${LIFT_ID}"]`), "Enter");

    expect(document.getElementById("preview-cause-1").className).not.toContain(
      "evo-cause-highlight",
    );
  });

  it("names a single saved closure in the singular", () => {
    const island = buildIsland({ selectedId: LIFT_ID });
    island.dataset.pathways = JSON.stringify([{ ...PATHWAYS[1], closures: 1 }]);
    imageFor(island);
    mountHook(island);

    expect(island.querySelector("[data-floorplan-caption]").textContent).toBe(
      "Selected: Elevator · Mezzanine hall ↔ Platform 1 FP/PW LIFT · 1 closure",
    );
  });

  it("writes the caption from the hovered or roving pathway", () => {
    const island = buildIsland({ selectedId: LIFT_ID });
    imageFor(island);
    mountHook(island);

    const caption = island.querySelector("[data-floorplan-caption]");
    expect(caption.textContent).toBe(
      "Selected: Elevator · Mezzanine hall ↔ Platform 1 FP/PW LIFT · 2 closures",
    );

    const walk = island.querySelector(`[data-pathway-uuid="${WALK_ID}"]`);
    walk.dispatchEvent(new Event("pointerover", { bubbles: true }));
    expect(caption.textContent).toBe("Walkway · North entrance ↔ Mezzanine hall FP/PW WALK");

    island.querySelector("[data-floorplan-svg]").dispatchEvent(new Event("pointerleave"));
    expect(caption.textContent).toContain("Selected: Elevator");
  });
  it("refuses to move geometry: no drag, pan or zoom listener is installed", () => {
    const island = buildIsland();
    imageFor(island);
    const hook = mountHook(island);
    const svg = island.querySelector("[data-floorplan-svg]");

    expect(svg.getAttribute("phx-hook")).toBeNull();
    expect(island.getAttribute("phx-update")).toBe("ignore");

    const dragEvents = ["dragstart", "mousedown", "pointerdown", "wheel"];
    for (const name of dragEvents) {
      expect(hook[`_${name}`]).toBeUndefined();
    }

    // A selection leaves every stored coordinate exactly as the server sent it:
    // the redraw never moves a line the first render drew.
    const lift = () => svg.querySelector(`[data-pathway-uuid="${LIFT_ID}"]`);
    const drawn = lift().querySelector("line.evo-fp-line").getAttribute("y2");

    keydown(svg.querySelector(`[data-pathway-uuid="${WALK_ID}"]`), "Enter");

    expect(lift().querySelector("line.evo-fp-line").getAttribute("y2")).toBe(drawn);
  });
});
