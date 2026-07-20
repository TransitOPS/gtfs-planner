# Authentication and Setup Audit

## Scope, routes, and method

Source-inspection audit of the public entry and account-activation workflow:

| Route | LiveView / controller | Rendered branches inspected |
|---|---|---|
| `/first` | `FirstAdminLive` | first-install form; existing-install redirect; validation; setup success/failure |
| `/users/log_in` + `POST /users/log_in` | `UserLoginLive`, `UserSessionController` | form; invalid credentials; deactivated account; missing organization; successful login |
| `/users/reset_password` | `UserForgotPasswordLive` | form; validate; anti-enumeration success |
| `/users/reset_password/:token` | `UserResetPasswordLive` | valid, invalid, and expired token; validate; reset success/failure |
| `/users/confirm/:token` | `UserConfirmationLive` | token confirmation success/failure; source-only resend form branch |
| `/users/accept_invite/:token` | `UserAcceptInviteLive` | valid/invalid token; validate; acceptance success/failure |

Direct dependencies inspected: `router.ex`, `layouts.ex` (`Layouts.auth`), the form/header/button/input/feedback primitives in `core_components.ex`, `layouts/root.html.heex`, `UserSessionController`, account/organization changesets, relevant LiveView and authentication tests, the `/design` Foundations and Components pages, and the written design guides.

This is a source-evidenced audit, not a claim about browser-rendered pixels. The shared primitive defects already recorded as `SHR-005`, `SHR-008`, `SHR-011`, `SHR-013`, `SHR-015`, `SHR-017`, and `SHR-018` in `shared-shell-and-components.md` are referenced rather than duplicated here.

## Posture and applicable standards

These surfaces use the functionalist posture: one clear account task, restrained structure, plain language, visible recovery, and minimal input cost. Normative standards are the shipped `/design` Foundations and Components pages; `docs/design/cta-design.md`, `form-design.md`, and the UX-state/functionalist guides; and production components in `core_components.ex`. Proposal pages are advisory only. No finding below treats a proposal as a compliance requirement.

The most relevant shipped rules are:

- use one-column `<.simple_form>` and `<.input>` fields with visible labels, useful help, preserved input, and fix-oriented errors;
- validate after interaction (the written guide specifies blur), focus/announce errors, and prevent duplicate submission while showing progress;
- use sentence-case verb + noun labels, one primary action, and one-to-four words;
- use semantic feedback: field errors for validation, in-flow callouts for actionable view/form failures, flashes for background outcomes;
- define success, error, permission/unavailable, and reconnecting states, not only the ideal form;
- use semantic color tokens, the documented type hierarchy, and `<.icon>` for Heroicons.

## Current implementation summary

All routed forms use `Layouts.auth`, `<.simple_form>`, `<.input>`, and the shared primary button. The flows preserve the anti-enumeration behavior for reset and confirmation emails, show LiveView validation on most password/setup forms, and use `phx-disable-with` to block duplicate submissions. Invalid/expired reset tokens have test coverage, as do reset submission and invite validation.

The major gaps are state integrity and feedback. First-install organization errors cannot map back to the rendered fields, the optional alias is not optional in practice, synchronous login failures are transient flashes, successful activation/reset/setup actions provide no acknowledgment on the destination, and the resend-confirmation render branch has no route. Shared form error semantics, title hierarchy, auth-card depth, and browser-title identity are covered by the `SHR-*` dependencies.

## State coverage matrix

| Surface | Ideal | Loading / submit | Empty / first use | Error | Partial / degraded | Permission / unavailable | Offline / stale | Assessment |
|---|---|---|---|---|---|---|---|---|
| First administrator | Form renders | `phx-disable-with` only | This is the intended first-use state | User errors may render; organization errors do not map to fields | Transaction fallback is not rendered | Existing install redirects silently | Reconnect flash via auth layout; stale N/A | Failing organization error/preservation contract |
| Login | Form renders | Native POST + `phx-disable-with` | N/A | Credentials/account/org failures return as dismissible flash | N/A | Authenticated users redirect | Reconnect flash | Partial; actionable failures are outside the form |
| Forgot password | Form renders | `phx-disable-with` | N/A | Email format is not validated inline | Mail-delivery failure is not surfaced to the user | Authenticated users redirect | Reconnect flash | Anti-enumeration success is correct; validation/recovery is thin |
| Reset password | Valid-token form | `phx-disable-with` | N/A | Field errors; invalid/expired token redirects with flash | N/A | Authenticated users redirect | Reconnect flash | Partial; success has no acknowledgment |
| Confirmation | No ideal token page; immediate redirect | No visible pending state | N/A | Invalid/expired token redirects with flash | Mail delivery result ignored in resend branch | Resend form is unreachable | Reconnect flash only if a page renders | Failing route/state completeness |
| Accept invite | Valid-token form | `phx-disable-with` | N/A | Field errors; invalid token redirects with flash | N/A | Authenticated users redirect | Reconnect flash | Partial; success has no acknowledgment |

Synchronous, server-owned auth forms do not need first-paint skeletons. Stale/revalidating is not applicable because these pages do not retain refreshable data. Offline handling is inherited from `Layouts.flash_group`; the shared quality of that feedback is owned by the shell report.

## Findings

| ID | Priority | Type | Evidence | Standard | Gap | Required correction |
|---|---|---|---|---|---|---|
| AUTH-001 | P0 | violation | `lib/gtfs_planner_web/live/first_admin_live.ex:34-47,78-92`; `lib/gtfs_planner/accounts.ex:609-631`; `lib/gtfs_planner/organizations/organization.ex:32-40` | Form guide: preserve input and explain what/how to fix | The setup form names organization fields `organization_name`/`organization_alias`, but a failed organization insert returns errors on `name`/`alias` and is passed directly to `to_form`. Those errors cannot associate with the rendered controls, and the replacement form cannot reliably preserve the setup field values. | Drive setup from one form contract whose field names match all user/org errors, or explicitly remap organization errors and values back to the setup fields. |
| AUTH-002 | P1 | violation | `lib/gtfs_planner_web/live/first_admin_live.ex:41-47,78-83`; `lib/gtfs_planner/organizations/organization.ex:32-40`; `lib/gtfs_planner_web/router.ex:78-97,120-132` | Form guide: required/optional truth; every field is a cost; plain accurate help | “Organization alias (optional)” submits `""`, but `||` defaults only `nil`; the organization changeset then requires the blank alias. Its help also promises `/gtfs/<organization-alias>`, while current GTFS browser routes are version-ID scoped. | Treat blank as absent and generate the alias, or make the field truly required. Replace the stale URL promise with accurate purpose text; remove the field if users do not need to choose it. |
| AUTH-003 | P1 | violation | `lib/gtfs_planner_web/controllers/user_session_controller.ex:10-39`; `lib/gtfs_planner_web/live/user_login_live.ex:11-40`; `lib/gtfs_planner_web/live/design/component_pages.ex:567-580,638-667,755-768` | Feedback component guidance: validation/action failures in flow; flash for background outcomes | Invalid credentials, deactivation, and missing organization are synchronous login outcomes that require recovery, yet they appear only as dismissible layout flashes after a redirect. The form has no persistent error summary/callout and no focus target. | Render a form-level error/callout adjacent to login, preserve the email, move/announce focus appropriately, and keep anti-enumeration copy for credential failure. |
| AUTH-004 | P1 | consistency | `lib/gtfs_planner_web/router.ex:54-59`; `lib/gtfs_planner_web/live/user_confirmation_live.ex:7-29,33-80` | Functionalist navigation; UX states: every state has a reachable next action | The only confirmation route requires `:token`; therefore the tokenless `mount/3` and “Resend confirmation instructions” form are unreachable from the router and are not linked from login. | Decide the product path: add an intentional resend route and discoverable entry point, or remove the dead render branch. Cover the chosen route and anti-enumeration outcome in tests. |
| AUTH-005 | P1 | violation | `lib/gtfs_planner_web/live/first_admin_live.ex:85-90`; `lib/gtfs_planner_web/live/user_reset_password_live.ex:68-75`; `lib/gtfs_planner_web/live/user_confirmation_live.ex:9-17`; `lib/gtfs_planner_web/live/user_accept_invite_live.ex:74-81`; `lib/gtfs_planner_web/live/design/component_pages.ex:567-593` | UX feedback: acknowledge outcomes; flashes for completed background outcomes | Successful first setup, password reset, confirmation, and invite acceptance redirect without a success acknowledgment. The user lands on login with no confirmation that the requested account mutation completed. | Put a concise success flash on the login destination for each completed action, with distinct wording that names the outcome. Preserve the existing error feedback for invalid tokens. |
| AUTH-006 | P1 | violation | `lib/gtfs_planner_web/live/first_admin_live.ex:14,96-109`; `lib/gtfs_planner_web/live/user_forgot_password_live.ex:15-20,73-75`; `lib/gtfs_planner_web/live/user_reset_password_live.ex:14-18,82-85`; `lib/gtfs_planner_web/live/user_accept_invite_live.ex:15-20,88-90`; `lib/gtfs_planner_web/live/design/foundation_pages.ex:82-90`; `docs/design/form-design.md:1-35` | Forms: validate on blur, preserve input, explain correction | Most auth forms attach `phx-change` to the whole form, validating on every keystroke rather than blur. First-admin validation also validates only user fields, so organization fields receive no interactive validation. | Use a consistent after-interaction/blur policy per field and validate the complete form contract. Do not show errors before interaction; keep all entered values after validation. |
| AUTH-007 | P2 | violation | `first_admin_live.ex:22-33`; `user_reset_password_live.ex:20-32`; `user_accept_invite_live.ex:21-33`; `user_settings_live.ex:66-77`; `user.ex:139-143` | Form guide: reduce uncertainty; errors explain how to fix | Every password creation/change flow enforces 12–72 characters but gives no up-front help. Users learn the basic constraint only after failure. | Add concise, programmatically associated password help everywhere the rule applies; keep confirmation errors specific and avoid disclosing passwords. |
| AUTH-008 | P2 | violation | `user_login_live.ex:35-38`; `user_accept_invite_live.ex:35-38`; `foundation_pages.ex:68-80`; `docs/design/cta-design.md:1-33` | CTA guide: sentence case, one-to-four words, no punctuation/fluff; icons through `<.icon>` | “Log in →” appends a decorative raw glyph, and “Accept invite & set password” is a five-word compound promise with punctuation. Both drift from the compact verb+noun vocabulary. | Use concise literal promises such as “Log in” and “Set password”/“Accept invite”; if an icon materially adds meaning, use `<.icon>` after the text. |
| AUTH-009 | P2 | consistency | `user_login_live.ex:45-49`; `user_forgot_password_live.ex:46-49`; `user_reset_password_live.ex:50-63`; `user_accept_invite_live.ex:51-68`; `layouts/root.html.heex:8-10` | Product identity and semantic page titles; see `SHR-018` | Login, forgot-password, valid-token reset, and invite acceptance do not assign `page_title`. They fall back to the scaffold title/suffix rather than naming the current task. | Assign a unique, concise title for every rendered auth state and implement the shared product-title correction in `SHR-018`. |
| AUTH-010 | P2 | consistency | `first_admin_live.ex:9-12`; `user_accept_invite_live.ex:10-13`; `dashboard_live.ex:99-101`; `foundation_pages.ex:102-110` | Functionalist plain/front-loaded language | “Welcome to Pathways Studio” repeats brand identity instead of naming the form task. On setup and invite pages the useful task appears only in the subtitle. | Front-load task headings (“Create administrator account”, “Set password”) and keep context in a short subtitle. |
| AUTH-011 | P2 | consistency | `first_admin_live.ex:49`; `user_login_live.ex:36`; `user_forgot_password_live.ex:30`; `user_reset_password_live.ex:35`; `user_confirmation_live.ex:49`; `user_accept_invite_live.ex:36`; `component_pages.ex:596-635` | UX feedback: visible progress and duplicate-submit prevention | Auth submit controls change text through `phx-disable-with`, but they do not use the shipped loading treatment (pending opacity/spinner/announcement), and progress copy/punctuation varies by page. | Standardize auth-submit pending feedback through a shared pattern that disables duplicates, exposes task-specific progress, respects reduced motion, and is announced without replacing useful error content. |
| AUTH-012 | P3 | violation | `test/gtfs_planner_web/live/user_reset_password_live_test.exs:25-88`; `test/gtfs_planner_web/live/user_accept_invite_live_test.exs:18-60`; `test/gtfs_planner_web/live/header_test.exs:7-20`; no dedicated tests for first-admin/login/forgot/confirmation | Audit completion and UX-state guide | Tests cover reset and limited invite states but do not pin first setup, login form recovery, forgot-password feedback, confirmation route completeness, browser titles, focus, or submit progress. | Add small state-focused LiveView/controller tests using IDs and semantic selectors; include failure preservation and successful destination feedback. |
| AUTH-013 | P2 | violation | `assets/js/form_error_focus_hook.js:16-47`; `assets/e2e/authentication.spec.js` failed-submit cases; `focusin` trace: hook focuses the invalid field, submit button regains focus ~1ms later | Form guide: focus/announce the first error after a failed submit | Discovered during step-10 browser evidence. The `FormErrorFocus` hook focuses the first `[aria-invalid="true"]` control on the server event, but LiveView re-enables the `phx-disable-with` submit button and the browser returns focus to that button ~1ms later, so resting focus is the button. The correction context is correct and the field stays keyboard-reachable. | Defer the focus to win the button re-enablement race (redefines the step-3 single-attempt focus contract INV-11); owned by a FormErrorFocus follow-up, not Package 10. |
| AUTH-014 | P2 | violation | `lib/gtfs_planner_web/components/core_components.ex:104-140` (default button size); `assets/e2e/authentication.spec.js` target-size case (measured 40px button, 48px inputs) | CTA guide: preserve 44px targets | Discovered during step-10 browser evidence. The shared default `<.button>` renders at 40px on auth surfaces — clears the WCAG 2.5.8 AA minimum (24px) but not the 44px design target cited by AUTH-011/AC-19. `input-lg` fields render at 48px. | Close the gap in the shared button component (e.g. a 44px minimum or an auth `size="lg"`), not with auth-local styling; owned by a Package 9 button follow-up, not Package 10. |

## Detailed finding notes and acceptance criteria

### AUTH-001 and AUTH-002 — first-install form integrity

- Submitting a blank optional alias succeeds and stores the deterministic alias generated from organization name, unless product explicitly makes the field required.
- Duplicate/invalid organization names or aliases render beside the correct control, preserve email, organization name, alias, and all non-secret values, and focus the first invalid field.
- Password values follow the chosen security-preservation policy; the UI must not silently clear unrelated fields.
- Help text describes current behavior and does not cite a route shape absent from `router.ex`.
- LiveView tests cover blank alias, duplicate alias, organization validation, and transaction failure without inspecting raw HTML.

### AUTH-003 through AUTH-006 — recovery and outcomes

- Invalid login leaves the email visible and places a named in-flow error at the form; the copy does not reveal whether the account exists.
- Deactivated and unassigned-organization failures state the next action and remain visible until the user navigates or resolves them.
- Setup/reset/confirmation/invite success lands on login with one concise success message.
- Interactive validation starts after blur/interaction, not on untouched fields, and every rendered error says what to change.
- The resend-confirmation task is either reachable and tested or removed; there is no source-only user-facing branch.

### AUTH-007 through AUTH-011 — content, titles, and pending state

- All password-setting forms expose the same 12–72-character help through `aria-describedby` after `SHR-005` is fixed.
- Every auth page has one task-naming H1 and one browser title; brand identity remains in the auth shell rather than being repeated as the task heading.
- Primary labels are sentence case, one-to-four words, and match their outcome.
- Submit pending state appears immediately, prevents a second action, and remains usable with reduced motion.
- Verify at 320 px, 200% zoom, and keyboard-only. No form field or recovery link clips or changes visual order unexpectedly.

## Shared-component candidates and dependencies

1. Implement `SHR-005` before page-by-page error work so help/error IDs and `aria-invalid` are consistent.
2. Implement `SHR-008` once for auth/page headings; avoid local size overrides.
3. Implement `SHR-011` and the semantic-token portion of `SHR-003` in `Layouts.auth`, not in six LiveViews.
4. Implement `SHR-013` in `<.simple_form>` before standardizing blur and pending behavior.
5. Implement `SHR-015`, `SHR-017`, and `SHR-018` for explicit flash dismissal, reduced motion, and product browser titles.
6. Consider a setup-specific changeset/form object as the reusable boundary for AUTH-001/002; do not teach the generic input component mismatched domain field names.

## Verification plan

- Add/extend LiveView tests for each route and each branch in the matrix, selecting `#first_admin_form`, `#login_form`, `#reset_password_form`, `#resend_confirmation_form` (if retained), and `#accept_invite_form`.
- Assert semantic outcomes with `has_element?/2`: task H1, associated inline errors, callout role/name, loading/disabled state, destination flash, and browser title.
- Exercise invalid and expired tokens, blank/duplicate alias, wrong credentials, deactivated and unassigned accounts, mail-delivery degradation, invalid password, and success.
- Run keyboard-only checks for initial focus, first error focus, and post-submit destination.
- Check 320, 768, and desktop widths plus 200% zoom; then run `mix precommit` after implementation.

## Exclusions and unknowns

- Email message templates and delivery copy are outside this browser-surface report; only the on-page result of delivery is audited.
- Authentication and authorization policy correctness is not redesigned here. Anti-enumeration is a hard constraint and must be preserved.
- No live browser or visual-regression capture was produced; spacing, contrast interaction, and actual focus movement require verification.
- The confirmation resend branch is documented from source but cannot be rendered through the current router.
- Shared shell/component defects are intentionally not duplicated as implementation findings; this report depends on the cited `SHR-*` items.
## Package 0 dispositions

- **`AUTH-004` — remove.** Remove the unreachable tokenless confirmation-resend form, mount branch, and handler. Retain the routed token-confirmation flow. See [decisions.md](decisions.md).
- **Decision 0.12 (2026-07-19) — accessibility scope.** Screen-reader smoke tests, speech/announcement verification, and live-region requirements in this report are removed; render equivalent state visibly and keep keyboard operability, visible focus, 320 px, and 200% zoom checks. See [decisions.md](decisions.md).

## Package 5 implementation evidence (in progress)

Status on 2026-07-18: Package 5 ("Restore first-install error mapping") is implemented and automatically verified on branch `005-dsa-restore-first-install-error-mapping`. `AUTH-001` remains **in progress**: automated evidence does not satisfy the external browser gate below, and no completion is claimed here. No commit or PR identifier is recorded yet; append it when the work is merged.

### Implemented files

- `lib/gtfs_planner/accounts/first_admin_form.ex` — composite five-field embedded form model: composed user/organization validation, required/matching password confirmation, domain-to-browser error mapping (`:name` → `:organization_name`, `:alias` → `:organization_alias`), transaction-failure normalization with safe diagnostics, and secret sanitization.
- `lib/gtfs_planner/accounts.ex` — `change_first_admin/1` plus the sole-arity `register_first_admin/1` (replaces `/2`): composite preflight, preserved `:user -> :org -> :version -> :membership -> :confirm_user` `Ecto.Multi`, all failures returned as composite changesets.
- `lib/gtfs_planner_web/components/core_components.ex` — backward-compatible `announce_errors` opt-out on `<.input>` (default announcement contract unchanged).
- `docs/design/form-design.md` and `lib/gtfs_planner_web/live/design/component_pages.ex` — documented default announcement contract and the licensed opt-out conditions.
- `lib/gtfs_planner_web/live/first_admin_live.ex` — composite-form mount/change/submit, stable DOM contract (`#first_admin_form`, five stable control IDs, `#first-admin-submit`), submit-only fixed-order `#first-admin-error-summary` (non-live, focusable), failed-submit secret clearing, and the `.FirstAdminErrorFocus` colocated hook pushing exactly one `focus_first_admin_error` event.
- Tests: `test/gtfs_planner/accounts/first_admin_form_test.exs`, `test/gtfs_planner/accounts_test.exs` (first-admin API section), `test/gtfs_planner_web/components/core_components_test.exs`, `test/gtfs_planner_web/live/design_system_live_test.exs`, `test/gtfs_planner_web/live/first_admin_live_test.exs`.

### Automated results (observed 2026-07-18)

- `mix test test/gtfs_planner_web/live/first_admin_live_test.exs` — 12 tests, 0 failures. Includes the existing-user `/` redirect without rendering `#first_admin_form`, the valid first-submit `/users/log_in` destination, one same-view invalid-submit/corrected-submit sequence asserting user/organization/version/membership counts each increase exactly once, and a same-view real duplicate-alias transaction rollback retried to success with the same exactly-once count deltas.
- Focused five-file Package 5 suite (`mix test` over the five files above) — 264 tests, 0 failures (17 form model, 91 accounts context, 26 core components, 118 design system, 12 first-admin LiveView).
- `mix precommit` — 2,493 tests, 0 failures, 5 skipped; Credo strict diff from `origin/main` added no issues.

### Pending external verification (required before `AUTH-001` or Package 5 completion)

Automated LiveView tests prove pushed focus events, DOM order, and `aria-describedby`/summary associations only. Actual focus movement, keyboard correction at 320 px, and 200% zoom remain unverified. Decision 0.12 removes the former Safari + VoiceOver speech gate. A human verifier must capture keyboard-only browser evidence for one combined-error submit and append it here with browser and OS versions, date, and pass/fail result:

- focus visibly lands on `#first-admin-email` after submit;
- summary links reach their controls;
- a base-only failure state focuses the summary; and
- keyboard-only correction works at 320 px and at 200% zoom.

### Findings status after this package

- `AUTH-001` — in progress. Implementation and automated evidence are complete; completion is gated on the keyboard-only browser evidence above (VoiceOver gate removed by decision 0.12).
- `AUTH-002` (blank-alias optionality and help copy), `AUTH-005` (success acknowledgment), and `AUTH-006` (validation timing) remain open and deferred; this package maps the blank-alias error but changes no alias policy, help copy, validation timing, or success acknowledgment.
- The bootstrap race remains out of scope, and the remaining Package 10 findings remain unresolved; Package 10 is not complete.

## Package 10 implementation evidence

Status on 2026-07-20: Package 10 ("Align authentication and setup") is implemented on branch
`010-dsa-align-authentication-setup` (steps 1–9 merged as commits `7f69395`, `79fd162`, `3fec497`,
`f7d08bf`, `50050ed`, `4f77390`, `8fa74fd`, `c244a5e`, `e980d5d`; step 10 adds the browser evidence and
this reconciliation). Every `AUTH-001`–`AUTH-012` row now has an evidence-backed disposition below. Two
new defects surfaced by the step-10 browser evidence are recorded as `AUTH-013` and `AUTH-014`; neither
is claimed resolved by this package and neither blocks Package 11 (both are P2).

### Implemented evidence files (step 10)

- `test/support/browser_seed.exs` — adds isolated, deterministic auth fixtures alongside the existing
  admin/editor/diagram seed (which is unchanged): a deactivated member and a no-organization user for
  login-recovery states, plus distinct users for reset/confirm/invite valid+replay and expired cases.
  Each token fixture is a fixed test-only 32-byte raw value; only its SHA-256 digest is persisted as a
  production-shaped `%UserToken{token: <digest>, context: ..., sent_to: ..., user_id: ...}`. The unpadded
  URL-safe Base64 of each raw value is mirrored verbatim in the spec so token URLs are reproducible
  without parsing mail. Expired rows are backdated with a direct `update_all` (bypassing timestamp
  autogenerate) beyond each context window (`reset_password` 1 day, `confirm`/`invite` 7 days). No
  production token endpoint or bypass is introduced.
- `assets/e2e/authentication.spec.js` (new) — a serial public-auth Playwright suite (one worker, Chromium,
  port 4002, reusing `assets/playwright.config.js` unchanged). 30 cases: login ideal and each recovery
  state (`invalid_credentials`, unknown-email indistinguishability, `deactivated`, `organization_required`),
  recovery-callout mount focus, reset-request common outcome for present and absent accounts, the
  task-specific pending label/form opacity, isolated valid/invalid/expired/replay paths for reset,
  confirmation, and invitation, failed-submit correction context and keyboard reachability, login Tab
  order, 44px input targets, no horizontal overflow at 320/768/desktop, Chromium 200% page-scale reflow,
  and reduced-motion animation disablement.

### AUTH-001–AUTH-012 dispositions

| ID | Disposition | Exact automated evidence |
|---|---|---|
| AUTH-001 | Implementation resolved (Package 5 + step 1 + step 4). Keyboard-only browser check on `/first` recorded separately as a zero-user release observation (below); NOT covered by the seeded suite. | Package 5 commit `4f26b68`; step 1 `7f69395`; step 4 `f7d08bf`; `test/gtfs_planner/accounts/first_admin_form_test.exs`, `test/gtfs_planner_web/live/first_admin_live_test.exs` (error mapping, blank-alias normalization, atomic rollback, focus event). |
| AUTH-002 | Resolved by step 1 (blank/whitespace alias generated from organization name before `Organization.changeset/2`; explicit alias preserved) and step 4 (truthful optional-alias help; stale `/gtfs/<alias>` promise removed). | Step 1 `7f69395`, step 4 `f7d08bf`; `test/gtfs_planner/accounts/first_admin_form_test.exs` (normalization, unsluggable name, collision, blank-visible preservation), `test/gtfs_planner_web/live/first_admin_live_test.exs`. |
| AUTH-003 | Resolved by step 5 (bounded `invalid_credentials`/`deactivated`/`organization_required` recovery callout in flow; email preserved; mount focus via `FormErrorFocus`). | Step 5 `50050ed`; `test/gtfs_planner_web/controllers/user_session_controller_test.exs`, `test/gtfs_planner_web/live/user_login_live_test.exs`; browser `authentication.spec.js` "login recovery: the callout receives keyboard focus after redirect" (focus lands on `#login-recovery`). |
| AUTH-004 | Resolved by step 8 (unreachable tokenless confirmation mount/render/`send_instructions` branch and `#resend_confirmation_form` removed; only `/users/confirm/:token` remains). | Step 8 `c244a5e`; `test/gtfs_planner_web/live/user_confirmation_live_test.exs` (dead branch absent, token confirmation once, invalid/expired/replay to login); browser `authentication.spec.js` confirm valid/replay/invalid/expired. |
| AUTH-005 | Resolved by steps 4/6/7/8/9 (distinct success `:info` flashes at login: administrator created, password reset, email confirmed, invitation accepted). | `f7d08bf`, `4f77390`, `8fa74fd`, `c244a5e`, `e980d5d`; `first_admin_live_test.exs`, `user_reset_password_live_test.exs`, `user_confirmation_live_test.exs`, `user_accept_invite_live_test.exs`; browser `authentication.spec.js` reset/confirm/invite valid-success `#flash-info` assertions. |
| AUTH-006 | Resolved by steps 4/6/7/9 (validation on `phx-blur`/`phx-debounce="blur"`; untouched fields render no errors; submit validates the complete form). | `f7d08bf`, `4f77390`, `8fa74fd`, `e980d5d`; `first_admin_live_test.exs`, `user_forgot_password_live_test.exs`, `user_reset_password_live_test.exs`, `user_accept_invite_live_test.exs` (untouched-vs-blurred); browser `authentication.spec.js` failed-submit correction context. |
| AUTH-007 | Resolved by steps 4/7/9 (shared password help "Use 12–72 characters." on first-admin, reset-token, invite, and settings new-password; confirmation references the primary). | `f7d08bf`, `8fa74fd`, `e980d5d`; `user_reset_password_live_test.exs`, `user_accept_invite_live_test.exs`, `user_settings_live_test.exs` (help association + `aria-describedby`). |
| AUTH-008 | Resolved by step 5 (login CTA arrow glyph removed; one primary "Log in"). | Step 5 `50050ed`; `test/gtfs_planner_web/live/user_login_live_test.exs` (`#login-submit` "Log in", no `→`); browser `authentication.spec.js` login ideal/recovery. |
| AUTH-009 | Resolved by steps 4/5/6/7/9 (distinct `page_title` assigned on every rendered auth state). | `f7d08bf`, `50050ed`, `4f77390`, `8fa74fd`, `e980d5d`; `first_admin_live_test.exs`, `user_login_live_test.exs`, `user_forgot_password_live_test.exs`, `user_reset_password_live_test.exs`, `user_accept_invite_live_test.exs` (page title assertions). |
| AUTH-010 | Resolved by step 4 (task-first H1 "Create administrator account"; brand identity kept in the auth shell). | Step 4 `f7d08bf`; `test/gtfs_planner_web/live/first_admin_live_test.exs` (single task H1). |
| AUTH-011 | Resolved by steps 4/5/6/7/9 (form-level `phx-submit-loading:opacity-60`, task-specific `phx-disable-with`, one primary action). The primary action's rendered target size is recorded separately as `AUTH-014`. | `f7d08bf`, `50050ed`, `4f77390`, `8fa74fd`, `e980d5d`; the LiveView tests above pin `phx-disable-with`/form opacity; browser `authentication.spec.js` "reset request: submit carries the task-specific pending label and form opacity". |
| AUTH-012 | Resolved by steps 4–9 (focused LiveView/controller/context tests across every auth surface). | The 11-file focused suite: `first_admin_form_test.exs`, `password_reset_request_form_test.exs`, `user_session_controller_test.exs`, `first_admin_live_test.exs`, `user_login_live_test.exs`, `user_forgot_password_live_test.exs`, `user_forgot_password_live_failure_test.exs`, `user_reset_password_live_test.exs`, `user_confirmation_live_test.exs`, `user_accept_invite_live_test.exs`, `user_settings_live_test.exs` — 151 tests, 0 failures (`MIX_TEST_PARTITION=step10`). |

### Separate zero-user first-admin observation (AUTH-001 browser gate)

The seeded Playwright suite creates users, so it cannot render `/first` (first-install only appears with
zero users). Consistent with the Package 5 gate and decision 0.12, the keyboard-only browser check on
`/first` requires a zero-user environment and is recorded here as a separate release observation, NOT as
seeded Playwright coverage:

- `AUTH-001` implementation is resolved and automatically verified (Package 5 + steps 1/4).
- The keyboard-only browser check on `/first` (focus lands on `#first-admin-email` after a combined-error
  submit; summary links reach their controls; keyboard-only correction at 320 px and 200% zoom) remains a
  separate release observation requiring a zero-user database. It is not performed by `authentication.spec.js`
  and is not claimed here. No production test bypass was added and the database was not reset beneath a
  running browser suite for this purpose.

### New findings discovered during step-10 browser evidence

- `AUTH-013` (P2, open) — failed-submit auto-focus race. The `FormErrorFocus` hook focuses the first
  `[aria-invalid="true"]` control on the `focus_form_error` server event (jsdom-pinned in step 3,
  event-push pinned in steps 5/6/7/9), and a `focusin` trace confirms it focuses the field — but LiveView
  re-enables the `phx-disable-with` submit button and the browser hands focus back to that button ~1ms
  later, so the resting focus is the button, not the invalid field. The correction context
  (`aria-invalid="true"` + visible error) is correct and the field stays keyboard-reachable. Resolving the
  focus race requires redefining the step-3 single-attempt focus contract (INV-11) — e.g. a deferred
  re-focus — which is step-3 ownership, not a step-10 change. Owner: a FormErrorFocus follow-up.
- `AUTH-014` (P2, open) — primary-action target size. The shared default `<.button>` renders at 40px on
  the auth surfaces: it clears the WCAG 2.5.8 AA minimum (24px) but not the 44px design target cited by
  `AUTH-011`/`AC-19`. The `input-lg` fields render at 48px (≥44px). This is a shared button-sizing gap,
  not auth-local; Package 10 may not introduce auth-only styling to close it. Owner: the shared button
  component (Package 9 follow-up).

### Step-10 verification record (observed 2026-07-20)

Focused gates were run green before browser evidence (regression gate INV-22):

- `MIX_TEST_PARTITION=step10 mix test <11 focused files>` — 151 tests, 0 failures. (The default partition
  is contended by an external user-owned `beam.smp` that holds test-DB connections; the partitioned run is
  the substitute of record, matching the step-4–9 precedent.)
- `npm --prefix assets test -- --run js/__tests__/form_error_focus_hook_test.js` — 17 tests, 0 failures.
- `MIX_ENV=test mix ecto.reset` — succeeded (migrations re-applied).
- `MIX_ENV=test mix run test/support/browser_seed.exs` — succeeded; all existing admin/editor/diagram
  fixtures plus the 8 new auth fixtures created.
- `npm --prefix assets run test:browser -- authentication.spec.js` — 30 tests, 0 failures (Chromium, one
  worker, port 4002).
- `mix precommit` — passed: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`,
  `credo diff --from-git-ref origin/main --strict` (no added issues after the step-10 nesting refactor of
  `UserForgotPasswordLive.handle_event/2` into a private `maybe_deliver_reset_instructions/1` helper), and
  `mix test` — 2,795 tests, 0 failures, 5 skipped. The full suite was run against a freshly reset test
  database (the browser seed commits persistent fixtures that the empty-DB suite assumes absent, so the
  database is reset before the suite per the seed's documented workflow).

Limitations: the 200% check exercises a 640×400 CSS layout viewport (the established
`shared_design_contracts.spec.js` approach) so media queries and reflow run; the `AUTH-013` focus race and
`AUTH-014` 40px button are recorded above rather than fixed in this non-visual step.
