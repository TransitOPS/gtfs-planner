# Step 2 Learning — Add password context contracts

## Outcome
Success. Added `apply_user_password/3` (non-persisting preflight) and changed `update_user_password/3` to capture and return expired token structs atomically within a single `Ecto.Multi` transaction.

## Changed Files
- `lib/gtfs_planner/accounts.ex` — added `apply_user_password/3`; reworked `update_user_password/3` to `Ecto.Multi.run` then `Ecto.Multi.delete_all` the same IDs, returning `{:ok, {user, tokens}}`
- `lib/gtfs_planner_web/live/user_settings_live.ex` — updated caller destructuring from `{:ok, user}` to `{:ok, {user, _tokens}}`
- `test/gtfs_planner/accounts_test.exs` — added `apply_user_password/3` describe block (3 tests), updated existing `update_user_password/3` tests for new return tuple, added persistence-integrity and cross-context token-capture tests, added `insert_email_token/2` helper

## Risk Audit Summary

### persistence-integrity
- Preflight (`apply_user_password/3`) makes zero database writes — verified by snapshotting `hashed_password` and token count before/after.
- Failed `update_user_password/3` (wrong `current_password`) preserves the stored hash and all existing token rows — verified.
- Successful `update_user_password/3` captures token structs via `Ecto.Multi.run` *before* `Ecto.Multi.delete_all` in the same transaction, then returns the exact captured set.

### concurrency
- Token capture (`:tokens` step) and deletion (`:deleted` step) share one `Repo.transaction()`. If validation fails, `Ecto.Multi` short-circuits before either step runs. If the update runs, both capture and delete happen atomically — no window for phantom tokens.

### cross-step-contract
- Reuses `User.password_changeset/2`, `User.validate_current_password/3`, and `Ecto.Changeset.apply_action/2` — no reimplementation.
- Caller (`UserSettingsLive`) updated to destructure `{:ok, {user, _tokens}}`.

### security-boundary
- Old password fails after successful update (test assertion: `get_user_by_email_and_password(user.email, valid_user_password()) == nil` preserved).
- New password works after update.

## Notable Decisions
- Used `assert returned_ids != []` over `assert length(returned_ids) > 0` per Credo strict `length/1` warning.
