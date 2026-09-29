/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import RouteDetailsEditor from "../route_details_editor";

// The markup `RouteFormComponents.color_fields/1` renders for one prefix,
// reduced to the ids and parts the hook reads, wrapped in the recovery form
// both route surfaces mount (`data-recovery` is step 26's AC-23 contract).
function colorPartsMarkup(prefix) {
  return `
    <div
      id="${prefix}-color-fields"
      data-prefix="${prefix}"
    >
      <input type="color" id="${prefix}-color-picker" value="#FFFFFF" />
      <input type="radio" name="text_mode" id="${prefix}-text-mode-automatic" value="automatic" checked />
      <input type="radio" name="text_mode" id="${prefix}-text-mode-custom" value="custom" />
      <div id="${prefix}-text-wrap" class="hidden">
        <input type="text" id="${prefix}-text" name="route[route_text_color]" value="" />
      </div>
      <input type="text" id="${prefix}-color" name="route[route_color]" value="" />
      <div id="${prefix}-contrast">
        <span id="${prefix}-contrast-badge"><span>W1</span></span>
        <span id="${prefix}-contrast-icon-ok" class="hidden"></span>
        <span id="${prefix}-contrast-icon-low" class="hidden"></span>
        <span id="${prefix}-contrast-verdict" class="hidden"><span id="${prefix}-contrast-verdict-text"></span></span>
        <span id="${prefix}-contrast-ratio"></span>
        <span id="${prefix}-contrast-advice" class="hidden"><button type="button" id="${prefix}-use-automatic">Use automatic text color</button></span>
      </div>
    </div>
  `;
}

function recoveryFormMarkup({ prefix, attempt, recoveryEvent }) {
  return `
    <form
      id="${prefix}-form"
      data-recovery="true"
      ${recoveryEvent ? `data-recovery-event="${recoveryEvent}"` : ""}
    >
      ${attempt ? `<input type="hidden" name="_attempt" value="${attempt}" />` : ""}
      <p id="${prefix}-recovery" role="status" hidden></p>
      ${colorPartsMarkup(prefix)}
      <input type="text" id="${prefix}-short" name="route[route_short_name]" value="W1" />
      <button type="button" id="${prefix}-discard">Discard</button>
      <button type="submit" id="${prefix}-submit">Save</button>
    </form>
  `;
}

function mountHook({
  prefix = "new-route",
  attempt,
  recoveryEvent,
  inRecoveryForm = true,
} = {}) {
  const host = document.createElement("div");
  host.innerHTML = inRecoveryForm
    ? recoveryFormMarkup({ prefix, attempt, recoveryEvent })
    : `<form id="${prefix}-form">${colorPartsMarkup(prefix)}<button type="submit" id="${prefix}-submit">Save</button></form>`;
  document.body.appendChild(host);

  const el = host.querySelector(`[id="${prefix}-color-fields"]`);
  if (!inRecoveryForm) {
    el.setAttribute("data-prefix", prefix);
  }

  const hook = Object.create(RouteDetailsEditor);
  hook.el = el;
  hook.pushEvent = vi.fn();
  hook.handleEvent = vi.fn();
  hook.mounted();
  return hook;
}

function recoveryHandler(hook) {
  const call = hook.handleEvent.mock.calls.find(
    ([name]) => name === "route_recovery",
  );
  if (!call) throw new Error("the hook never subscribed to route_recovery");
  return call[1];
}

describe("RouteDetailsEditor local color preview", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
  });

  afterEach(() => {
    document.body.innerHTML = "";
  });

  it("the verdict label follows the recomputed ratio as the operator types", () => {
    mountHook({ prefix: "new-route" });
    const verdict = document.getElementById("new-route-contrast-verdict-text");

    document.getElementById("new-route-color").value = "5BC5F2";
    document.getElementById("new-route-text-mode-custom").checked = true;
    const text = document.getElementById("new-route-text");

    text.value = "FFFFFF";
    text.dispatchEvent(new Event("input", { bubbles: true }));
    expect(verdict.textContent).toBe("Hard to read");
    expect(
      document.getElementById("new-route-contrast-ratio").textContent,
    ).toBe("2.0:1 contrast, below 4.5:1");

    text.value = "000000";
    text.dispatchEvent(new Event("input", { bubbles: true }));
    expect(verdict.textContent).toBe("Easy to read");
  });

  it("Use automatic text color announces the mode change so the server draft follows", () => {
    mountHook({ prefix: "new-route" });
    const automatic = document.getElementById("new-route-text-mode-automatic");
    const heard = vi.fn();
    document
      .getElementById("new-route-form")
      .addEventListener("input", (event) => heard(event.target.id));
    document.getElementById("new-route-text-mode-custom").checked = true;

    document.getElementById("new-route-use-automatic").click();

    expect(automatic.checked).toBe(true);
    expect(heard).toHaveBeenCalledWith("new-route-text-mode-automatic");
  });
});

describe("RouteDetailsEditor connectivity recovery", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
  });

  afterEach(() => {
    document.body.innerHTML = "";
  });

  it("a dropped connection preserves the draft, announces it and blocks the commit", () => {
    const hook = mountHook({
      prefix: "new-route",
      attempt: "signed-attempt-token",
    });
    const draft = document.getElementById("new-route-short");
    draft.value = "the operator typed this";
    draft.focus();

    hook.disconnected();

    const submit = document.getElementById("new-route-submit");
    expect(submit.disabled).toBe(true);
    expect(submit.dataset.recoveryProtected).toBe("true");
    expect(draft.value).toBe("the operator typed this");
    expect(document.activeElement).toBe(draft);

    const region = document.getElementById("new-route-recovery");
    expect(region.hidden).toBe(false);
    expect(region.textContent).toContain("Connection lost");
    expect(region.textContent).toContain("preserved");
  });

  it("reconnecting puts back the entries a rejoin render reset, without touching later ones", () => {
    const hook = mountHook({
      prefix: "new-route",
      attempt: "signed-attempt-token",
    });
    const short = document.getElementById("new-route-short");
    short.value = "R9";
    hook.disconnected();

    // The new server process renders the form empty, and a second failed
    // rejoin must not replace the entries kept from the first drop.
    short.value = "";
    hook.disconnected();
    hook.reconnected();

    expect(short.value).toBe("R9");

    short.value = "R10";
    hook.reconnected();
    expect(short.value).toBe("R10");
  });

  it("reconnecting asks the server and keeps the commit blocked until it answers", () => {
    const hook = mountHook({
      prefix: "new-route",
      attempt: "signed-attempt-token",
    });
    hook.disconnected();

    hook.reconnected();

    expect(hook.pushEvent).toHaveBeenCalledWith("recover_new_route", {
      _attempt: "signed-attempt-token",
    });
    expect(document.getElementById("new-route-submit").disabled).toBe(true);
  });

  it("the server's retryable answer re-enables only the controls the hook blocked", () => {
    const hook = mountHook({
      prefix: "new-route",
      attempt: "signed-attempt-token",
    });
    hook.disconnected();
    // A save that is pending for another reason: disabled without the hook's
    // marker, so recovery must leave it alone (never blindly re-enable).
    const inFlight = document.getElementById("new-route-discard");
    inFlight.disabled = true;

    hook.reconnected();
    recoveryHandler(hook)({
      state: "retryable",
      message:
        "Connection restored. Your entries are preserved — you can save again.",
    });

    const submit = document.getElementById("new-route-submit");
    expect(submit.disabled).toBe(false);
    expect(submit.dataset.recoveryProtected).toBeUndefined();
    expect(inFlight.disabled).toBe(true);
    expect(document.getElementById("new-route-recovery").textContent).toContain(
      "Connection restored",
    );
  });

  it("a blocked recovery keeps the commit disabled and announces the server's message", () => {
    const hook = mountHook({
      prefix: "new-route",
      attempt: "signed-attempt-token",
    });
    hook.disconnected();

    hook.reconnected();
    recoveryHandler(hook)({
      state: "blocked",
      message:
        "This create attempt is no longer valid, so nothing was created.",
    });

    expect(document.getElementById("new-route-submit").disabled).toBe(true);
    const region = document.getElementById("new-route-recovery");
    expect(region.hidden).toBe(false);
    expect(region.textContent).toBe(
      "This create attempt is no longer valid, so nothing was created.",
    );
  });

  it("the details form asks its own recovery event and carries no attempt", () => {
    const hook = mountHook({
      prefix: "route-details",
      recoveryEvent: "recover_route_details",
    });
    hook.disconnected();
    hook.reconnected();

    expect(hook.pushEvent).toHaveBeenCalledWith("recover_route_details", {
      _attempt: "",
    });
    expect(document.getElementById("route-save")?.disabled).toBeUndefined();
    expect(document.getElementById("route-details-submit").disabled).toBe(true);
  });

  it("a form without data-recovery keeps no recovery behavior", () => {
    const hook = mountHook({ prefix: "new-route", inRecoveryForm: false });
    const submit = document.getElementById("new-route-submit");

    hook.disconnected();
    expect(submit.disabled).toBe(false);

    hook.reconnected();
    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(submit.disabled).toBe(false);
  });
});
