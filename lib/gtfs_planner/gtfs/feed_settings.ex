defmodule GtfsPlanner.Gtfs.FeedSettings do
  @moduledoc """
  Scoped reads and editor writes for one version's feed information.

  Every write resolves the actor's *current* active organization membership with the
  `pathways_studio_editor` role and locks the organization-scoped published version row
  before it reads or writes the state it depends on (R10). A feed-info save takes that
  row `FOR SHARE` first and the version's single `feed_info` row `FOR UPDATE` second.
  That is the same version row `GtfsPlanner.Gtfs.Calendars` locks, no other lock
  precedes it (INV-2), and only a published version of the actor's organization can be
  written: an unknown, foreign, unpublished or malformed scope returns `:not_found`.

  Saving feed details is stale-safe (R8). The editor sends back the `updated_at` it
  loaded with the form, the token is compared with the row read under the write lock,
  and a mismatch returns `:stale` without a write. A first save is allowed only with a
  nil token; when a concurrent first insert beats the loser's own load, the unique index
  on `(organization_id, gtfs_version_id)` turns that insert into the same `:stale`
  result instead of a second row or a crash.

  The agency reads report the version's rows, their route counts and the version's
  timezone state, all scoped to the organization and version. Creating an agency
  (`create_agency/2`) is one transaction: it authorizes the actor, takes the published
  version row `FOR UPDATE` (INV-2) before it reads the state it depends on, resolves the
  zone (R2), derives a collision-free ID (R1), runs the first- or second-agency backfill
  (R6), and inserts through the editor changeset (R9). A failed insert rolls the
  backfill back with it, so a refused create leaves the version's agencies, routes and
  fare attributes exactly as they were.

  Updating an agency (`update_agency/4`) is one transaction that authorizes the actor,
  share-locks the published version row, loads the scoped row `FOR UPDATE`, compares the
  `updated_at` token the editor loaded and then writes only the editable fields through
  `Agency.editor_changeset/2`. A token that does not match the row read under the
  lock returns `:stale` with no write, so a save that started before another editor's save
  loses instead of overwriting it (R8).

  A version-wide timezone change is a review and an apply bound by a fingerprint (R3,
  INV-3). `review_timezone_change/2` trims and validates the chosen zone with
  `DisplayClock.valid_zone?/1` (INV-4), share-locks the published version row, and reports
  every agency's current zone and route count together with a token that binds the zone to
  the `{agency row id, agency_timezone}` pairs it observed. `apply_timezone_change/3`
  validates the zone again, takes the version row `FOR UPDATE`, recomputes the token, and
  refuses a mismatch with `:stale_review` before it writes anything. On a match one
  `UPDATE` statement sets `agency_timezone` and `updated_at` for the version's agencies;
  no stop time, frequency or calendar row is read or written (CR-7).

  Deleting an agency is a review and an apply bound by a fingerprint (R7, INV-3).
  `review_agency_deletion/3` refuses the version's last agency, requires a different
  existing receiving agency when the agency has routes, and otherwise reports the routes
  that will move, the fare attributes and attributions that block the deletion, and the
  record-bound translation count. `delete_agency/4` takes the version row `FOR UPDATE`,
  re-reads the same state, and refuses with `:stale_review` unless every reviewed
  condition still holds. On a match one transaction moves the agency's routes to the
  receiving agency, deletes its record-bound translations and deletes the agency, so no
  route can be left naming an agency that no longer exists.

  A route insert resolves its agency under the same version row lock (R4, INV-1).
  `lock_agency_for_reference!/3` share-locks the published version and then returns the
  version's single agency for a blank choice, or the listed agency for a provided choice,
  rolling back `:agency_required` or `:agency_not_found` instead. A route insert that
  calls it inside its own transaction serializes against an agency deletion and cannot
  commit against an agency that no longer exists (AC-26); `Routes.create_editor_route/3`
  gets the same guarantee by resolving the agency under the version's `FOR UPDATE` lock.

  Outside import and test fixtures this module is the application's writer of `agencies`
  and `feed_info` rows and of the agency columns they own (INV-5).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FeedInfo
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"
  @no_attribution_id "(no ID)"

  @type scope :: AuditContext.t()
  @type zone_state :: {:ok, String.t()} | {:unresolved, :missing | :invalid | :conflicting}
  @type agency_row :: %{agency: Agency.t(), route_count: non_neg_integer()}

  @type timezone_review :: %{
          zone: String.t(),
          fingerprint: String.t(),
          agencies: [
            %{
              id: Ecto.UUID.t(),
              agency_id: String.t(),
              agency_name: String.t(),
              from: String.t(),
              route_count: non_neg_integer()
            }
          ]
        }

  @type health :: %{
          agency_count: non_neg_integer(),
          unassigned_routes: non_neg_integer(),
          zone: zone_state()
        }

  @type deletion_review :: %{
          agency: Agency.t(),
          target: Agency.t() | nil,
          fingerprint: String.t(),
          routes: [
            %{
              route_id: String.t(),
              route_short_name: String.t() | nil,
              route_long_name: String.t() | nil
            }
          ],
          blockers: %{fare_ids: [String.t()], attribution_ids: [String.t()]},
          translation_count: non_neg_integer()
        }

  @doc """
  Returns the version's feed info row, or nil when the version has none.

  The read is filtered on the organization and the version and takes no lock.
  """
  @spec get_feed_info(Ecto.UUID.t(), Ecto.UUID.t()) :: FeedInfo.t() | nil
  def get_feed_info(organization_id, gtfs_version_id) do
    from(f in FeedInfo,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  @doc """
  Builds the feed details drawer's changeset for `feed_info`, or for an empty row when
  the caller has none yet.
  """
  @spec change_feed_info(FeedInfo.t() | nil, map()) :: Ecto.Changeset.t()
  def change_feed_info(feed_info, attrs) do
    (feed_info || %FeedInfo{})
    |> FeedInfo.editor_changeset(attrs)
  end

  @doc """
  Lists the version's agencies with their route counts (R5).

  Rows are the scoped rows `Gtfs.list_agencies/2` returns, ordered by `agency_name`, each
  wrapped with the number of routes whose `agency_id` equals that agency's own ID. With
  exactly one agency the version's blank-agency routes — `agency_id` nil or whitespace —
  count toward it as well. The read is filtered on the organization and the version and
  takes no lock.
  """
  @spec list_agencies(Ecto.UUID.t(), Ecto.UUID.t()) :: [agency_row()]
  def list_agencies(organization_id, gtfs_version_id) do
    agencies = Gtfs.list_agencies(organization_id, gtfs_version_id)
    counts = route_counts(organization_id, gtfs_version_id)

    Enum.map(agencies, fn agency ->
      %{agency: agency, route_count: route_count(counts, agencies, agency)}
    end)
  end

  @doc """
  Reports the version's agency count, unassigned routes and timezone state (R5).

  `unassigned_routes` counts the routes the agency list does not account for, so a version
  with no agency reports all of its routes. `zone` is the version zone
  `DisplayClock.resolve_zone/2` resolves, mapped to `{:ok, timezone}` or
  `{:unresolved, :missing | :invalid | :conflicting}` (INV-4); this module holds no
  timezone rule of its own. The read is filtered on the organization and the version and
  takes no lock.
  """
  @spec agency_health(Ecto.UUID.t(), Ecto.UUID.t()) :: health()
  def agency_health(organization_id, gtfs_version_id) do
    agencies = Gtfs.list_agencies(organization_id, gtfs_version_id)
    counts = route_counts(organization_id, gtfs_version_id)

    assigned_routes =
      agencies
      |> Enum.map(&route_count(counts, agencies, &1))
      |> Enum.sum()

    %{
      agency_count: length(agencies),
      unassigned_routes: route_total(counts) - assigned_routes,
      zone: zone_state(organization_id, gtfs_version_id)
    }
  end

  @doc """
  Returns one of the version's agencies by its row UUID, or nil.

  The query filters on the organization, the version and the row ID, so a UUID from
  another organization or another version returns nil. A malformed ID returns nil without
  reaching the database. The read takes no lock.
  """
  @spec get_agency(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: Agency.t() | nil
  def get_agency(organization_id, gtfs_version_id, agency_row_id) do
    case Ecto.UUID.cast(agency_row_id) do
      {:ok, agency_id} -> scoped_agency(organization_id, gtfs_version_id, agency_id)
      :error -> nil
    end
  end

  @doc """
  Builds the agency create/edit drawer's changeset (R9).

  The editable fields and their rules live in
  `GtfsPlanner.Gtfs.Agency.editor_changeset/2`; the row's `organization_id`,
  `gtfs_version_id` and `agency_id` are never cast, so a drawer request cannot move a
  row across the tenant boundary or regenerate its GTFS ID.
  """
  @spec change_agency(Agency.t(), map()) :: Ecto.Changeset.t()
  def change_agency(%Agency{} = agency, attrs) do
    Agency.editor_changeset(agency, attrs)
  end

  @doc """
  Creates one agency in the version, applying the ID, timezone and backfill rules (R1,
  R2, R6, R9) atomically under the published version lock (R10, INV-2).

  `attrs` may use string or atom keys; they are normalized to string keys first. One
  transaction authorizes the actor, locks the published `gtfs_versions` row
  `FOR UPDATE`, loads the version's agencies, resolves the zone, chooses the ID, runs
  the backfill, and inserts the row through the editor changeset:

  - The first agency (no agencies yet) keeps its submitted `agency_timezone`, which the
    editor changeset validates against `DisplayClock.valid_zone?/1`.
  - A later agency ignores any submitted zone and takes `DisplayClock.resolve_zone/2`'s
    resolved zone; a missing, invalid or conflicting version zone returns
    `:timezone_unresolved` without a write.
  - The ID is `Stop.slugify(agency_name)`, or `agency` when that is blank, suffixed
    `_2`, `_3`… until no agency or non-blank `routes`, `fare_attributes` or
    `attributions` reference in the version uses it. With no agencies yet and exactly one
    distinct non-blank route reference, that reference is adopted instead.
  - With no agencies, every route whose `agency_id` is blank or another value is set to
    the new ID. With exactly one existing agency, blank routes and blank fare attributes
    are set to that agency's ID; blank attributions stay blank (they apply to the whole
    dataset).

  Because the insert happens after the backfill in the same transaction, a changeset
  error rolls the backfill back and leaves the prior committed state usable.

  ## Returns

  - `{:ok, agency}` on a create
  - `{:error, changeset}` for attrs the editor changeset refuses
  - `{:error, :forbidden}` for a deactivated or non-editor member
  - `{:error, :not_found}` for a scope that is not a published version of the actor's
    organization
  - `{:error, :timezone_unresolved}` when the version has agencies but no single valid
    zone
  """
  @spec create_agency(AuditContext.t(), map()) ::
          {:ok, Agency.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found | :timezone_unresolved}
  def create_agency(%AuditContext{} = audit_context, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    Repo.transaction(fn ->
      Authorization.lock_editor!(audit_context)
      lock_version!(audit_context)

      audit_context
      |> agencies_in_scope()
      |> create_agency_locked!(attrs, audit_context)
    end)
  end

  @doc """
  Updates one of the version's agencies, refusing a save based on a stale row (R8, R9,
  R10, INV-2).

  `id` is the agency's row UUID; a foreign, unknown or malformed id returns `:not_found`.
  `token` is the `updated_at` the editor loaded with the form. One transaction authorizes
  the actor, share-locks the published version row, loads the scoped row `FOR UPDATE` and
  compares timestamps:

  - a token equal to the row's `updated_at` updates the row through
    `Agency.editor_changeset/2`;
  - a different token returns `:stale` with no write.

  The submitted attrs never carry `agency_id`, `agency_timezone` or a scope field into the
  write: `editor_changeset/2` casts only the editable fields, and the two identifier
  columns are dropped before the changeset is built.

  ## Returns

  - `{:ok, agency}` on an update
  - `{:error, changeset}` for attrs the editor changeset refuses
  - `{:error, :forbidden}` for a deactivated or non-editor member
  - `{:error, :not_found}` for a scope that is not a published version of the actor's
    organization, or an agency id outside it
  - `{:error, :stale}` when the token does not match the stored row, so nothing is saved
  """
  @spec update_agency(AuditContext.t(), String.t(), map(), DateTime.t()) ::
          {:ok, Agency.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found | :stale}
  def update_agency(%AuditContext{} = audit_context, id, attrs, token) when is_map(attrs) do
    attrs = attrs |> stringify_keys() |> Map.drop(["agency_timezone", "agency_id"])

    Repo.transaction(fn ->
      Authorization.lock_editor!(audit_context)
      share_version!(audit_context)

      audit_context
      |> lock_scoped_agency!(id)
      |> update_agency_locked!(attrs, token)
    end)
  end

  @doc """
  Reviews a version-wide timezone change against the version's current agencies (R3,
  INV-3).

  `zone` is the zone the editor chose; surrounding whitespace is trimmed and the trimmed
  name must be one `DisplayClock.valid_zone?/1` accepts (INV-4). One transaction then
  authorizes the actor, share-locks the published version row (INV-2) and loads the
  version's agencies with the route counts `list_agencies/2` reports (R5). With no
  agencies there is no zone to change and the review returns `:no_agencies`.

  Each returned agency names the zone it holds now in `from`, and `fingerprint` binds the
  reviewed zone to the `{agency row id, agency_timezone}` pairs the review observed, so
  `apply_timezone_change/3` can tell whether the version still matches this review.

  ## Returns

  - `{:ok, review}` with `:zone`, `:fingerprint` and `:agencies`
  - `{:error, :invalid_timezone}` for a blank, non-binary or unknown zone
  - `{:error, :forbidden}` for a deactivated or non-editor member
  - `{:error, :not_found}` for a scope that is not a published version of the actor's
    organization
  - `{:error, :no_agencies}` when the version has no agencies
  """
  @spec review_timezone_change(AuditContext.t(), String.t()) ::
          {:ok, timezone_review()}
          | {:error, :forbidden | :not_found | :invalid_timezone | :no_agencies}
  def review_timezone_change(%AuditContext{} = audit_context, zone) do
    case normalize_zone(zone) do
      :invalid ->
        {:error, :invalid_timezone}

      zone ->
        Repo.transaction(fn ->
          Authorization.lock_editor!(audit_context)
          share_version!(audit_context)

          audit_context
          |> list_agencies_in_scope()
          |> timezone_review_locked!(zone)
        end)
    end
  end

  @doc """
  Applies a reviewed version-wide timezone change atomically (R3, INV-3, CR-7).

  `zone` is validated exactly as `review_timezone_change/2` validates it, and
  `fingerprint` is the token that review returned. One transaction authorizes the actor,
  takes the published version row `FOR UPDATE` (INV-2) and recomputes the fingerprint from
  the version's current `{agency row id, agency_timezone}` pairs and the given zone. Any
  difference rolls back `:stale_review` with no write, so an agency added or removed after
  the review, an agency whose zone changed after it, and a different zone applied with an
  earlier review's token all change nothing.

  On a match one `UPDATE` sets `agency_timezone` and `updated_at` for every agency of the
  version and the number of rows it rewrote is returned. Stop times, frequencies and
  calendars are neither read nor written (CR-7), so stored clock times are unchanged.

  ## Returns

  - `{:ok, updated_agency_count}` on an apply
  - `{:error, :invalid_timezone}` for a blank, non-binary or unknown zone
  - `{:error, :forbidden}` for a deactivated or non-editor member
  - `{:error, :not_found}` for a scope that is not a published version of the actor's
    organization
  - `{:error, :stale_review}` when the version no longer matches the review, or the given
    zone differs from the reviewed one
  """
  @spec apply_timezone_change(AuditContext.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :forbidden | :not_found | :invalid_timezone | :stale_review}
  def apply_timezone_change(%AuditContext{} = audit_context, zone, fingerprint) do
    case normalize_zone(zone) do
      :invalid ->
        {:error, :invalid_timezone}

      zone ->
        Repo.transaction(fn ->
          Authorization.lock_editor!(audit_context)
          lock_version!(audit_context)

          audit_context
          |> agencies_in_scope()
          |> apply_timezone_locked!(zone, fingerprint, audit_context)
        end)
    end
  end

  @doc """
  Reviews the deletion of one of the version's agencies against its current state (R7,
  INV-3).

  `id` is the agency's row UUID and `target_id` the row UUID of the receiving agency, or
  nil when the editor chose none. One transaction authorizes the actor, share-locks the
  published version row (INV-2) and loads:

  - the scoped agency, so a malformed, unknown, foreign or other-version id is
    `:not_found`;
  - the version's agency row IDs, because the last agency cannot be deleted (AC-19);
  - the routes that carry the agency's own ID, ordered by `route_id` (AC-20);
  - the `fare_id`s and `attribution_id`s that reference the agency, which block the
    deletion until later work can move them (AC-21);
  - the number of record-bound agency translations, which the deletion removes.

  A review is returned even when blockers exist, so the editor can be told why. An agency
  with routes needs a different existing receiving agency in the same version, and any
  target given for an agency without routes is ignored. `fingerprint` binds that command
  and the reviewed route and agency sets, so `delete_agency/4` can tell whether the
  version still matches this review.

  ## Returns

  - `{:ok, review}` with `:agency`, `:target`, `:fingerprint`, `:routes`, `:blockers` and
    `:translation_count`
  - `{:error, :not_found}` for an agency id outside the version or the actor's
    organization, or a scope that is not a published version of it
  - `{:error, :last_agency}` when the version holds fewer than two agencies
  - `{:error, :target_required}` when the agency has routes and no target was chosen
  - `{:error, :invalid_target}` when the chosen target does not exist in the version or is
    the agency itself
  - `{:error, :forbidden}` for a deactivated or non-editor member
  """
  @spec review_agency_deletion(AuditContext.t(), String.t(), String.t() | nil) ::
          {:ok, deletion_review()}
          | {:error, :forbidden | :not_found | :last_agency | :target_required | :invalid_target}
  def review_agency_deletion(%AuditContext{} = audit_context, id, target_id) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(audit_context)
      share_version!(audit_context)

      audit_context
      |> deletion_state(id, target_id)
      |> deletion_review_locked!(target_id)
    end)
  end

  @doc """
  Deletes a reviewed agency, moving its routes to the receiving agency in one transaction
  (R7, INV-2, INV-3).

  `id` and `target_id` are the arguments the review was taken with and `fingerprint` is
  the token `review_agency_deletion/3` returned. One transaction authorizes the actor and
  takes the published version row `FOR UPDATE` before re-reading the reviewed state. It
  rolls back `:stale_review` with no write unless all of the following still hold:

  - the agency exists in the version and is not the last one;
  - the receiving agency rule still resolves to the reviewed target, so a deleted or
    replaced target, a target that became the agency itself and a missing target all
    refuse a command that needs one;
  - no fare attribute or attribution references the agency;
  - the fingerprint still matches, so a route, an agency or a different target that
    appeared after the review changes nothing.

  On a match the routes that carry the agency's ID are moved to the receiving agency, the
  agency's record-bound translations are deleted, and the agency row is deleted. A review
  whose agency was already deleted, or a second of two valid reviews taken before either
  applied, therefore loses with `:stale_review` instead of emptying the version or leaving
  a route on a deleted agency.

  ## Returns

  - `{:ok, %{moved_routes: count, target: agency | nil}}` on a deletion
  - `{:error, :forbidden}` for a deactivated or non-editor member
  - `{:error, :not_found}` for a malformed agency id, or a scope that is not a published
    version of the actor's organization
  - `{:error, :stale_review}` when the version no longer matches the review, including an
    agency that no longer resolves in it
  """
  @spec delete_agency(AuditContext.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, %{moved_routes: non_neg_integer(), target: Agency.t() | nil}}
          | {:error, :forbidden | :not_found | :stale_review}
  def delete_agency(%AuditContext{} = audit_context, id, target_id, fingerprint) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(audit_context)
      lock_version!(audit_context)
      deletion_locked!(audit_context, id, target_id, fingerprint)
    end)
  end

  @doc """
  Locks the published version row and resolves the agency a route insert references (R4,
  INV-1, INV-2).

  `organization_id` and `gtfs_version_id` are the scope the route is inserted into, and
  `agency_id` is the choice the caller sent, or nil. Call this inside
  `Repo.transaction/1`: the version row is share-locked before the agency set is read, so
  the insert serializes against an agency deletion, creation or timezone change for the
  same version (AC-26). The scope must be a published version of the organization, else
  `:not_found`.

  The rule is the one every route write uses:

  - no agency in the version → `:agency_required`;
  - one agency and a blank choice → that agency's ID;
  - otherwise the choice must be one of the version's agency IDs, else `:agency_not_found`.

  ## Returns

  - the resolved `agency_id` string
  - rolls back `:not_found`, `:agency_required` or `:agency_not_found`
  """
  @spec lock_agency_for_reference!(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) :: String.t()
  def lock_agency_for_reference!(organization_id, gtfs_version_id, agency_id) do
    share_version!(organization_id, gtfs_version_id)
    reference_agency!(organization_id, gtfs_version_id, agency_id)
  end

  @doc """
  Creates or updates the version's feed info row (R8, R10, INV-2).

  `token` is the `updated_at` of the row the caller loaded, or nil when the form was
  opened without a row. One transaction authorizes the actor, share-locks the published
  version row, loads the version's feed info row `FOR UPDATE`, and then branches:

  - no row and a nil token inserts the row through the editor changeset;
  - a row whose `updated_at` equals the token updates it;
  - every other pair — a first save against an existing row, a token without a row, or a
    token that is not a loaded `updated_at` — returns `:stale` with no write.

  ## Returns

  - `{:ok, feed_info}` on a create or update
  - `{:error, changeset}` for attrs the editor changeset refuses
  - `{:error, :forbidden}` for a deactivated or non-editor member
  - `{:error, :not_found}` for a scope that is not a published version of the actor's
    organization
  - `{:error, :stale}` for a conflicting save, including a lost first-insert race
  """
  @spec save_feed_info(AuditContext.t(), map(), DateTime.t() | nil) ::
          {:ok, FeedInfo.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found | :stale}
  def save_feed_info(%AuditContext{} = audit_context, attrs, token) when is_map(attrs) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(audit_context)
      share_version!(audit_context)

      audit_context
      |> lock_feed_info!()
      |> save_locked!(attrs, token, audit_context)
    end)
  end

  defp save_locked!(nil, attrs, nil, %AuditContext{} = audit_context) do
    %FeedInfo{
      organization_id: audit_context.organization_id,
      gtfs_version_id: audit_context.gtfs_version_id
    }
    |> FeedInfo.editor_changeset(attrs)
    |> insert_stale_safe!()
  end

  defp save_locked!(%FeedInfo{} = feed_info, attrs, %DateTime{} = token, _audit_context) do
    if DateTime.compare(feed_info.updated_at, token) == :eq do
      feed_info
      |> FeedInfo.editor_changeset(attrs)
      |> update_or_rollback!()
    else
      Repo.rollback(:stale)
    end
  end

  defp save_locked!(_feed_info, _attrs, _token, _audit_context), do: Repo.rollback(:stale)

  # The unique index on (organization_id, gtfs_version_id) is the first-insert race:
  # the insert that loses is a conflict, never a second row. The savepoint keeps the
  # statement's constraint violation from aborting the save's own transaction, so the
  # transaction decides the `:stale` outcome instead of PostgreSQL deciding it.
  defp insert_stale_safe!(changeset) do
    case Repo.insert(changeset, mode: :savepoint) do
      {:ok, feed_info} ->
        feed_info

      {:error, changeset} ->
        if unique_conflict?(changeset) do
          Repo.rollback(:stale)
        else
          Repo.rollback(changeset)
        end
    end
  end

  defp update_or_rollback!(changeset) do
    case Repo.update(changeset) do
      {:ok, feed_info} -> feed_info
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp unique_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} when is_list(opts) -> opts[:constraint] == :unique
      _error -> false
    end)
  end

  defp lock_feed_info!(%AuditContext{} = audit_context) do
    from(f in FeedInfo,
      where:
        f.organization_id == ^audit_context.organization_id and
          f.gtfs_version_id == ^audit_context.gtfs_version_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  # The version lock is the row `Calendars` locks, and it is taken before any feed-info
  # row so agency-set writes and calendar writes share one lock order (INV-2, R10).
  defp share_version!(%AuditContext{} = audit_context) do
    share_version!(audit_context.organization_id, audit_context.gtfs_version_id)
  end

  # The reference lock is the same row in the same mode, so a route insert takes the lock
  # every agency-set write takes, and no other lock precedes it (INV-1, INV-2).
  defp share_version!(organization_id, gtfs_version_id) do
    organization_id
    |> published_version_for_share(gtfs_version_id)
    |> case do
      %GtfsVersion{} = version -> version
      nil -> Repo.rollback(:not_found)
    end
  end

  # A literal lock string is required by Ecto; sharing the scoped version row excludes
  # cooperating writers for the duration of the save. The `uuid?/1` guards keep a
  # malformed scope out of the query instead of raising on a cast.
  defp published_version_for_share(organization_id, version_id) do
    if uuid?(organization_id) and uuid?(version_id) do
      from(v in GtfsVersion,
        where:
          v.id == ^version_id and v.organization_id == ^organization_id and
            v.publication_status == ^@published_status,
        lock: "FOR SHARE"
      )
      |> Repo.one()
    end
  end

  # Agency-set writes take the same version row `FOR UPDATE`, before any agency read,
  # so two writes cannot interleave between the state they read and the write they
  # make (INV-2). The row and the guards are the ones `share_version!/1` uses.
  defp lock_version!(%AuditContext{} = audit_context) do
    audit_context.organization_id
    |> published_version_for_update(audit_context.gtfs_version_id)
    |> case do
      %GtfsVersion{} = version -> version
      nil -> Repo.rollback(:not_found)
    end
  end

  defp published_version_for_update(organization_id, version_id) do
    if uuid?(organization_id) and uuid?(version_id) do
      from(v in GtfsVersion,
        where:
          v.id == ^version_id and v.organization_id == ^organization_id and
            v.publication_status == ^@published_status,
        lock: "FOR UPDATE"
      )
      |> Repo.one()
    end
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  # Blank here is PostgreSQL's `btrim`, so a route reference is classified the same way as
  # the version zone candidates. Exact counts keep the stored string: a padded reference is
  # neither blank nor an exact match, so it stays unassigned (R5).
  defp route_counts(organization_id, gtfs_version_id) do
    %{
      by_agency_id: exact_route_counts(organization_id, gtfs_version_id),
      blank: blank_route_count(organization_id, gtfs_version_id)
    }
  end

  defp exact_route_counts(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      where: not is_nil(r.agency_id) and fragment("btrim(?) <> ''", r.agency_id),
      group_by: r.agency_id,
      select: {r.agency_id, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp blank_route_count(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      where: is_nil(r.agency_id) or fragment("btrim(?) = ''", r.agency_id),
      select: count(r.id)
    )
    |> Repo.one()
  end

  defp route_total(%{by_agency_id: by_agency_id, blank: blank}) do
    blank + Enum.sum(Map.values(by_agency_id))
  end

  defp route_count(%{by_agency_id: by_agency_id, blank: blank}, agencies, agency) do
    exact_matches = Map.get(by_agency_id, agency.agency_id, 0)

    if single_agency?(agencies), do: exact_matches + blank, else: exact_matches
  end

  defp single_agency?([_agency]), do: true
  defp single_agency?(_agencies), do: false

  defp scoped_agency(organization_id, gtfs_version_id, agency_id) do
    from(a in Agency,
      where:
        a.id == ^agency_id and a.organization_id == ^organization_id and
          a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  defp zone_state(organization_id, gtfs_version_id) do
    case DisplayClock.resolve_zone(organization_id, gtfs_version_id) do
      %{fallback?: false, timezone: timezone} -> {:ok, timezone}
      %{fallback_reason: reason} -> {:unresolved, reason}
    end
  end

  # -- Agency creation -------------------------------------------------------

  defp agencies_in_scope(%AuditContext{} = audit_context) do
    Gtfs.list_agencies(audit_context.organization_id, audit_context.gtfs_version_id)
  end

  defp create_agency_locked!(agencies, attrs, %AuditContext{} = audit_context) do
    attrs = resolve_create_zone!(attrs, audit_context, agencies)
    agency_id = next_agency_id(attrs["agency_name"], audit_context, agencies)

    backfill_before_create!(agencies, agency_id, audit_context)

    %Agency{
      organization_id: audit_context.organization_id,
      gtfs_version_id: audit_context.gtfs_version_id,
      agency_id: agency_id
    }
    |> Agency.editor_changeset(attrs)
    |> insert_or_rollback!()
  end

  # The first agency carries the zone the editor validated from the form. Later agencies
  # take the version zone, so the version never holds two zones (R2).
  defp resolve_create_zone!(attrs, _audit_context, []), do: attrs

  defp resolve_create_zone!(attrs, %AuditContext{} = audit_context, [_ | _]) do
    case DisplayClock.resolve_zone(audit_context.organization_id, audit_context.gtfs_version_id) do
      %{fallback?: false, timezone: timezone} -> Map.put(attrs, "agency_timezone", timezone)
      %{fallback_reason: _reason} -> Repo.rollback(:timezone_unresolved)
    end
  end

  # R1: adopt a single dangling route reference in an otherwise empty version, otherwise
  # slugify the name and step past every taken ID.
  defp next_agency_id(name, %AuditContext{} = audit_context, []) do
    case referenced_agency_ids(audit_context.organization_id, audit_context.gtfs_version_id) do
      [referenced_id] ->
        referenced_id

      _none_or_many ->
        unique_agency_id(slug_or_default(name), taken_agency_ids([], audit_context))
    end
  end

  defp next_agency_id(name, %AuditContext{} = audit_context, agencies) do
    unique_agency_id(slug_or_default(name), taken_agency_ids(agencies, audit_context))
  end

  defp slug_or_default(name) do
    case Stop.slugify(name) do
      "" -> "agency"
      slug -> slug
    end
  end

  defp unique_agency_id(base, taken) do
    if MapSet.member?(taken, base), do: suffixed_agency_id(base, taken, 2), else: base
  end

  defp suffixed_agency_id(base, taken, suffix) do
    candidate = "#{base}_#{suffix}"

    if MapSet.member?(taken, candidate),
      do: suffixed_agency_id(base, taken, suffix + 1),
      else: candidate
  end

  # The candidate must avoid the version's own agency IDs and every non-blank reference
  # in the three tables whose `agency_id` outlives a single route (R1).
  defp taken_agency_ids(agencies, %AuditContext{} = audit_context) do
    referenced =
      referenced_agency_ids(audit_context.organization_id, audit_context.gtfs_version_id) ++
        fare_attribute_agency_ids(audit_context.organization_id, audit_context.gtfs_version_id) ++
        attribution_agency_ids(audit_context.organization_id, audit_context.gtfs_version_id)

    MapSet.new(Enum.map(agencies, & &1.agency_id) ++ referenced)
  end

  # Route references drive both the adoption rule and the first-agency backfill.
  defp referenced_agency_ids(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      where: not is_nil(r.agency_id) and fragment("btrim(?) <> ''", r.agency_id),
      distinct: true,
      select: r.agency_id
    )
    |> Repo.all()
  end

  defp fare_attribute_agency_ids(organization_id, gtfs_version_id) do
    from(f in FareAttribute,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      where: not is_nil(f.agency_id) and fragment("btrim(?) <> ''", f.agency_id),
      distinct: true,
      select: f.agency_id
    )
    |> Repo.all()
  end

  defp attribution_agency_ids(organization_id, gtfs_version_id) do
    from(a in Attribution,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
      where: not is_nil(a.agency_id) and fragment("btrim(?) <> ''", a.agency_id),
      distinct: true,
      select: a.agency_id
    )
    |> Repo.all()
  end

  defp backfill_before_create!([], agency_id, %AuditContext{} = audit_context) do
    backfill_first_agency(
      audit_context.organization_id,
      audit_context.gtfs_version_id,
      agency_id
    )
  end

  defp backfill_before_create!(
         [%Agency{agency_id: existing_id}],
         _agency_id,
         %AuditContext{} = audit_context
       ) do
    backfill_second_agency(
      audit_context.organization_id,
      audit_context.gtfs_version_id,
      existing_id
    )
  end

  defp backfill_before_create!(_agencies, _agency_id, _audit_context), do: :ok

  # R6: a first agency claims every route that does not already carry its own ID. A route
  # that already references the adopted ID is left byte-for-byte as it was.
  defp backfill_first_agency(organization_id, gtfs_version_id, agency_id) do
    Route
    |> where([r], r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id)
    |> where(
      [r],
      is_nil(r.agency_id) or fragment("btrim(?) = ''", r.agency_id) or
        r.agency_id != ^agency_id
    )
    |> Repo.update_all(set: [agency_id: agency_id])
  end

  # R6: a second agency first fills the blanks that belong to the only existing agency.
  # Blank attributions stay blank: they describe the whole dataset, not one operator.
  defp backfill_second_agency(organization_id, gtfs_version_id, agency_id) do
    Route
    |> where([r], r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id)
    |> where([r], is_nil(r.agency_id) or fragment("btrim(?) = ''", r.agency_id))
    |> Repo.update_all(set: [agency_id: agency_id])

    FareAttribute
    |> where([f], f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id)
    |> where([f], is_nil(f.agency_id) or fragment("btrim(?) = ''", f.agency_id))
    |> Repo.update_all(set: [agency_id: agency_id])
  end

  # -- Agency updates --------------------------------------------------------

  # The agency row is locked only after the version row, the order `share_version!/1`
  # established (INV-2). A malformed id never reaches the query, and the scope filters
  # mean another organization's or another version's row is the same as no row.
  defp lock_scoped_agency!(%AuditContext{} = audit_context, agency_row_id) do
    case Ecto.UUID.cast(agency_row_id) do
      {:ok, agency_id} ->
        from(a in Agency,
          where:
            a.id == ^agency_id and a.organization_id == ^audit_context.organization_id and
              a.gtfs_version_id == ^audit_context.gtfs_version_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  defp update_agency_locked!(nil, _attrs, _token), do: Repo.rollback(:not_found)

  defp update_agency_locked!(%Agency{} = agency, attrs, %DateTime{} = token) do
    if DateTime.compare(agency.updated_at, token) == :eq do
      agency
      |> Agency.editor_changeset(attrs)
      |> update_or_rollback!()
    else
      Repo.rollback(:stale)
    end
  end

  # -- Timezone change -------------------------------------------------------

  # The zone field may carry surrounding whitespace and `valid_zone?/1` compares exactly,
  # so trimming here keeps DisplayClock the single zone authority (INV-4). Anything that is
  # not a trimmed catalog name is refused before a transaction is opened.
  defp normalize_zone(zone) when is_binary(zone) do
    zone = String.trim(zone)

    if DisplayClock.valid_zone?(zone), do: zone, else: :invalid
  end

  defp normalize_zone(_zone), do: :invalid

  defp list_agencies_in_scope(%AuditContext{} = audit_context) do
    list_agencies(audit_context.organization_id, audit_context.gtfs_version_id)
  end

  defp timezone_review_locked!([], _zone), do: Repo.rollback(:no_agencies)

  defp timezone_review_locked!(rows, zone) do
    agencies = Enum.map(rows, & &1.agency)

    %{
      zone: zone,
      fingerprint: timezone_fingerprint(zone, timezone_pairs(agencies)),
      agencies: Enum.map(rows, &timezone_review_row/1)
    }
  end

  defp timezone_review_row(%{agency: agency, route_count: route_count}) do
    %{
      id: agency.id,
      agency_id: agency.agency_id,
      agency_name: agency.agency_name,
      from: agency.agency_timezone,
      route_count: route_count
    }
  end

  # The fingerprint covers the agency rows the review observed, not the route counts the
  # review displays, so a route moving between agencies does not invalidate a review: only
  # the agency set and its zones bind the command (INV-3, R3).
  defp apply_timezone_locked!(agencies, zone, fingerprint, %AuditContext{} = audit_context) do
    unless timezone_fingerprint(zone, timezone_pairs(agencies)) == fingerprint do
      Repo.rollback(:stale_review)
    end

    update_timezones!(zone, audit_context)
  end

  defp timezone_pairs(agencies) do
    Enum.map(agencies, fn %Agency{} = agency -> {agency.id, agency.agency_timezone} end)
  end

  defp timezone_fingerprint(zone, pairs) do
    :crypto.hash(:sha256, :erlang.term_to_binary({:timezone, zone, Enum.sort(pairs)}))
    |> Base.encode16(case: :lower)
  end

  # The whole version moves in one statement, so a failed apply cannot leave part of the
  # agency set rezoned. `update_all` writes no timestamps of its own, hence the explicit
  # `updated_at`: an edit drawer open across an apply then reports a conflict (R8).
  defp update_timezones!(zone, %AuditContext{} = audit_context) do
    now = DateTime.utc_now()

    {count, _} =
      Agency
      |> where(
        [a],
        a.organization_id == ^audit_context.organization_id and
          a.gtfs_version_id == ^audit_context.gtfs_version_id
      )
      |> Repo.update_all(set: [agency_timezone: zone, updated_at: now])

    count
  end

  # -- Agency deletion -------------------------------------------------------

  # One snapshot of everything a deletion re-validates. `nil` when the agency is not in
  # scope, so a malformed, unknown, foreign or other-version id never reaches a write.
  defp deletion_state(%AuditContext{} = audit_context, id, target_id) do
    with %Agency{} = agency <- scoped_agency_row(audit_context, id) do
      %{
        agency: agency,
        target: scoped_agency_row(audit_context, target_id),
        agency_row_ids: audit_context |> agencies_in_scope() |> Enum.map(& &1.id) |> Enum.sort(),
        routes: deletion_routes(audit_context, agency),
        blockers: deletion_blockers(audit_context, agency),
        translation_count: deletion_translation_count(audit_context, agency)
      }
    end
  end

  # The row id is cast before the query, so a malformed id is the same as an unknown one,
  # and the scope filters make another organization's or another version's row the same as
  # no row at all (R10). Both callers hold the version row lock, which is the state the
  # deletion depends on (INV-2).
  defp scoped_agency_row(%AuditContext{} = audit_context, row_id) do
    case Ecto.UUID.cast(row_id) do
      {:ok, agency_id} ->
        scoped_agency(audit_context.organization_id, audit_context.gtfs_version_id, agency_id)

      :error ->
        nil
    end
  end

  # The routes that move are the ones carrying the agency's own ID (R7). Exact matches
  # only: with two or more agencies a blank or padded reference is not this agency's route
  # (R5), and it names no agency, so the move leaves it as it was.
  defp deletion_routes(%AuditContext{} = audit_context, agency) do
    from(r in Route,
      where:
        r.organization_id == ^audit_context.organization_id and
          r.gtfs_version_id == ^audit_context.gtfs_version_id and
          not is_nil(r.agency_id) and r.agency_id == ^agency.agency_id,
      order_by: [asc: r.route_id],
      select: %{
        route_id: r.route_id,
        route_short_name: r.route_short_name,
        route_long_name: r.route_long_name
      }
    )
    |> Repo.all()
  end

  # R7 blocks the deletion while a fare attribute or an attribution names the agency,
  # because neither has a rule for a receiving agency. The review reports their IDs so the
  # editor knows what to resolve first.
  defp deletion_blockers(%AuditContext{} = audit_context, agency) do
    %{
      fare_ids: deletion_fare_ids(audit_context, agency),
      attribution_ids: deletion_attribution_ids(audit_context, agency)
    }
  end

  defp deletion_fare_ids(%AuditContext{} = audit_context, agency) do
    from(f in FareAttribute,
      where:
        f.organization_id == ^audit_context.organization_id and
          f.gtfs_version_id == ^audit_context.gtfs_version_id and
          f.agency_id == ^agency.agency_id,
      select: f.fare_id
    )
    |> Repo.all()
    |> Enum.sort()
  end

  # An attribution may carry no ID of its own, so a blocker without one is named by a
  # placeholder the editor can match against the row.
  defp deletion_attribution_ids(%AuditContext{} = audit_context, agency) do
    from(a in Attribution,
      where:
        a.organization_id == ^audit_context.organization_id and
          a.gtfs_version_id == ^audit_context.gtfs_version_id and
          a.agency_id == ^agency.agency_id,
      select: a.attribution_id
    )
    |> Repo.all()
    |> Enum.map(&(&1 || @no_attribution_id))
    |> Enum.sort()
  end

  # The translations that name the agency row are never exported and have no editor, so
  # the deletion removes them with the agency (R7). A `field_value` translation matches no
  # record id and stays.
  defp deletion_translation_count(%AuditContext{} = audit_context, agency) do
    from(t in Translation,
      where:
        t.organization_id == ^audit_context.organization_id and
          t.gtfs_version_id == ^audit_context.gtfs_version_id and t.table_name == "agency" and
          t.record_id == ^agency.id,
      select: count(t.id)
    )
    |> Repo.one()
  end

  # The token binds the command to the state the review observed: the agency, the
  # receiving agency, the route IDs that move and the version's agency set (R7, INV-3).
  defp deletion_fingerprint(%{
         agency: agency,
         target: target,
         routes: routes,
         agency_row_ids: agency_row_ids
       }) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {:delete, agency.id, target && target.id, Enum.map(routes, & &1.route_id), agency_row_ids}
      )
    )
    |> Base.encode16(case: :lower)
  end

  defp deletion_review_locked!(nil, _target_id), do: Repo.rollback(:not_found)

  defp deletion_review_locked!(state, target_id) do
    if length(state.agency_row_ids) < 2 do
      Repo.rollback(:last_agency)
    end

    case resolve_deletion_target(state, target_id) do
      {:ok, target} -> deletion_review(state, target)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp deletion_review(state, target) do
    %{
      agency: state.agency,
      target: target,
      fingerprint: deletion_fingerprint(%{state | target: target}),
      routes: state.routes,
      blockers: state.blockers,
      translation_count: state.translation_count
    }
  end

  # A receiving agency must exist in the same version, differ from the agency and name an
  # agency at all (R7): its ID is blank when the import path left a whitespace-only value
  # behind (R5), and a move onto it would unassign the routes while reporting them moved.
  # An agency with no routes needs none, and a target given for one is ignored, so a review
  # and an apply called with the same arguments bind the same command either way.
  defp resolve_deletion_target(%{agency: agency, target: target, routes: routes}, target_id) do
    cond do
      target_id == nil and routes == [] -> {:ok, nil}
      target_id == nil -> {:error, :target_required}
      target == nil -> {:error, :invalid_target}
      target.id == agency.id -> {:error, :invalid_target}
      routes == [] -> {:ok, nil}
      Values.blank?(target.agency_id) -> {:error, :invalid_target}
      true -> {:ok, target}
    end
  end

  # A malformed id is a protocol error, refused with `:not_found` exactly like the other
  # scoped writes, and only after the actor was authorized, so what an unauthorized caller
  # sees never depends on the id's shape. A well-formed id that no longer resolves in the
  # scope is a stale review instead: the row set the review observed changed.
  defp deletion_locked!(%AuditContext{} = audit_context, id, target_id, fingerprint) do
    case Ecto.UUID.cast(id) do
      {:ok, _agency_id} ->
        audit_context
        |> deletion_state(id, target_id)
        |> deletion_apply_locked!(target_id, fingerprint, audit_context)

      :error ->
        Repo.rollback(:not_found)
    end
  end

  defp deletion_apply_locked!(nil, _target_id, _fingerprint, _audit_context),
    do: Repo.rollback(:stale_review)

  defp deletion_apply_locked!(state, target_id, fingerprint, %AuditContext{} = audit_context) do
    if length(state.agency_row_ids) < 2 do
      Repo.rollback(:stale_review)
    end

    if state.blockers.fare_ids != [] or state.blockers.attribution_ids != [] do
      Repo.rollback(:stale_review)
    end

    target =
      case resolve_deletion_target(state, target_id) do
        {:ok, target} -> target
        {:error, _reason} -> Repo.rollback(:stale_review)
      end

    if deletion_fingerprint(%{state | target: target}) != fingerprint do
      Repo.rollback(:stale_review)
    end

    moved_routes = move_agency_routes!(state.agency, target, audit_context)
    delete_agency_translations!(state.agency, audit_context)
    delete_agency_row!(state.agency)

    %{moved_routes: moved_routes, target: target}
  end

  # Skipping the move without a receiving agency keeps a route on the agency that is about
  # to be deleted out of reach by construction.
  defp move_agency_routes!(_agency, nil, _audit_context), do: 0

  defp move_agency_routes!(agency, %Agency{} = target, %AuditContext{} = audit_context) do
    {count, _} =
      Route
      |> where(
        [r],
        r.organization_id == ^audit_context.organization_id and
          r.gtfs_version_id == ^audit_context.gtfs_version_id
      )
      |> where([r], r.agency_id == ^agency.agency_id)
      |> Repo.update_all(set: [agency_id: target.agency_id])

    count
  end

  defp delete_agency_translations!(agency, %AuditContext{} = audit_context) do
    Translation
    |> where(
      [t],
      t.organization_id == ^audit_context.organization_id and
        t.gtfs_version_id == ^audit_context.gtfs_version_id and t.table_name == "agency" and
        t.record_id == ^agency.id
    )
    |> Repo.delete_all()
  end

  # The transaction owns the irreversible step: a delete that finds the row already gone
  # rolls the whole command back to the reviewed state instead of raising out of the
  # public contract.
  defp delete_agency_row!(agency) do
    case Repo.delete(agency) do
      {:ok, _deleted} -> :ok
      {:error, _changeset} -> Repo.rollback(:stale_review)
    end
  end

  # -- Route agency references -----------------------------------------------

  # The version's agencies through the scoped read steps 9-13 use, so the reference rule
  # sees the same agency set under the same lock as every other agency-set read (INV-1).
  defp reference_agency!(organization_id, gtfs_version_id, agency_id) do
    organization_id
    |> Gtfs.list_agencies(gtfs_version_id)
    |> resolve_reference_agency!(agency_id)
  end

  defp resolve_reference_agency!([], _agency_id), do: Repo.rollback(:agency_required)

  # A blank choice means "the only agency", so a version with one agency resolves without
  # asking the caller to know its ID (R4).
  defp resolve_reference_agency!([%Agency{} = agency], agency_id) do
    if Values.blank?(agency_id) do
      agency.agency_id
    else
      listed_agency_reference!([agency], agency_id)
    end
  end

  defp resolve_reference_agency!([_ | _] = agencies, agency_id) do
    listed_agency_reference!(agencies, agency_id)
  end

  # With two or more agencies only an exact match names one, so a blank, padded or unknown
  # choice is refused instead of quietly becoming the first agency (R5, FH-20).
  defp listed_agency_reference!(agencies, agency_id) do
    case Enum.find(agencies, &(&1.agency_id == agency_id)) do
      %Agency{agency_id: resolved} -> resolved
      nil -> Repo.rollback(:agency_not_found)
    end
  end

  defp insert_or_rollback!(changeset) do
    case Repo.insert(changeset) do
      {:ok, agency} -> agency
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
