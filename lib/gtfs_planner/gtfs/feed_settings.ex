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
  timezone state, all scoped to the organization and version. Outside import and test
  fixtures this module is the application's writer of `agencies` and `feed_info` rows
  and of the agency columns they own (INV-5); the agency write entry points arrive with
  the steps that consume them.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedInfo
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"
  @editor_role "pathways_studio_editor"

  @type scope :: AuditContext.t()
  @type zone_state :: {:ok, String.t()} | {:unresolved, :missing | :invalid | :conflicting}
  @type agency_row :: %{agency: Agency.t(), route_count: non_neg_integer()}

  @type health :: %{
          agency_count: non_neg_integer(),
          unassigned_routes: non_neg_integer(),
          zone: zone_state()
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
      authorize_editor!(audit_context)
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
    audit_context.organization_id
    |> published_version_for_share(audit_context.gtfs_version_id)
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

  defp authorize_editor!(%AuditContext{} = audit_context) do
    case authorize_editor(audit_context) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_editor(%AuditContext{
         actor_id: actor_id,
         organization_id: organization_id
       }) do
    with true <- uuid?(actor_id),
         true <- uuid?(organization_id),
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(actor_id, organization_id),
         true <- is_nil(membership.deactivated_at),
         true <- editor_role?(membership.roles) do
      :ok
    else
      _other -> {:error, :forbidden}
    end
  end

  defp editor_role?(roles) when is_list(roles), do: @editor_role in roles
  defp editor_role?(_roles), do: false

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
end
