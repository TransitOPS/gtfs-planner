/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import FormErrorFocus from "../form_error_focus_hook.js";

const FOCUS_EVENT = "focus_form_error";
const SCOPED_TARGET_EVENT = "focus_scoped_target";

const LOGIN_FORM_HTML = `
  <div id="login-recovery" tabindex="-1">Check your email and password, then try again.</div>
  <form id="login_form">
    <input id="login-email" type="email" aria-invalid="true" />
    <input id="login-password" type="password" aria-invalid="true" />
    <button id="login-submit" type="submit">Log in</button>
  </form>
`;

const VALID_LOGIN_FORM_HTML = `
  <div id="login-recovery" tabindex="-1">Check your email and password, then try again.</div>
  <form id="login_form">
    <input id="login-email" type="email" />
    <input id="login-password" type="password" />
    <button id="login-submit" type="submit">Log in</button>
  </form>
`;

function buildRoot({ dataset = {}, innerHTML = LOGIN_FORM_HTML } = {}) {
  const root = document.createElement("div");
  root.id = "login-page";
  Object.entries(dataset).forEach(([key, value]) => {
    root.dataset[key] = value;
  });
  root.innerHTML = innerHTML;
  document.body.appendChild(root);
  return root;
}

function makeHook(root) {
  const hook = Object.create(FormErrorFocus);
  hook.el = root;
  const registrations = [];
  hook.handleEvent = vi.fn((event, callback) => {
    registrations.push({ event, callback });
  });
  return { hook, registrations };
}

function focusRegistrations(registrations) {
  return registrations.filter((entry) => entry.event === FOCUS_EVENT);
}

function pushServerEvent(registrations, payload) {
  focusRegistrations(registrations).forEach((entry) => entry.callback(payload));
}

function scopedTargetRegistrations(registrations) {
  return registrations.filter((entry) => entry.event === SCOPED_TARGET_EVENT);
}

function pushScopedTargetEvent(registrations, payload) {
  scopedTargetRegistrations(registrations).forEach((entry) =>
    entry.callback(payload),
  );
}

function focusSpy(root, selector) {
  return vi.spyOn(root.querySelector(selector), "focus");
}

describe("FormErrorFocus", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
  });

  afterEach(() => {
    vi.restoreAllMocks();
    document.body.innerHTML = "";
  });

  // =========================================================================
  // Server event registration (INV-11: one handler, one attempt per event)
  // =========================================================================
  describe("server event registration", () => {
    it("registers exactly one focus_form_error handler from mounted", () => {
      const root = buildRoot();
      const { hook, registrations } = makeHook(root);

      hook.mounted();

      expect(hook.handleEvent).toHaveBeenCalledWith(
        FOCUS_EVENT,
        expect.any(Function),
      );
      expect(focusRegistrations(registrations)).toHaveLength(1);
    });

    it("registers exactly one focus_scoped_target handler from mounted", () => {
      const root = buildRoot();
      const { hook, registrations } = makeHook(root);

      hook.mounted();

      expect(hook.handleEvent).toHaveBeenCalledWith(
        SCOPED_TARGET_EVENT,
        expect.any(Function),
      );
      expect(scopedTargetRegistrations(registrations)).toHaveLength(1);
    });

    it("performs one focus attempt per repeated server event without stacking listeners", () => {
      const root = buildRoot();
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const emailSpy = focusSpy(root, "#login-email");

      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });
      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });
      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });

      expect(emailSpy).toHaveBeenCalledTimes(3);
      expect(focusRegistrations(registrations)).toHaveLength(1);
      expect(document.activeElement).toBe(root.querySelector("#login-email"));
    });
  });

  // =========================================================================
  // Scoped target focus: outcomes with no form and no invalid field
  // =========================================================================
  describe("scoped target focus", () => {
    it("focuses the named element inside its own root", () => {
      const root = buildRoot({ innerHTML: VALID_LOGIN_FORM_HTML });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const recoverySpy = focusSpy(root, "#login-recovery");

      pushScopedTargetEvent(registrations, { id: "login-recovery" });

      expect(recoverySpy).toHaveBeenCalledTimes(1);
      expect(document.activeElement).toBe(
        root.querySelector("#login-recovery"),
      );
    });

    it("never focuses a target outside its own root", () => {
      const outside = document.createElement("div");
      outside.innerHTML = `<div id="outside-target" tabindex="-1"></div>`;
      document.body.appendChild(outside);

      const root = buildRoot({ innerHTML: VALID_LOGIN_FORM_HTML });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const outsideSpy = vi.spyOn(
        outside.querySelector("#outside-target"),
        "focus",
      );

      pushScopedTargetEvent(registrations, { id: "outside-target" });

      expect(outsideSpy).not.toHaveBeenCalled();
    });

    it("ignores a missing target, a blank id, and a missing payload", () => {
      const root = buildRoot({ innerHTML: VALID_LOGIN_FORM_HTML });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      expect(() => {
        pushScopedTargetEvent(registrations, { id: "not-here" });
        pushScopedTargetEvent(registrations, { id: "" });
        pushScopedTargetEvent(registrations, undefined);
      }).not.toThrow();

      expect(document.activeElement).toBe(document.body);
    });

    it("leaves the form-error handler untouched", () => {
      const root = buildRoot();
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const emailSpy = focusSpy(root, "#login-email");

      pushScopedTargetEvent(registrations, { id: "login-recovery" });

      expect(emailSpy).not.toHaveBeenCalled();
      expect(document.activeElement).toBe(
        root.querySelector("#login-recovery"),
      );
    });
  });

  // =========================================================================
  // Invalid-field precedence and scoping
  // =========================================================================
  describe("invalid-field precedence", () => {
    it("focuses the first aria-invalid control in the named form and not the fallback", () => {
      const root = buildRoot();
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const emailSpy = focusSpy(root, "#login-email");
      const passwordSpy = focusSpy(root, "#login-password");
      const recoverySpy = focusSpy(root, "#login-recovery");

      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });

      expect(emailSpy).toHaveBeenCalledTimes(1);
      expect(passwordSpy).not.toHaveBeenCalled();
      expect(recoverySpy).not.toHaveBeenCalled();
      expect(document.activeElement).toBe(root.querySelector("#login-email"));
    });

    it("ignores invalid controls outside the named form", () => {
      const root = buildRoot({
        innerHTML: `
          <div id="login-recovery" tabindex="-1">Recovery</div>
          <form id="login_form">
            <input id="login-email" type="email" />
          </form>
          <form id="reset_password_form">
            <input id="reset-password-email" type="email" aria-invalid="true" />
          </form>
        `,
      });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const otherFormSpy = focusSpy(root, "#reset-password-email");
      const recoverySpy = focusSpy(root, "#login-recovery");

      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });

      expect(otherFormSpy).not.toHaveBeenCalled();
      expect(recoverySpy).toHaveBeenCalledTimes(1);
    });

    it("never focuses targets outside its own root", () => {
      const outside = document.createElement("div");
      outside.innerHTML = `
        <form id="outside_form">
          <input id="outside-email" type="email" aria-invalid="true" />
        </form>
        <div id="outside-recovery" tabindex="-1">Outside recovery</div>
      `;
      document.body.appendChild(outside);

      const root = buildRoot({ innerHTML: VALID_LOGIN_FORM_HTML });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const outsideEmailSpy = vi.spyOn(
        outside.querySelector("#outside-email"),
        "focus",
      );
      const outsideRecoverySpy = vi.spyOn(
        outside.querySelector("#outside-recovery"),
        "focus",
      );
      const insideRecoverySpy = focusSpy(root, "#login-recovery");

      pushServerEvent(registrations, {
        form_id: "outside_form",
        fallback_id: "outside-recovery",
      });

      expect(outsideEmailSpy).not.toHaveBeenCalled();
      expect(outsideRecoverySpy).not.toHaveBeenCalled();
      expect(insideRecoverySpy).not.toHaveBeenCalled();
    });
  });

  // =========================================================================
  // Bounded fallback
  // =========================================================================
  describe("bounded fallback", () => {
    it("focuses the fallback when the named form has no invalid control", () => {
      const root = buildRoot({ innerHTML: VALID_LOGIN_FORM_HTML });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const recoverySpy = focusSpy(root, "#login-recovery");

      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });

      expect(recoverySpy).toHaveBeenCalledTimes(1);
      expect(document.activeElement).toBe(
        root.querySelector("#login-recovery"),
      );
    });

    it("focuses the fallback when the named form is missing", () => {
      const root = buildRoot({
        innerHTML: `<div id="login-recovery" tabindex="-1">Recovery</div>`,
      });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const recoverySpy = focusSpy(root, "#login-recovery");

      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });

      expect(recoverySpy).toHaveBeenCalledTimes(1);
    });

    it("is a safe no-op when fallback_id is null or absent and no invalid control exists", () => {
      const root = buildRoot({ innerHTML: VALID_LOGIN_FORM_HTML });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const emailSpy = focusSpy(root, "#login-email");
      const recoverySpy = focusSpy(root, "#login-recovery");

      expect(() =>
        pushServerEvent(registrations, {
          form_id: "login_form",
          fallback_id: null,
        }),
      ).not.toThrow();
      expect(() =>
        pushServerEvent(registrations, { form_id: "login_form" }),
      ).not.toThrow();

      expect(emailSpy).not.toHaveBeenCalled();
      expect(recoverySpy).not.toHaveBeenCalled();
    });
  });

  // =========================================================================
  // Mount focus
  // =========================================================================
  describe("mount focus", () => {
    it("focuses the data-focus-on-mount target on mount, not the invalid scan", () => {
      const root = buildRoot({ dataset: { focusOnMount: "login-recovery" } });
      const { hook } = makeHook(root);

      const recoverySpy = focusSpy(root, "#login-recovery");
      const emailSpy = focusSpy(root, "#login-email");

      hook.mounted();

      expect(recoverySpy).toHaveBeenCalledTimes(1);
      expect(emailSpy).not.toHaveBeenCalled();
      expect(document.activeElement).toBe(
        root.querySelector("#login-recovery"),
      );
    });

    it("does not focus anything on mount without data-focus-on-mount", () => {
      const root = buildRoot();
      const { hook } = makeHook(root);

      const emailSpy = focusSpy(root, "#login-email");
      const recoverySpy = focusSpy(root, "#login-recovery");

      hook.mounted();

      expect(emailSpy).not.toHaveBeenCalled();
      expect(recoverySpy).not.toHaveBeenCalled();
    });

    it("is a safe no-op when the mount target is missing or empty", () => {
      const missingRoot = buildRoot({
        dataset: { focusOnMount: "nonexistent" },
      });
      const { hook: missingHook } = makeHook(missingRoot);
      expect(() => missingHook.mounted()).not.toThrow();

      const emptyRoot = buildRoot({ dataset: { focusOnMount: "" } });
      const { hook: emptyHook } = makeHook(emptyRoot);
      expect(() => emptyHook.mounted()).not.toThrow();
      expect(document.activeElement).not.toBe(
        emptyRoot.querySelector("#login-email"),
      );
    });

    it("does not focus an out-of-root mount target", () => {
      const outside = document.createElement("div");
      outside.id = "outside-mount";
      outside.tabIndex = -1;
      document.body.appendChild(outside);

      const root = buildRoot({ dataset: { focusOnMount: "outside-mount" } });
      const { hook } = makeHook(root);
      const outsideSpy = vi.spyOn(outside, "focus");

      hook.mounted();

      expect(outsideSpy).not.toHaveBeenCalled();
    });
  });

  // =========================================================================
  // Missing, duplicate, and malformed targets fail closed
  // =========================================================================
  describe("missing and malformed targets", () => {
    it("is a safe no-op for an unknown form id", () => {
      const root = buildRoot();
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const emailSpy = focusSpy(root, "#login-email");

      expect(() =>
        pushServerEvent(registrations, {
          form_id: "missing_form",
          fallback_id: null,
        }),
      ).not.toThrow();
      expect(emailSpy).not.toHaveBeenCalled();
    });

    it("fails closed when a duplicate id resolves canonically outside the root", () => {
      const outside = document.createElement("div");
      outside.innerHTML = `
        <form id="dup_form">
          <input id="dup-outside-input" type="email" aria-invalid="true" />
        </form>
      `;
      document.body.appendChild(outside);

      const root = buildRoot({
        innerHTML: `
          <form id="dup_form">
            <input id="dup-inside-input" type="email" aria-invalid="true" />
          </form>
        `,
      });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const outsideSpy = vi.spyOn(
        outside.querySelector("#dup-outside-input"),
        "focus",
      );
      const insideSpy = focusSpy(root, "#dup-inside-input");

      expect(() =>
        pushServerEvent(registrations, { form_id: "dup_form", fallback_id: null }),
      ).not.toThrow();

      expect(outsideSpy).not.toHaveBeenCalled();
      expect(insideSpy).not.toHaveBeenCalled();
    });

    it("ignores malformed payloads without throwing", () => {
      const root = buildRoot({ innerHTML: VALID_LOGIN_FORM_HTML });
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const emailSpy = focusSpy(root, "#login-email");
      const recoverySpy = focusSpy(root, "#login-recovery");

      const payloads = [
        {},
        { form_id: null, fallback_id: null },
        { form_id: 42, fallback_id: 7 },
        { form_id: "", fallback_id: "" },
        undefined,
        null,
      ];

      payloads.forEach((payload) => {
        expect(() => pushServerEvent(registrations, payload)).not.toThrow();
      });

      expect(emailSpy).not.toHaveBeenCalled();
      expect(recoverySpy).not.toHaveBeenCalled();
    });
  });

  // =========================================================================
  // Late focus restoration by the caller must not win
  // =========================================================================
  describe("re-asserting focus after the frame", () => {
    it("takes focus back when something else claims it in the same task", async () => {
      const root = buildRoot();
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });

      // LiveView restores focus to the submitting control after hook events.
      root.querySelector("#login-submit").focus();
      expect(document.activeElement).toBe(root.querySelector("#login-submit"));

      await new Promise((resolve) => requestAnimationFrame(resolve));
      await new Promise((resolve) => requestAnimationFrame(resolve));

      expect(document.activeElement).toBe(root.querySelector("#login-email"));
    });

    it("does not re-focus when the user has already moved on deliberately", async () => {
      const root = buildRoot();
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const emailSpy = focusSpy(root, "#login-email");

      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });

      await new Promise((resolve) => requestAnimationFrame(resolve));
      await new Promise((resolve) => requestAnimationFrame(resolve));

      expect(emailSpy).toHaveBeenCalledTimes(1);
    });
  });

  // =========================================================================
  // DOM preservation: focus-only, never owns or mutates DOM
  // =========================================================================
  describe("DOM preservation", () => {
    it("does not mutate DOM when focusing from a server event", () => {
      const root = buildRoot();
      const { hook, registrations } = makeHook(root);
      hook.mounted();

      const before = document.body.innerHTML;

      pushServerEvent(registrations, {
        form_id: "login_form",
        fallback_id: "login-recovery",
      });

      expect(document.body.innerHTML).toBe(before);
    });

    it("does not mutate DOM when focusing on mount", () => {
      const root = buildRoot({ dataset: { focusOnMount: "login-recovery" } });
      const { hook } = makeHook(root);

      const before = document.body.innerHTML;

      hook.mounted();

      expect(document.body.innerHTML).toBe(before);
    });
  });
});
