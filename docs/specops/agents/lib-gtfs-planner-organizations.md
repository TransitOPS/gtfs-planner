# Organizations Context Agent Doc

Source target: `lib-gtfs-planner-organizations`
Scope: Manages tenant organizations, API keys, membership associations, default version creation, and organization PubSub notifications.
Deep analysis: [`../analysis/lib-gtfs-planner-organizations.md`](../analysis/lib-gtfs-planner-organizations.md)
Freshness: `source_hash=sha256:f66f2a761fd7b15dae9c3a74d71808cce0603647b03f2ab7a7eab05e75a91612`, `last_synthesized=2026-06-26`

## Use When
- Adding, modifying, or removing organization CRUD operations.
- Changing API key lifecycle (creation, verification, hashing, serialization format).
- Adjusting membership rules, roles, activation/deactivation, or user-org associations.
- Touching `AssignApiOrganization` plug or organization-based auth gating.
- Working on admin org management LiveViews or API auth pipelines that resolve org context.

## Read First
- `lib/gtfs_planner/organizations.ex` — the context module; all public functions, PubSub broadcasting, and transaction scoping (490 lines).
- `lib/gtfs_planner/organizations/organization.ex` — Organization schema, changeset, alias normalization (59 lines).
- `lib/gtfs_planner/organizations/api_key.ex` — ApiKey schema, token serialization/hashing/verification, constants (113 lines).
- `lib/gtfs_planner/accounts/user_org_membership.ex` — membership schema with role validation against canonical set (64 lines).
- `lib/gtfs_planner_web/plugs/assign_api_organization.ex` — API org resolution plug (118 lines).

## Interfaces
- **Org CRUD**: `list_organizations/0`, `get_organization/1`, `get_organization!/1`, `get_organization_by_alias/1`, `create_organization/1`, `update_organization/2`, `delete_organization/1`, `change_organization/2` (`organizations.ex:22-139`).
- **API keys**: `list_api_keys/1`, `get_api_key!/1`, `get_api_key_by_token/1`, `create_api_key/2`, `update_api_key/2`, `delete_api_key/1`, `change_api_key/2` (`organizations.ex:141-274`).
  - `create_api_key/2` returns `{:ok, {api_key, token}}` — the plaintext token is only available at creation.
  - `get_api_key_by_token/1` returns `{:ok, %ApiKey{}}` or `{:error, :invalid}` via constant-time comparison.
- **Memberships**: `add_user_to_organization/3`, `remove_user_from_organization/2`, `update_user_roles/3`, `deactivate_user_in_organization/2`, `activate_user_in_organization/2`, `list_organizations_for_user/1`, `list_users_in_organization/1`, `user_deactivated_in_organization?/2` (`organizations.ex:276-448`).
- **Cross-context**: calls `GtfsPlanner.Accounts.delete_user_sessions/1` on deactivation; calls `GtfsPlanner.Versions.create_default_version/1` during org creation.

## Rules & Invariants
- **Alias normalization** (`organization.ex:43-58`): trim → downcase → strip non-`[a-z0-9\s-]` → replace whitespace runs with single `-`. Examples: `"  My Test Org!@#  "` → `"my-test-org"`.
- **Alias uniqueness** is enforced by both `unique_constraint(:alias)` and a DB unique index.
- **Token format** is immutable: `"GtfsPlanner.V{version}.{base32(id || secret)}"`. `@secret_size`=32 bytes, `@hash_algorithm`=`:sha512`, `@prefix`=`"GtfsPlanner"`. Changing these constants breaks all existing tokens.
- **Hash algorithm**: SHA-512 of `"#{api_key_id}:#{version}:#{organization_id}:#{secret}"`.
- **Verification**: decode token → extract UUID (first 16 bytes) and secret (last 32 bytes) → DB lookup by UUID → recompute hash → `Plug.Crypto.secure_compare/2`.
- **ApiKey.id** has `autogenerate: false` — the ID is generated in `build_hashed_token/2` before insert, tying the token payload to the DB record ID.
- **Org creation is transactional**: both org insert and default version creation (`Versions.create_default_version/1` seeding "First Version") run in `Repo.transaction`; either failure rolls back the other.
- **Membership uniqueness**: DB unique index on `[:user_id, :organization_id]` — no user can have multiple memberships per org.
- **Canonical roles** (validated by `Roles.valid?/1`): `administrator`, `pathways_studio_admin`, `pathways_studio_editor`.
- **Empty/nil roles** are valid (early return in `validate_roles/1`).
- **Deactivation** sets `deactivated_at` to `DateTime.utc_now() |> DateTime.truncate(:second)` AND calls `Accounts.delete_user_sessions(user_id)` to invalidate all sessions.
- **Activation** sets `deactivated_at` back to `nil`.
- **`user_deactivated_in_organization?/2`** returns `true` only when `deactivated_at` is a `DateTime` struct.

## State, I/O & Side Effects
- **Database**: owns `organizations`, `api_keys` tables; reads/owns `user_org_memberships` (schema in Accounts but membership mutations go through this context).
- **PubSub**: all mutating operations broadcast on `"organizations"` topic (topic: `{:organizations, ...}`, `{:api_keys, ...}`, `{:memberships, ...}`). Broadcasts are fire-and-forget; no known in-codebase subscribers.
  - Events only fire on `{:ok, result}`; errors (`{:error, ...}`) are returned directly with no broadcast.
- **Transactions**: `create_organization/1` wraps org insert + default version creation in a transaction (`organizations.ex:83-93`). Other mutations are single-repo operations (no transaction).
- **Session invalidation**: `deactivate_user_in_organization/2` side-effect calls `Accounts.delete_user_sessions(user_id)`.
- **Plug context** (`AssignApiOrganization`): requires `:current_user` on conn; resolves org from `X-Organization-Id` header; assigns `:current_organization_id`.
- **Change tracking**: `change_organization/2` and `change_api_key/2` return tracking changesets, no DB writes.
- **No caching or GenServer state** — all reads go directly to DB.

## Failure Modes
- **Create org**: returns `{:error, %Changeset{}}` on validation failure or default version creation failure (transaction rollback).
- **Create API key**: returns `{:error, %Changeset{}}` on missing description or FK violation.
- **Token verification**: `{:error, :invalid}` for any mismatch — malformed token, wrong prefix, bad base32, missing record, hash mismatch. **Never** reveals which check failed.
- **Membership operations**: `remove_user_from_organization/2`, `update_user_roles/3`, and activate/deactivate return `{:error, :not_found}` (not changesets) when membership doesn't exist.
- **Duplicate membership**: `add_user_to_organization/3` returns `{:error, %Changeset{}}` on `[:user_id, :organization_id]` uniqueness violation.
- **AssignApiOrganization plug errors**:
  - No `:current_user` → 401 `unauthorized`
  - Invalid UUID header → 400 `bad_request`
  - User not in specified org → 403 `forbidden`
  - 0 memberships → 403 `no_organization`
  - 2+ memberships, no header → 403 `organization_required` (body includes `available_organization_ids`)
  - Deactivated sole membership → 403

## Change Checklist
- [ ] Token format constant changes? Will break all existing API keys. Coordinate with key rotation.
- [ ] New organization fields? Update `Organization.changeset/2`, migrations, and any consumers reading org structs.
- [ ] Changing membership rules? Verify `user_deactivated_in_organization?/2`, plug auth gating, and session invalidation side-effects still hold.
- [ ] New roles? Add to canonical set in `Roles.valid?/1`; role validation in `UserOrgMembership` will auto-enforce.
- [ ] Adding new mutating operations? Add `broadcast/2` call on success path and a PubSub event entry.
- [ ] Changing org creation flow? Preserve the transaction wrapping both org insert and `Versions.create_default_version/1`.
- [ ] Run `mix test test/gtfs_planner/organizations_test.exs` plus plug/LiveView tests after changes.
- [ ] Untested gap: `deactivate_user_in_organization/2`, `activate_user_in_organization/2`, and `user_deactivated_in_organization?/2` lack direct unit tests (tested indirectly via LiveView).

## Escalate To Deep Analysis
- Full domain model field tables, canonical role definitions, and consumer lists.
- Detailed data-flow sequences for org creation, API key creation/verification, and org resolution.
- Complete PubSub event catalog with payload shapes.
- Migration history and backfill details.
- Comprehensive test inventory with coverage gaps.
- Complete evidence file:line references for every claim.
