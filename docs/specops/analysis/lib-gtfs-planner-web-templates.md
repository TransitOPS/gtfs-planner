# SpecOps Analysis: Email Templates

**Target:** `lib-gtfs-planner-web-templates`
**Structural unit:** `lib/gtfs_planner_web/templates`
**Source hash:** `sha256:aea42c4ab6d2a5393adfd9fb64359dec50f16a415b42c33d3c0111d626bd7016`
**Analysis date:** 2026-06-26

---

## 1. Purpose & Responsibilities

This structural unit contains HEEx email templates intended for user-facing authentication emails. The templates provide HTML email body content for four email types:

1. **Account confirmation** — `confirmation_instructions.html.heex` — Body for the "confirm your account email" message, containing a user greeting, instructional text, a clickable confirmation link, and a fallback notice.
2. **Password reset** — `reset_password_instructions.html.heex` — Body for the "reset your password" message, with greeting, instructions, a clickable reset link, and a fallback notice.
3. **Email change** — `update_email_instructions.html.heex` — Body for the "change your email" message, with greeting, instructions, a clickable change-email link, and a fallback notice.
4. **User invitation** — `user_invite.html.heex` — Body for the "you have been invited" message, with greeting, invitation text, a clickable password-set link, and a fallback notice.

The templates are loaded via `GtfsPlannerWeb.EmailTemplates`, a dead module created with `use Phoenix.View` (deprecated pattern). **None of these templates or the `EmailTemplates` module are referenced by any other module in the codebase.** The templates have been superseded twice:
- First by `GtfsPlanner.Accounts.UserNotifier`, which generates HTML email bodies via inline string interpolation in private helper functions (HTML-only, no text part).
- Then by `GtfsPlanner.Accounts.Emails.*` modules (`EmailConfirmationEmail`, `ResetPasswordEmail`, `UserInviteEmail`), which generate full multipart HTML+text emails with CSS styling — but these too are unreferenced dead code.

Only `UserNotifier` is currently wired and in production use. The HEEx templates in this structural unit are dead code.

### Evidence

- `lib/gtfs_planner_web/templates/confirmation_instructions.html.heex:1-12` — Confirmation template with `@user.email` and `@url` assigns
- `lib/gtfs_planner_web/templates/reset_password_instructions.html.heex:1-12` — Reset password template
- `lib/gtfs_planner_web/templates/update_email_instructions.html.heex:1-12` — Email change template
- `lib/gtfs_planner_web/templates/user_invite.html.heex:1-12` — User invite template
- `lib/gtfs_planner_web/email_templates.ex:1-3` — `EmailTemplates` module using deprecated `Phoenix.View`
- `lib/gtfs_planner/accounts/user_notifier.ex:1-165` — Active email sender (inline string HTML, no HEEx templates)
- `lib/gtfs_planner/accounts/emails/email_confirmation_email.ex:1-131` — Unused replacement email module
- `lib/gtfs_planner/accounts/emails/reset_password_email.ex:1-131` — Unused replacement email module
- `lib/gtfs_planner/accounts/emails/user_invite_email.ex:1-131` — Unused replacement email module

---

## 2. Public Interfaces & Entry Points

### 2.1 GtfsPlannerWeb.EmailTemplates

A `Phoenix.View` module with root at `lib/gtfs_planner_web/templates`. Phoenix.View automatically exposes one render function per template file, deriving the function name from the filename:

| Template File (stem) | Effective Function | Assigns |
|-----------------------|-------------------|---------|
| `confirmation_instructions` | `GtfsPlannerWeb.EmailTemplates.confirmation_instructions_html/1` | `user`, `url` |
| `reset_password_instructions` | `GtfsPlannerWeb.EmailTemplates.reset_password_instructions_html/1` | `user`, `url` |
| `update_email_instructions` | `GtfsPlannerWeb.EmailTemplates.update_email_instructions_html/1` | `user`, `url` |
| `user_invite` | `GtfsPlannerWeb.EmailTemplates.user_invite_html/1` | `user`, `url` |

**All four functions are unreferenced** — zero callers exist in the codebase.

### 2.2 Template Assigns

Each template expects two assigns:

- **`@user`** — A user struct or map with an `.email` field (string). Rendered in the greeting line.
- **`@url`** — A string URL for the call-to-action link. Rendered as the `href` attribute of the anchor tag.

### 2.3 Template Structure

All four templates follow an identical structural pattern:

1. `<p>` — Greeting, `Hi {@user.email}` or `Hello {@user.email}`
2. `<p>` — Instructional sentence describing the action
3. `<p>` — `<a href={@url}>` — Call-to-action link button
4. `<p>` — Fallback notice ("If you didn't request this...")

### Evidence

- `lib/gtfs_planner_web/email_templates.ex:1-3` — `EmailTemplates` uses `Phoenix.View`, which auto-generates render functions
- `lib/gtfs_planner_web/templates/confirmation_instructions.html.heex:1-12` — Template references `@user.email` and `@url`
- No `.ex` file contains `EmailTemplates.` or `Module.concat.*EmailTemplates` — confirming zero callers

---

## 3. Data Models & Structures

### 3.1 Template Assign (Input)

```
%{
  user: %{email: String.t()},
  url: String.t()
}
```

- **`user`**: Any struct or map that implements the `Access` behaviour and has an `:email` key. In practice, this would be a `GtfsPlanner.Accounts.User` Ecto schema struct.
- **`url`**: A plain string, typically a Phoenix verified route URL containing a signed token (e.g., `https://hostname/users/confirm/abc123`).

### 3.2 Template Output

Each template renders to an HTML fragment (no `<html>`, `<head>`, or `<body>` tags). The output is a sequence of `<p>` elements containing plain text and a single `<a>` element. There is no CSS styling, no DOCTYPE, and no `<meta>` tags.

### 3.3 Comparison with Active Email Implementations

| Aspect | HEEx Templates (dead) | UserNotifier (active) | emails/ modules (dead) |
|--------|----------------------|-----------------------|------------------------|
| HTML body | HEEx fragment | Inline string heredoc | Full HTML document with CSS |
| Text body | None | None | Plain text heredoc |
| User email in greeting | `{@user.email}` (HEEx) | `#{user.email}` (string interp) | Not shown (generic "Hello") |
| Expiry notice | None | None | Yes (24h / 7 days) |
| Copyright footer | None | None | Yes |
| CSS styling | None | None | Full embedded `<style>` |

### Evidence

- `lib/gtfs_planner_web/templates/confirmation_instructions.html.heex:1-12` — Pattern used across all templates
- `lib/gtfs_planner/accounts/user_notifier.ex:98-113` — UserNotifier inline equivalent for confirmation
- `lib/gtfs_planner/accounts/emails/email_confirmation_email.ex:33-112` — Full HTML email template (unused)

---

## 4. Behavioral Contracts

### 4.1 Template Rendering (when called)

When `EmailTemplates.confirmation_instructions_html(%{user: user, url: url})` is invoked (hypothetically):

1. HEEx engine evaluates `{@user.email}` → renders user's email address, HTML-escaped
2. HEEx engine evaluates `{@url}` → renders the URL as the `<a>` href, HTML-escaped
3. All static text is rendered verbatim
4. Output is an HTML fragment string

### 4.2 Greeting Pattern Differences

Notable inconsistency in greeting text across the two dead template sets:

| Template | HEEx greeting | UserNotifier greeting |
|----------|--------------|----------------------|
| confirmation_instructions | `Hello {@user.email}` | `Hello #{user.email}` |
| reset_password_instructions | `Hello {@user.email}` | `Hello #{user.email}` |
| update_email_instructions | `Hi {@user.email}` | `Hi #{user.email}` |
| user_invite | `Hi {@user.email}` | `Hi #{user.email}` |

The `emails/` modules omit user email from the greeting entirely (use generic "Hello").

### 4.3 No Current Behavioral Contracts

Since the templates and `EmailTemplates` module are unreferenced, there are no active behavioral contracts. The templates cannot be triggered by any existing code path.

### Evidence

- `lib/gtfs_planner_web/templates/confirmation_instructions.html.heex:2` — `Hello {@user.email}`
- `lib/gtfs_planner_web/templates/update_email_instructions.html.heex:2` — `Hi {@user.email}`
- `lib/gtfs_planner/accounts/user_notifier.ex:100` — `Hello #{user.email}` (inline equivalent)
- `lib/gtfs_planner/accounts/user_notifier.ex:117` — `Hi #{user.email}` (inline equivalent)

---

## 4A. Decision Logic, Business Rules & Policy Surface

There is no decision logic or business rules encoded in these templates. They are pure presentation templates:

- No conditionals (`if`, `cond`, `case`) in any template
- No iteration (`for`, `each`)
- No event handling (no `phx-*` attributes)
- No role-based or permission-based logic
- All user-facing content is static text with two dynamic interpolations (`@user.email` and `@url`)

The business rules governing email delivery (when to send, what URL to include, token generation, token expiry) live entirely in:
- `GtfsPlanner.Accounts` (`accounts.ex:351-362, 395-403, 488-495, 512-516`) — orchestration logic
- `GtfsPlanner.Accounts.UserNotifier` (`user_notifier.ex:20-95`) — email construction and delivery

### Evidence

- Full contents of all four template files — no conditional or iterative logic present
- `lib/gtfs_planner/accounts.ex:492-495` — Token generation and URL construction in Accounts
- `lib/gtfs_planner/accounts/user_notifier.ex:20-30` — Email construction from user + url

---

## 5. State Management

### 5.1 Template State

Templates are stateless. They receive two assigns (`user`, `url`) and produce a string. No LiveView socket, no process state, no cache, no session involvement.

### 5.2 EmailTemplates Module State

`GtfsPlannerWeb.EmailTemplates` is a stateless view module. `use Phoenix.View` sets up compile-time template registration (reads template files at compile time) but maintains no runtime state.

### 5.3 Relationship to Runtime State

The templates do not interact with:
- Ecto repos or database
- Agent/GenServer processes
- ETS tables
- LiveView socket assigns
- Phoenix channel state
- HTTP connection assigns

### Evidence

- `lib/gtfs_planner_web/email_templates.ex:1-3` — Module definition, no stateful constructs
- Template files — Only static HEEx interpolation, no state management

---

## 6. Dependencies

### 6.1 Compile-Time Dependencies

```
GtfsPlannerWeb.EmailTemplates
  └── Phoenix.View (deprecated)
      └── Phoenix.Template (via Phoenix.View)
          └── Phoenix.HTML.Engine (HEEx engine, for .heex extension detection)
```

### 6.2 Runtime Dependencies (theoretical, if templates were called)

Templates depend on:
- **`user` assign** — Must respond to `.email` accessor (dot-notation field access via `{@user.email}` in HEEx). Requires the assign to be a struct or map with atom key `:email`.
- **`url` assign** — Must be a string.

### 6.3 Modules That Use These Templates

**None.** A grep for `EmailTemplates` across the entire codebase returns only the module's own definition. No module imports, aliases, or calls `GtfsPlannerWeb.EmailTemplates`.

### 6.4 Modules That Duplicate These Templates

- `GtfsPlanner.Accounts.UserNotifier` — Active module with inline HTML string equivalents (same content, different rendering approach)
- `GtfsPlanner.Accounts.Emails.EmailConfirmationEmail` — Unused richer replacement
- `GtfsPlanner.Accounts.Emails.ResetPasswordEmail` — Unused richer replacement
- `GtfsPlanner.Accounts.Emails.UserInviteEmail` — Unused richer replacement

### Evidence

- `lib/gtfs_planner_web/email_templates.ex:2` — `use Phoenix.View`
- `lib/gtfs_planner/accounts/user_notifier.ex:98-113,115-129,132-146,149-163` — Inline equivalents
- `lib/gtfs_planner/accounts/emails/email_confirmation_email.ex:1-131` — Richer replacement (unused)
- `lib/gtfs_planner/mailer.ex:1-3` — Swoosh Mailer (shared by UserNotifier and emails/ modules)

---

## 7. Side Effects & I/O

### 7.1 Template Rendering

Template rendering is a pure function: same inputs → same outputs. It reads no files at runtime, makes no network calls, writes nothing. HEEx template compilation happens at compile time and produces in-memory function clauses.

### 7.2 EmailTemplates Module

No side effects. The module only contains a `use Phoenix.View` declaration. It starts no processes, opens no connections, and writes no files.

### 7.3 Compare: UserNotifier Side Effects

The actual email subsystem (`UserNotifier`) performs I/O:
- Reads `Application.get_env(:gtfs_planner, :mail_domain)` for SMTP from address
- Calls `Mailer.deliver()` → Swoosh → SMTP/API delivery
- Logs invite URLs via `Logger.info/1` (potential PII leak of invite URL at `user_notifier.ex:84`)

### Evidence

- `lib/gtfs_planner/accounts/user_notifier.ex:22-29` — mail_domain env read and Mailer.deliver call
- `lib/gtfs_planner/accounts/user_notifier.ex:84` — Logger.info with invite URL
- `lib/gtfs_planner/mailer.ex:2` — `use Swoosh.Mailer, otp_app: :gtfs_planner`
- `config/runtime.exs:112` — `mail_domain` config from `MAIL_DOMAIN` env var, default `"gtfsplanner.com"`

---

## 8. Error Handling & Failure Modes

### 8.1 Template Rendering Errors

If the templates were called, potential failure modes:

| Failure | Cause | Effect |
|---------|-------|--------|
| Missing `@user` assign | Caller omits `:user` key | `KeyError` at runtime (HEEx cannot resolve `@user`) |
| Missing `@url` assign | Caller omits `:url` key | `KeyError` at runtime (HEEx cannot resolve `@url`) |
| `@user` has no `.email` key | Wrong struct type passed | `KeyError` at runtime |
| `nil` user | User is nil | `{nil}` rendered as link text, no error raised |

### 8.2 EmailTemplates Module Errors

- **Compile-time**: If a template file has invalid HEEx syntax, `GtfsPlannerWeb.EmailTemplates` will fail to compile (raising `Phoenix.Template.CompileError`).
- **Runtime**: Since the module is never called, no runtime errors can occur from these templates.

### 8.3 Actual Error Handling (UserNotifier)

The active `UserNotifier` module has no error handling:
- No try/rescue/with blocks
- No pattern matching on `Mailer.deliver()` return values
- Callers in `Accounts` (`accounts.ex:495`) ignore the return value: `UserNotifier.deliver_user_invite(user, invite_url_fun.(encoded_token))` — the `{:ok, _}` or `{:error, _}` tuple is not pattern-matched

### Evidence

- `lib/gtfs_planner_web/templates/*.heex` — Template assign expectations
- `lib/gtfs_planner/accounts/user_notifier.ex:20-95` — No error handling in delivery functions
- `lib/gtfs_planner/accounts.ex:495` — Return value of `deliver_user_invite` not checked
- `lib/gtfs_planner/accounts.ex:362` — Return value of `deliver_confirmation_instructions` not checked

---

## 9. Integration Points & Data Flow

### 9.1 Intended Integration Pattern (not operational)

The intended pattern appears to be:

```
Accounts context (accounts.ex)
  → generates token + URL
  → calls EmailTemplates.*_html(user, url)
  → gets HTML string
  → passes to Swoosh.Mailer for delivery
```

### 9.2 Actual Integration Pattern (UserNotifier)

```
Accounts context (accounts.ex)
  → generates token + URL via UserToken.build_email_token/2
  → calls UserNotifier.deliver_*(user, url)
  → UserNotifier generates HTML via private *_html helper (inline heredoc)
  → UserNotifier constructs Swoosh.Email struct
  → UserNotifier calls Mailer.deliver()
  → Mailer → Swoosh → configured adapter (SMTP/API)
```

### 9.3 Call Chain

```
LiveView event handlers
  → GtfsPlanner.Accounts.deliver_user_confirmation_instructions/2
  → GtfsPlanner.Accounts.deliver_user_reset_password_instructions/2
  → GtfsPlanner.Accounts.deliver_user_invite/2
  → GtfsPlanner.Accounts.resend_user_invite/2 (calls deliver_user_invite/2)
  → GtfsPlanner.Accounts.deliver_user_update_email_instructions/2
    → GtfsPlanner.Accounts.UserNotifier.deliver_* /2
      → GtfsPlanner.Mailer.deliver/1
```

All paths bypass `EmailTemplates` and the HEEx templates entirely.

### 9.4 Callers of Email-Template-Equivalent Functionality

| Caller File | Line | Function Called |
|-------------|------|----------------|
| `lib/gtfs_planner_web/live/user_confirmation_live.ex` | 67 | `Accounts.deliver_user_confirmation_instructions` |
| `lib/gtfs_planner_web/live/user_settings_live.ex` | 198 | `Accounts.deliver_user_confirmation_instructions` |
| `lib/gtfs_planner_web/live/user_forgot_password_live.ex` | 54 | `Accounts.deliver_user_reset_password_instructions` |
| `lib/gtfs_planner_web/live/admin/users_live.ex` | 186, 222 | `Accounts.deliver_user_invite` |
| `lib/gtfs_planner_web/live/admin/organizations_live.ex` | 167, 287 | `Accounts.deliver_user_invite` / `Accounts.resend_user_invite` |
| `lib/gtfs_planner_web/live/manage_users_live.ex` | 148, 187 | `Accounts.deliver_user_invite` / `Accounts.resend_user_invite` |

### Evidence

- `lib/gtfs_planner/accounts.ex:351-362` — `deliver_user_confirmation_instructions` calls `UserNotifier`
- `lib/gtfs_planner/accounts.ex:395-403` — `deliver_user_reset_password_instructions` calls `UserNotifier`
- `lib/gtfs_planner/accounts.ex:488-495` — `deliver_user_invite` calls `UserNotifier`
- `lib/gtfs_planner/accounts.ex:194-200` — `deliver_user_update_email_instructions` calls `UserNotifier`
- `lib/gtfs_planner/accounts/user_notifier.ex:20-95` — All delivery functions in UserNotifier

---

## 10. Edge Cases & Implicit Behavior

### 10.1 HTML Escaping

- HEEx templates automatically HTML-escape `{@user.email}` and `{@url}` interpolations. This prevents XSS if an email or URL contains HTML special characters (`<`, `>`, `&`, etc.).
- The active `UserNotifier` uses raw Elixir string interpolation (`#{user.email}`, `#{url}`) without explicit HTML escaping, though email addresses and Phoenix-generated URLs are unlikely to contain HTML special characters.

### 10.2 URL-Only Content

The templates are plain HTML fragments. No `<html>`, `<body>`, or `<head>` tags. Email clients that require a full HTML document may display these incorrectly if used without a wrapping layout. The active `UserNotifier` has the same limitation (sends HTML fragments via `html_body/1`).

### 10.3 Missing Email Types

The `emails/` directory contains only three modules (confirmation, reset password, invite). There is no `UpdateEmailEmail` module — the email-change flow has no richer replacement. This matches the HEEx templates which do include `update_email_instructions`.

### 10.4 No Text Part

Neither the HEEx templates nor the active `UserNotifier` provide a `text_body` alternative. Email clients that prefer plain text will show the raw HTML instead. Only the unused `emails/` modules include both `html_body` and `text_body`.

### 10.5 Template Precedence Ambiguity

If someone were to call `EmailTemplates.confirmation_instructions_html/1`, both the HEEx template and `UserNotifier.confirmation_instructions_html/2` (private) would exist simultaneously, with different signatures (1-arity for templates vs 2-arity for UserNotifier). This is not a current problem since `EmailTemplates` is never called, but could cause confusion during future refactoring.

### Evidence

- `lib/gtfs_planner_web/templates/*.heex` — HEEx auto-escaping via `{@x}` syntax
- `lib/gtfs_planner/accounts/user_notifier.ex:98-163` — Inline heredoc with raw `#{}` interpolation
- `lib/gtfs_planner/accounts/emails/email_confirmation_email.ex:27` — `text_body` line present (unused)
- `lib/gtfs_planner/accounts/emails/` — No `update_email_email.ex` file

---

## 11. Open Questions & Ambiguities

### 11.1 Dead Code Disposition

1. **Should the HEEx templates be removed?** They duplicate active code and use the deprecated `Phoenix.View` pattern. Their existence adds confusion — a developer might assume they are the canonical email templates.

2. **Should `EmailTemplates` be removed?** Same as above; it's a dead module with zero callers.

3. **Should the `emails/` modules be wired up?** They offer richer functionality (multipart emails, CSS styling, expiry notices, copyright footers) but are also unused. Are they intended to replace `UserNotifier`? Was this work in progress?

4. **Should `UserNotifier` be refactored to use a proper template system?** Currently it embeds HTML in Elixir string heredocs, which is hard to maintain, not auto-escaped, and lacks text_part support.

### 11.2 Missing Tests

There are **no test files** for:
- `GtfsPlannerWeb.EmailTemplates`
- `GtfsPlanner.Accounts.UserNotifier`
- `GtfsPlanner.Accounts.Emails.EmailConfirmationEmail`
- `GtfsPlanner.Accounts.Emails.ResetPasswordEmail`
- `GtfsPlanner.Accounts.Emails.UserInviteEmail`

Email delivery is tested indirectly through `accounts_test.exs`, which calls `Accounts.deliver_user_*` functions but only verifies token creation, not email content or delivery outcome.

### 11.3 Logger PII Concern

`UserNotifier.deliver_user_invite/2` logs the full invite URL at `user_notifier.ex:84`:
```
Logger.info("User invite for #{user.email}: #{url}")
```
The URL contains a signed token. If logs are persisted or aggregated, this leaks sensitive account-activation URLs along with user email addresses.

### 11.4 Phoenix.View Deprecation

`Phoenix.View` is deprecated as of Phoenix 1.7 and was removed from Phoenix in later versions. If the project upgrades Phoenix, `EmailTemplates` will fail to compile. Since `EmailTemplates` is dead code, this is a non-issue for runtime, but a compile-time breakage will still occur.

### 11.5 Inconsistency Between Template Sets

| Concern | HEEx templates | UserNotifier | emails/ modules |
|---------|---------------|-------------|-----------------|
| Greeting style | `Hi` or `Hello` + email | `Hi` or `Hello` + email | Generic `Hello` (no email) |
| HTML document structure | Fragment only | Fragment only | Full document with CSS |
| Text part | None | None | Yes |
| Expiry notice | None | None | Yes |
| Copyright | None | None | Yes |
| Status | Dead | Active | Dead |

There is no documented decision on which pattern should be canonical.

### Evidence

- `lib/gtfs_planner/accounts/user_notifier.ex:84` — Logger.info with PII
- `lib/gtfs_planner_web/email_templates.ex:2` — Deprecated `use Phoenix.View`
- `test/gtfs_planner/accounts_test.exs` — No direct email content assertions
- No test files matching `*notifier*` or `*email_template*` found
