/* @vitest-environment jsdom */
import { afterEach, describe, expect, it, vi } from "vitest";
import DiagramCandidateProbe from "../diagram_candidate_probe_hook.js";

function hook() {
  const instance = Object.create(DiagramCandidateProbe);
  instance.el = document.createElement("div");
  instance.pushEvent = vi.fn();
  instance.handleEvent = vi.fn((name, callback) => {
    instance.callbackName = name;
    instance.callback = callback;
  });
  instance.mounted();
  return instance;
}

describe("DiagramCandidateProbe", () => {
  afterEach(() => vi.restoreAllMocks());

  it("reports readiness using the candidate identity supplied by the server", () => {
    let image;
    vi.stubGlobal("Image", class {
      constructor() { image = this; }
    });
    const instance = hook();

    expect(instance.callbackName).toBe("probe_diagram_candidate");
    instance.callback({ candidate_ref: "candidate-1", url: "/uploads/candidate.png" });
    image.onload();

    expect(instance.pushEvent).toHaveBeenCalledWith("diagram_candidate_probe_result", {
      candidate_ref: "candidate-1", result: "ready"
    });
  });

  it("ignores an obsolete probe callback after a later candidate starts", () => {
    const images = [];
    vi.stubGlobal("Image", class {
      constructor() { images.push(this); }
    });
    const instance = hook();

    instance.callback({ candidate_ref: "old", url: "/old.png" });
    instance.callback({ candidate_ref: "new", url: "/new.png" });
    images[0].onerror();
    images[1].onload();

    expect(instance.pushEvent).toHaveBeenCalledTimes(1);
    expect(instance.pushEvent).toHaveBeenCalledWith("diagram_candidate_probe_result", {
      candidate_ref: "new", result: "ready"
    });
  });

  it("does not report after the hook is destroyed", () => {
    let image;
    vi.stubGlobal("Image", class {
      constructor() { image = this; }
    });
    const instance = hook();

    instance.callback({ candidate_ref: "candidate-1", url: "/candidate.png" });
    instance.destroyed();
    image.onload();

    expect(instance.pushEvent).not.toHaveBeenCalled();
  });
});
