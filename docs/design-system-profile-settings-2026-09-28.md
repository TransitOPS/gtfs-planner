# TransitOps design system — profile settings page (2026-09-28)

`/users/settings` moves from the daisyUI palette to the TransitOps application
design system, on the same terms as the routes work surface
(`docs/design-system-routes-2026-09-28.md`): an unlayered page scope in
`app.css`, the header and every other page keep the daisyUI palette, and no
`--color-primary` change is made app-wide.

The page carries no table, so the shared `.workbench` rules do not apply. The
DS's card, field, callout, badge and form-error-summary grammars do, and those
are what the page is rebuilt from.

## Applicability check

`tmp/redesign/profile-page.html` and the design system's `application.html`
share one token grammar:

- Palette: navy `--color-strong`/`--color-default`/`--color-muted`, magenta
  `--color-action`, cyan-700/800 for informational text.
- Surfaces: `--color-canvas` card heads, `--color-subtle` hairlines,
  `--color-control` control boundaries, `--radius-control`/`--radius-card`/
  `--radius-badge`.
- Grammars: `.workbench` cards, `.field` (label over a 44px control over 13px
  help), `.callout`, `.badge`, `.form-error-summary`, and the `.field` state
  rules (`[aria-invalid="true"]` takes a 2px error border).

`<.input>` is the app's single input implementation and emits daisyUI's
`fieldset`/`label`/`label-text` structure, which is the same shape as the DS's
`.field`. Rather than replace it, `#account-page` restyles it, so the app keeps
one input implementation and every other form is untouched.

The `@theme` block gained the tokens this page needed and the header did not:
`--color-soft`, `--color-cyan-700`/`--color-cyan-800`,
`--color-success-bg`/`--color-success-fg`, `--color-warning-bg`/`--color-warning-fg`.

## What changed

`assets/css/app.css` — an unlayered `#account-page` scope mirroring
`#blocks-page`: `--color-primary` mapped to `--color-action` (so a filled button
paints #C81870, 5.50:1 for white text), `font-family: var(--font-ds)`, Gabarito
28px/600 for `h1`/`h2` over a 13px muted subtitle, and a 2px `var(--color-focus)`
focus-visible outline. Plus `.account-card`/`-card-head`/`-card-body`,
`.account-field`, `.account-error-summary`, `.account-callout`
(soft/warning/error), and `.account-badge` (selected/success/warning).

Every colour pair in that block was machine-checked against its stated ratio;
the lowest is the control boundary at 3.69:1 against a 3:1 floor, and every text
pair is at or above 4.5:1.

`lib/gtfs_planner_web/live/user_settings_live.ex` — two credential cards in the
main column and a read-only account record in an aside, split into
`email_card/1`, `password_card/1`, `account_facts/1` and `error_summary/1`.
Four behaviour and copy fixes rode along, each traceable to code:

1. **The `.SettingsFormFocus` polling hook is gone.** It ran a 10 × 25ms
   `setInterval` re-asserting focus, because there was no error summary to aim
   at. Each form now renders a `role="alert" tabindex="-1"` summary linking to
   each failing field, and focus goes to it through `FormErrorFocus` — the
   shared hook already registered in `assets/js/app.js`, which re-asserts once on
   the next frame. 250ms of polling became one frame.
2. **The confirmation-mismatch error moved to the field the reader is typing
   in.** `validate_confirmation/3` attaches "does not match" to `:password`, so
   a mismatch raised while typing in *Confirm new password* painted a red border
   on *New password*. `move_confirmation_mismatch/1` relocates that one error
   onto `:password_confirmation`; every other error, the params, and `Accounts`
   are untouched. It is a live result, so it announces via `aria-live="polite"`
   and gets no summary — a summary is for a rejection.
3. **Email-change copy now matches the code.** See below; this one was wrong
   twice during the work and the tests caught it.
4. **The sign-out consequence of a password change is stated before the
   button.** `update_user_password/3` deletes every `UserToken` for the account
   — all sessions, all remember-me cookies, and any pending confirmation link —
   and `complete_login/4` re-issues only this device's session. The old page
   never said so, so the reader learned it by being signed out.
5. **One error now reads the same wherever it appears.** A rejected submit shows
   the problem twice: in the summary and under the field. Both go through
   `summary_message/3`, because `translate_error/1` has no gettext entry for a
   `current_password` failure and rendered the field's copy as "is invalid"
   while the summary said "Your current password is not correct." Same error, two
   different sentences, two lines apart. The curated list is read from the
   *form*, not the changeset: `to_form/2` empties the error list when the action
   is `nil`, and that guard is what stops a freshly mounted password form
   showing "can't be blank" for fields the reader has not touched.

## A correction worth recording

An earlier pass in this work claimed `apply_user_email/3` writes the new address
immediately, because it ends in `Ecto.Changeset.apply_action/2`, and rewrote the
copy and flash to say the change was already live. **That was wrong.**
`apply_action/2` validates and returns an updated struct; it does not write. The
address only changes when `update_user_email/2` redeems the token at
`/users/settings/confirm_email/:token`, which `Repo.transaction(user_email_multi(...))`
performs. The app's own pre-existing test in
`user_settings_live_failure_test.exs` already asserted this
(`reloaded.email == old_email`); it was the six rewritten tests that made the
contradiction visible.

The shipped copy therefore states that the link is what completes the change, and
which address stays live until then. The same correction went back into
`tmp/redesign/_src/profile-page.html`, which had the "still signing in as …"
line removed for the same wrong reason and has it back.

## A pre-existing bug found on the way

`sanitize_changeset_secrets/1` removed the secret keys from
`changeset.params`. `Phoenix.Component.used_input?/1` returns **false** for an
absent key (`used_param?/2` falls through to `false`), and `<.input
field={...}/>` skips `field.errors` entirely for an unused field. So on a
rejected password change the length and mismatch errors were reported in no
field at all — the summary had nothing consistent to point at, and the deleted
focus hook had nothing to find. The keys are now blanked to `""` rather than
removed, which keeps the field "used" while still echoing nothing; all four
password inputs render `value=""`.

## Decisions

**Both submits are primary.** This breaks the DS's one-primary-per-view rule, and
it is deliberate. The page is two independent forms, each with exactly one
committed action, and neither is a page-level "main thing" — the header says
"Profile settings" and the page is a record of your account. A credential page
whose two commits are both secondary has no visual commit at all, which is what
the page looked like before. The buttons sit in separate cards roughly 600px
apart, so neither reads as *the* page action.

*Rejected:* password primary, email secondary. The frequency argument is
guesswork — an operator changes a password on a schedule and an email address
rarely or never — and ranking two rare operations against each other invents a
hierarchy the data does not support. *Rejected:* both outline, the old
treatment, which is the smallest diff and the least useful.

**The heading stays "Profile settings".** There is no profile: `Accounts.User`
has no name, avatar, or bio, and the page edits only `email` and `password`. That
argues for "Your account", which is what the prototype first used. `d9d2e315`
renamed the header link and this page to "Profile settings" as a recorded
information-architecture decision, and the account menu, the settings scopes, and
the feature specs all bind to it. Renaming back in one page would put the page
at odds with the IA decision for a copy improvement. The heading keeps its
promise a different way: the subtitle names what is actually here ("Your sign-in
address, password, and access for North Coast Transit"), and the record of who
you are moved to the aside rather than above the forms.

*Rejected:* "Your account" (honest, but contradicts a recorded IA decision);
"Account settings" (which `d9d2e315` deliberately moved away from);
"Sign-in and access" (accurate, but the H1 would then restate the two card
headings).

**The account record is an aside, not a header.** Roles with their
`Authorization.Roles` descriptions, confirmation state, and account created all
come from data the schema already has and the layout already assigns
(`user_roles`), and none of it is editable here. Putting it above the forms would
spend the first screen on facts a reader came to this page to change.

## Where the implementation diverges from the prototype

`tmp/redesign/profile-page.html` is the design; these are the places the app is
not identical to it, and why. Measured side by side at 1440x900, the two agree
on the aside width (320px), the `h1` family (Gabarito), `h2` size (18px), input
height (44px) and input radius (6px).

- **`h1` is 28px, not the prototype's 36px.** The prototype used the design
  system's `.title` scale; the app follows the `#blocks-page` precedent at
  28px/600 so two design-system pages do not disagree about a page heading.
- **Role badges carry the canonical names** — "Pathways Studio Editor",
  "Pathways Studio Admin" — where the prototype abbreviated them to "Editor" and
  "Organization admin". `Authorization.Roles` is the app's own vocabulary and
  the prose beside each badge is its `description` verbatim, so an abbreviation
  would be the only part that could drift.
- **Email outcomes are flashes, not persistent panels.** The prototype rendered
  the sent/failed states as cards, because a standalone HTML file has no layout
  flash group. `Layouts.app` already flashes, so the app uses the flash and says
  both halves in it: that the link is what completes the change, and which
  address stays live until then.
- **Card width differs** (936px vs the prototype's 832px) purely because the
  app's shell uses `max-w-7xl` with its own gutters where the prototype shell
  used `max-w-[1280px]`. Not a page-level decision.
- **The prototype's state switcher is prototype-only** and has no counterpart
  here; the states it modelled are covered by tests instead.

## Deliberately not changed

`--color-primary` is still daisyUI app-wide, exactly as on the routes page. The
magenta here arrives only through the `#account-page` scope.

No `Accounts` or context behaviour changed. In particular the page does **not**
persist a proposed address or mark a change as pending, because the app cannot:
the new address exists only inside an emailed token, so there is nothing to read
back. The honest design is the copy above, not an invented pending state.

The DS's own `.form-error-summary` colours (`#c02c47`/`#fff1f3`/`#8d1930`) are
not tokens in `theme.css`, so the summary is built from the app's existing
`--color-error-bg`/`-fg`/`-line` triple (6.68:1 for text, 3.88:1 for the
boundary) rather than introducing raw hex. Reconciling the DS's summary colours
with the app's error triple is an open item for whoever owns `theme.css`.
