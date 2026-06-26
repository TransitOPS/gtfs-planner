# Email Templates Agent Doc

Source target: `lib-gtfs-planner-web-templates`
Scope: Stores HEEx email templates for account confirmation, password reset, invitations, and email-change instructions.
Deep analysis: [`docs/specops/analysis/lib-gtfs-planner-web-templates.md`](../analysis/lib-gtfs-planner-web-templates.md)
Freshness: `source_hash=null`, `last_synthesized=null`

## Use When
- Removing or consolidating dead email template code.
- Refactoring email rendering away from inline string heredocs in `UserNotifier`.
- Upgrading Phoenix past 1.6 (deprecated `Phoenix.View` will break `EmailTemplates`).
- Adding multipart (text+HTML) email support.
- Addressing the PII logging concern in `UserNotifier`.

## Read First
- `lib/gtfs_planner_web/templates/` — four HEEx templates (~12 lines each), all dead code.
- `lib/gtfs_planner_web/email_templates.ex` — deprecated `use Phoenix.View` wrapper, zero callers.
- `lib/gtfs_planner/accounts/user_notifier.ex` — active email delivery (inline string heredocs, HTML only, no text part).

## Interfaces

### Dead: `GtfsPlannerWeb.EmailTemplates` (Phoenix.View, zero callers)
| Template file | Auto-generated function | Assigns |
|---|---|---|
| `confirmation_instructions.html.heex` | `confirmation_instructions_html/1` | `user`, `url` |
| `reset_password_instructions.html.heex` | `reset_password_instructions_html/1` | `user`, `url` |
| `update_email_instructions.html.heex` | `update_email_instructions_html/1` | `user`, `url` |
| `user_invite.html.heex` | `user_invite_html/1` | `user`, `url` |

Assigns contract:
- `@user` — struct/map with `.email` string (e.g., `GtfsPlanner.Accounts.User`)
- `@url` — plain string URL (typically a Phoenix verified route with signed token)

### Active: `GtfsPlanner.Accounts.UserNotifier`
All email delivery flows through `UserNotifier.deliver_*/2` (confirmation, reset, invite, update-email). These generate HTML bodies via private `*_html/2` helpers using raw `#{}` interpolation (no HEEx, no escaping, no text part). Callers in `Accounts` (accounts.ex) generate tokens and URLs, then invoke `UserNotifier`.

Call chain (all production paths):
```
LiveView events → Accounts.deliver_user_* → UserNotifier.deliver_* → Mailer.deliver → Swoosh
```

Callers: `user_confirmation_live.ex:67`, `user_settings_live.ex:198`, `user_forgot_password_live.ex:54`, `admin/users_live.ex:186,222`, `admin/organizations_live.ex:167,287`, `manage_users_live.ex:148,187`.

### Dead: `GtfsPlanner.Accounts.Emails.*`
- `EmailConfirmationEmail` — full HTML+CSS+text, unused
- `ResetPasswordEmail` — full HTML+CSS+text, unused
- `UserInviteEmail` — full HTML+CSS+text, unused
- No `UpdateEmailEmail` module exists (missing richer replacement for email-change flow)

## Rules & Invariants
- All four templates follow identical structure: greeting `<p>`, instruction `<p>`, `<a>` CTA link, fallback notice `<p>`.
- No conditionals, no iteration, no `phx-*` attributes — pure presentation.
- HEEx auto-escapes `{@user.email}` and `{@url}` → XSS-safe. Active `UserNotifier` does **not** escape (raw `#{}`).
- Inconsistent greeting style across template sets: HEEx and UserNotifier use `"Hi"`/`"Hello"` + email; unused `emails/` modules use generic `"Hello"`.
- `UserNotifier` has no error handling (no try/rescue, ignores `Mailer.deliver` return tuples).
- Callers in `Accounts` also ignore delivery return values (`accounts.ex:362,495`).

## State, I/O & Side Effects
- **HEEx templates**: Stateless pure functions (assigns in → string out). Compile-time only.
- **EmailTemplates module**: Stateless. No processes, no ETS, no socket, no DB.
- **UserNotifier** (active): Reads `Application.get_env(:gtfs_planner, :mail_domain)` from config, calls `Mailer.deliver()` → Swoosh → SMTP/API.
- **PII log**: `UserNotifier.deliver_user_invite/2` logs the full invite URL (containing signed token) at `user_notifier.ex:84`: `Logger.info("User invite for #{user.email}: #{url}")`.

## Failure Modes
| Failure | Where | Effect |
|---|---|---|
| Missing `@user` or `@url` assign | HEEx templates (if called) | `KeyError` at runtime |
| `@user` lacks `.email` key | HEEx templates (if called) | `KeyError` at runtime |
| Phoenix.View removal | `EmailTemplates` (compile time) | Compilation failure on Phoenix ≥1.7 |
| Email delivery failure | `Mailer.deliver()` | Return value ignored; silent failure |
| PII in production logs | `user_notifier.ex:84` | Leaks signed invite URLs + emails |

## Change Checklist
- [ ] If removing HEEx templates: delete `lib/gtfs_planner_web/templates/*.heex` and `lib/gtfs_planner_web/email_templates.ex`.
- [ ] If upgrading Phoenix ≥1.7: `EmailTemplates` must be removed first (dead code that will break compile).
- [ ] If refactoring `UserNotifier` to use templates: ensure HTML escaping, text part parity, and remove inline heredocs.
- [ ] If wiring up `emails/` modules: decide canonical greeting style, add `UpdateEmailEmail`, and update all callers.
- [ ] If addressing PII logging: remove or sanitize the Logger.info line at `user_notifier.ex:84`.
- [ ] If adding tests: no test coverage exists for email templates, UserNotifier, or emails/ modules. Only indirect token-creation assertions in `accounts_test.exs`.

## Escalate To Deep Analysis
- Full template file listings with line-level evidence → `docs/specops/analysis/lib-gtfs-planner-web-templates.md`
- Exhaustive caller table (file+line for every `Accounts.deliver_user_*` invocation)
- Detailed comparison matrix of all three email implementations (HEEx, UserNotifier, emails/)
- Edge cases: HTML fragment vs full document, nil user handling, missing text part, template precedence ambiguity
- Open questions on dead code disposition and canonical email pattern
