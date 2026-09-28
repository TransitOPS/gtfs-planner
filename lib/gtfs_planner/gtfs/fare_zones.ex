defmodule GtfsPlanner.Gtfs.FareZones do
  @moduledoc """
  Version-scoped fare zones and the projection of `fare_rules` rows into rules.

  This sub-context owns fare-zone data outside import: it is the only module that
  reads `fare_zones`, and — with the full importer — the only module that writes
  `stops.zone_id` and changes `fare_rules` rows. LiveViews call these functions
  instead of querying those tables themselves.

  Every read and write is filtered by `organization_id` and `gtfs_version_id`, so
  a row of another organization or version never resolves. Zone IDs and rule zone
  references are the exact stored strings: they are compared and written
  byte-for-byte, never trimmed or normalized. Membership counts and stop lists
  cover boardable stops (`location_type` 0) only; station and entrance zone IDs
  are kept and exported but not edited.

  `list_rule_groups/2` is the read side of the rule projection. One UI fare rule
  is exactly the set of `fare_rules` rows sharing `(fare_id, route_id, origin_id,
  destination_id, contains_id IS NOT NULL)`: a `contains_id` of NULL forms the
  rule for the journey itself, and rows with a `contains_id` form one rule whose
  `contains` values are the zones the journey must all visit. Every row of the
  version belongs to exactly one group, duplicate rows included, so the
  projection is lossless.

  `inventory/2` is the union of the version's `fare_zones` records, its distinct
  `stops.zone_id` values of every location type and the zone IDs its fare rules
  reference, compared byte-for-byte. A declared zone keeps its record's name and
  palette color; every other zone is named by its exact ID and colored with
  `FareZone.default_color/1`. `stop_count` counts boardable members and
  `other_stop_count` the remaining location types. `checks/2` derives the Checks
  tab's rows from that inventory and `zone_names/3` resolves display names for a
  list of zone IDs.

  The workspace's stop reads — `list_stops/3`, `matching_stop_ids/3` and
  `list_stop_points/2` — cover the version's boardable stops only. A zone filter
  matches the exact stored ID, search treats `%` and `_` literally, and the order
  is `stop_name` with names missing last, then `stop_id`, so the list pages, the
  current match and the map points stay deterministic.

  Reviewed bulk assignment is the three write functions `preview_assignment/4`,
  `apply_assignment/3` and `undo_assignment/3`. A preview is a read that reports
  each selected boardable stop's current and target zone; an apply writes the
  reviewed changes in one transaction that first locks the organization's
  published version row `FOR UPDATE`, so cooperating writers of one version
  serialize and a pair that is not a published version of the organization
  changes nothing (`:not_found`). Every change is fenced: the locked current zone
  must still equal the reviewed `from`, otherwise nothing is written and the
  changed stops are returned. `undo_assignment/3` takes exactly the `applied`
  list of a successful apply, swaps its values back and restores them without
  inventory validation, so a zone that left the inventory when its last stop
  moved is restored byte-for-byte. Only boardable stops are assignable and only
  a zone in the inventory can be an assignment target.

  Zone metadata is written by `create_zone/3` and `update_zone/4`, both inside
  the same version-locked transaction. `update_zone/4` edits only a zone that is
  still in the inventory: a metadata edit keeps the stored ID bytes and inserts a
  record for an implicit zone under exactly that ID, while an ID change (a form
  `zone_id` that differs from the stored ID both byte-for-byte and after
  trimming) moves the exact new ID on stops of every location type and in all
  three fare-rule zone columns and then rewrites the record. A form value that is
  the stored bytes or trims back to them is no change at all, so the drawer can
  re-send the untouched field, an imported `" A"` included. An ID the inventory
  already carries - a record, a stop of any location type or a fare-rule
  reference - is rejected with the in-use message, so a rename can neither merge
  two zones nor duplicate a rule row. `change_zone/2` is the drawer's form
  changeset and makes the same byte-for-byte decision, so a form validates what
  the write will do.

  `delete_zone/5` removes a zone inside the same version-locked transaction. It
  refuses a zone that left the inventory (`:not_found`), a request whose expected
  stop and rule counts no longer match the inventory (`{:stale, zone}` with the
  current entry), a zone fare rules use with no replacement
  (`:replacement_required`) and a replacement that is the zone itself or outside
  the inventory (`:invalid_replacement`); each refusal writes nothing. Otherwise
  the zone's stops of every location type move to the replacement (nil unassigns
  them), every fare-rule row that mentions the zone in `origin_id`,
  `destination_id` or `contains_id` is rewritten with the exact replacement value
  and reinserted under a new ID, a rewritten row identical to an unaffected row
  or to an earlier kept rewritten row is dropped, and the metadata record is
  removed - so no row keeps the deleted ID and no group is left orphaned.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"

  @type zone :: %{
          zone_id: String.t(),
          name: String.t(),
          color: String.t(),
          declared?: boolean(),
          stop_count: non_neg_integer(),
          other_stop_count: non_neg_integer(),
          rule_count: non_neg_integer()
        }

  @type inventory :: %{
          zones: [zone()],
          unassigned_count: non_neg_integer(),
          boardable_count: non_neg_integer()
        }

  @type rule_key :: {String.t(), String.t() | nil, String.t() | nil, String.t() | nil, boolean()}

  @type rule_row :: %{
          id: Ecto.UUID.t(),
          fare_id: String.t(),
          route_id: String.t() | nil,
          origin_id: String.t() | nil,
          destination_id: String.t() | nil,
          contains_id: String.t() | nil
        }

  @type rule_group :: %{
          key: rule_key(),
          fare_id: String.t(),
          route_id: String.t() | nil,
          origin_id: String.t() | nil,
          destination_id: String.t() | nil,
          contains: [String.t()],
          rows: [rule_row()],
          fare: %{price: Decimal.t(), currency_type: String.t()} | nil,
          route: %{short_name: String.t() | nil, long_name: String.t() | nil} | nil,
          unknown_fare?: boolean(),
          unknown_route?: boolean()
        }

  @type stop_filter :: :all | :unassigned | {:zone, String.t()}

  @type stop_entry :: %{
          id: Ecto.UUID.t(),
          stop_id: String.t(),
          stop_name: String.t() | nil,
          parent_station: String.t() | nil,
          platform_code: String.t() | nil,
          zone_id: String.t() | nil,
          located?: boolean()
        }

  @type stop_page :: %{
          entries: [stop_entry()],
          total_count: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          without_location_count: non_neg_integer()
        }

  @type stop_point :: [Ecto.UUID.t() | String.t() | float() | nil]

  @type assignment_change :: %{id: Ecto.UUID.t(), from: String.t() | nil, to: String.t() | nil}

  @type assignment_review :: %{
          rows: [
            %{
              id: Ecto.UUID.t(),
              stop_id: String.t(),
              stop_name: String.t() | nil,
              from: String.t() | nil,
              to: String.t() | nil
            }
          ],
          changes: [assignment_change()],
          changed_count: non_neg_integer(),
          added_count: non_neg_integer(),
          moved_count: non_neg_integer(),
          unchanged_count: non_neg_integer(),
          unselected_sibling_count: non_neg_integer()
        }

  @type stale_stop :: %{
          id: Ecto.UUID.t(),
          stop_id: String.t(),
          stop_name: String.t() | nil,
          reviewed: String.t() | nil,
          current: String.t() | nil
        }

  @type checks :: %{
          stopless_referenced: [zone()],
          unassigned_count: non_neg_integer(),
          empty_declared: [zone()],
          rules_reference_zones?: boolean()
        }

  @doc """
  Projects every `fare_rules` row of a version into one group per UI rule.

  Rows are grouped by `(fare_id, route_id, origin_id, destination_id, contains_id
  IS NOT NULL)`; `contains` holds the sorted unique non-nil `contains_id` values
  and `rows` lists every contributing row, duplicates included, ordered by ID.
  The group resolves its fare from the scoped `fare_attributes` row and its route
  from the scoped `routes` row: a missing fare sets `unknown_fare?` with a nil
  `fare`, a missing non-nil route sets `unknown_route?` with a nil `route`, and a
  nil route ID resolves to no route without being unknown.

  Groups are ordered by `fare_id`, origin, destination, route (nil first) and
  contains presence. A pair that is not a version of the organization returns an
  empty list.
  """
  @spec list_rule_groups(Ecto.UUID.t(), Ecto.UUID.t()) :: [rule_group()]
  def list_rule_groups(organization_id, gtfs_version_id) do
    rules = list_rows(organization_id, gtfs_version_id)
    fares = fare_index(organization_id, gtfs_version_id, Enum.map(rules, & &1.fare_id))
    routes = route_index(organization_id, gtfs_version_id, Enum.map(rules, & &1.route_id))

    rules
    |> Enum.group_by(&group_key/1)
    |> Enum.map(fn {key, rows} -> build_group(key, rows, fares, routes) end)
    |> Enum.sort_by(&sort_key/1)
  end

  @doc """
  The version's fare-zone inventory: declared records, stop zone IDs and rules.

  The zones are the byte-for-byte union of the version's `fare_zones` records,
  the distinct non-nil `stops.zone_id` values of every location type and the zone
  IDs its fare rules reference, sorted by ID. A zone with a record takes that
  record's name and color and is `declared?`; every other zone is named by its
  exact ID and colored with `FareZone.default_color/1`.

  `stop_count` counts `location_type` 0 members and `other_stop_count` the rest,
  so a zone carried only by a station or entrance has no stops. `rule_count`
  counts fare rules, not rows: a rule that references a zone twice, or whose rows
  repeat, counts once. `boardable_count` is every `location_type` 0 stop of the
  version and `unassigned_count` those without a zone.

  IDs are returned exactly as stored, so `" A"` and `"A"` are two zones with
  their own counts. A pair that is not a version of the organization returns an
  empty inventory.
  """
  @spec inventory(Ecto.UUID.t(), Ecto.UUID.t()) :: inventory()
  def inventory(organization_id, gtfs_version_id) do
    stop_counts = stop_zone_counts(organization_id, gtfs_version_id)
    declared = declared_zones(organization_id, gtfs_version_id)
    rule_counts = rule_zone_counts(organization_id, gtfs_version_id)
    {boardable_count, unassigned_count} = boardable_counts(organization_id, gtfs_version_id)

    zones =
      Enum.uniq(Map.keys(stop_counts) ++ Map.keys(declared) ++ Map.keys(rule_counts))
      |> Enum.sort()
      |> Enum.map(&build_zone(&1, declared, stop_counts, rule_counts))

    %{zones: zones, unassigned_count: unassigned_count, boardable_count: boardable_count}
  end

  @doc """
  The Checks tab's derived state.

  `stopless_referenced` lists the zones fare rules use that have no boardable
  stops, `unassigned_count` the version's boardable stops without a zone,
  `empty_declared` the declared zones that have no stops and no rules, and
  `rules_reference_zones?` whether any fare rule references a zone at all.
  """
  @spec checks(Ecto.UUID.t(), Ecto.UUID.t()) :: checks()
  def checks(organization_id, gtfs_version_id) do
    %{zones: zones, unassigned_count: unassigned_count} =
      inventory(organization_id, gtfs_version_id)

    %{
      stopless_referenced: Enum.filter(zones, &(&1.rule_count > 0 and &1.stop_count == 0)),
      unassigned_count: unassigned_count,
      empty_declared:
        Enum.filter(zones, &(&1.declared? and &1.stop_count == 0 and &1.rule_count == 0)),
      rules_reference_zones?: Enum.any?(zones, &(&1.rule_count > 0))
    }
  end

  @doc """
  Resolves display names for zone IDs.

  A zone with a `fare_zones` record returns that record's name; an undeclared
  zone returns its exact ID, so every requested ID has an entry. IDs of another
  organization or version never resolve.
  """
  @spec zone_names(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: %{String.t() => String.t()}
  def zone_names(_organization_id, _gtfs_version_id, []), do: %{}

  def zone_names(organization_id, gtfs_version_id, zone_ids) do
    names =
      from(z in FareZone,
        where:
          z.organization_id == ^organization_id and z.gtfs_version_id == ^gtfs_version_id and
            z.zone_id in ^Enum.uniq(zone_ids),
        select: {z.zone_id, z.name}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(zone_ids, fn zone_id -> {zone_id, Map.get(names, zone_id, zone_id)} end)
  end

  @default_page 1
  @default_per_page 100

  @doc """
  Lists one page of the version's boardable stops for the workspace list.

  `:filter` is `:all`, `:unassigned` (boardable stops without a zone) or
  `{:zone, id}`, which matches the stored zone ID byte-for-byte, so `" A"` never
  returns `"A"`. `:q` searches stop name and stop ID case-insensitively with `%`
  and `_` matched literally, so `50%` finds `Gate 50%` and not `Gate 500`, and
  `a_b` does not find `axb`; a nil or empty `:q` searches nothing.

  Entries are ordered by `stop_name` with names missing last, then by `stop_id`,
  so page boundaries do not depend on the database. `total_count` counts the
  stops the filter and search match, and `page` is clamped into `1..last_page`:
  a page past the end returns the last page, and an empty result is page 1.
  `without_location_count` counts the stops the filter alone matches that miss
  `stop_lat` or `stop_lon`, ignoring `:q`, for the workspace's "N without map
  location" caption. An entry carries `located?: false` when either coordinate
  is missing.

  A pair that is not a version of the organization returns an empty page.
  """
  @spec list_stops(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: stop_page()
  def list_stops(organization_id, gtfs_version_id, opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)
    per_page = Keyword.get(opts, :per_page, @default_per_page)

    matched =
      organization_id
      |> boardable_query(gtfs_version_id)
      |> apply_filter(filter)
      |> apply_search(Keyword.get(opts, :q))

    total_count = count_stops(matched)
    page = clamp_page(Keyword.get(opts, :page, @default_page), total_count, per_page)

    entries =
      matched
      |> order_by([s], asc_nulls_last: s.stop_name, asc: s.stop_id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> select([s], %{
        id: s.id,
        stop_id: s.stop_id,
        stop_name: s.stop_name,
        parent_station: s.parent_station,
        platform_code: s.platform_code,
        zone_id: s.zone_id,
        located?: not is_nil(s.stop_lat) and not is_nil(s.stop_lon)
      })
      |> Repo.all()

    %{
      entries: entries,
      total_count: total_count,
      page: page,
      per_page: per_page,
      without_location_count:
        count_stops(unlocated_stops(organization_id, gtfs_version_id, filter))
    }
  end

  @doc """
  Lists the IDs of every boardable stop a filter and search match.

  The result is the whole set `list_stops/3` pages through, in the same order
  (`stop_name` with missing names last, then `stop_id`), so a caller can hold it
  as the current match and offer "select all matching". `:ids` restricts the
  result to the given stop UUIDs: UUIDs of another organization or version and
  UUIDs of non-boardable stops are dropped, so one call validates a client
  selection. An empty `:ids` list matches nothing.
  """
  @spec matching_stop_ids(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: [Ecto.UUID.t()]
  def matching_stop_ids(organization_id, gtfs_version_id, opts \\ []) do
    organization_id
    |> boardable_query(gtfs_version_id)
    |> apply_filter(Keyword.get(opts, :filter, :all))
    |> apply_search(Keyword.get(opts, :q))
    |> restrict_to_ids(Keyword.get(opts, :ids))
    |> order_by([s], asc_nulls_last: s.stop_name, asc: s.stop_id)
    |> select([s], s.id)
    |> Repo.all()
  end

  @doc """
  Lists the map points of the version's located boardable stops.

  Each point is the list `[id, stop_id, stop_name, lat, lon, zone_id,
  parent_station]`, ordered by `stop_id`, so the whole payload encodes directly
  as the map hook's JSON. Only `location_type` 0 stops with both `stop_lat` and
  `stop_lon` appear, and the coordinates are floats. The zone ID is the exact
  stored string.

  A pair that is not a version of the organization returns an empty list.
  """
  @spec list_stop_points(Ecto.UUID.t(), Ecto.UUID.t()) :: [stop_point()]
  def list_stop_points(organization_id, gtfs_version_id) do
    organization_id
    |> boardable_query(gtfs_version_id)
    |> where([s], not is_nil(s.stop_lat) and not is_nil(s.stop_lon))
    |> order_by([s], asc: s.stop_id)
    |> select([s], {
      s.id,
      s.stop_id,
      s.stop_name,
      s.stop_lat,
      s.stop_lon,
      s.zone_id,
      s.parent_station
    })
    |> Repo.all()
    |> Enum.map(fn {id, stop_id, stop_name, lat, lon, zone_id, parent_station} ->
      [
        id,
        stop_id,
        stop_name,
        Decimal.to_float(lat),
        Decimal.to_float(lon),
        zone_id,
        parent_station
      ]
    end)
  end

  @doc """
  Reviews assigning the selected boardable stops to a target zone.

  `target` is the destination zone ID or nil to unassign; any other value must be
  in the version's inventory (a declared record, a `stops.zone_id` of any
  location type or a fare-rule reference) or the review fails `:unknown_zone`.
  Every selected stop must be a boardable stop of this organization and version,
  otherwise the review fails `:invalid_selection`.

  `rows` lists every selected stop in the list order (`stop_name` with missing
  names last, then `stop_id`) with its current (`from`) and target (`to`) zone.
  `changes` holds only the rows whose zone changes, `changed_count` their number,
  `added_count` the unassigned stops that gain the target, `moved_count` the
  stops that move between two zones, and `unchanged_count` the stops already at
  the target. `unselected_sibling_count` counts the version's unselected
  boardable stops that share a non-nil `parent_station` with a selected stop, so
  the review can disclose platforms of a selected one. A preview writes nothing.
  """
  @spec preview_assignment(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()], String.t() | nil) ::
          {:ok, assignment_review()} | {:error, :invalid_selection | :unknown_zone}
  def preview_assignment(organization_id, gtfs_version_id, stop_ids, target) do
    stop_ids = Enum.uniq(stop_ids)

    with :ok <- validate_target(organization_id, gtfs_version_id, target),
         {:ok, stops} <- selected_stops(organization_id, gtfs_version_id, stop_ids) do
      rows = Enum.map(stops, &assignment_row(&1, target))
      changes = for %{from: from, to: to} = row <- rows, from != to, do: change_of(row)

      {:ok,
       %{
         rows: rows,
         changes: changes,
         changed_count: length(changes),
         added_count: Enum.count(changes, &is_nil(&1.from)),
         moved_count: Enum.count(changes, &(not is_nil(&1.from) and not is_nil(&1.to))),
         unchanged_count: length(rows) - length(changes),
         unselected_sibling_count:
           unselected_sibling_count(organization_id, gtfs_version_id, stops)
       }}
    end
  end

  @doc """
  Writes exactly the reviewed assignment changes in one version-locked transaction.

  Each change's `from` is the zone the review showed and `to` the target; a `to`
  that is not nil must still be in the inventory (`:unknown_zone`), and every ID
  must still be a boardable stop of this organization and version
  (`:invalid_selection`, as for a duplicated foreign UUID). Inside one
  transaction the published version row is locked `FOR UPDATE` and the selected
  stops are locked and re-read: if any stop's current zone differs from its
  reviewed `from`, the transaction rolls back with
  `{:stale, [%{id, stop_id, stop_name, reviewed, current}]}` and nothing is
  written. Otherwise one `update_all/3` per distinct target writes the exact
  zone ID (nil for unassign) and `updated_at`, and the applied changes are
  returned for `undo_assignment/3`. A pair that is not a published version of the
  organization returns `:not_found` and changes nothing.
  """
  @spec apply_assignment(Ecto.UUID.t(), Ecto.UUID.t(), [assignment_change()]) ::
          {:ok, %{applied: [assignment_change()]}}
          | {:error, {:stale, [stale_stop()]} | :invalid_selection | :unknown_zone | :not_found}
  def apply_assignment(organization_id, gtfs_version_id, changes) do
    write_assignment(organization_id, gtfs_version_id, changes, validate_targets?: true)
  end

  @doc """
  Restores the zones an `apply_assignment/3` replaced, under the same fence.

  Call only with the exact `applied` list returned by a successful
  `apply_assignment/3`: the values are swapped back and written with no inventory
  validation, so a zone that left the inventory when its last stop moved, or was
  unassigned, is restored byte-for-byte. The same transaction, version-row lock,
  selection check and stale fence apply: if any stop changed after the save,
  nothing is written and `{:error, {:stale, stops}}` is returned. `:not_found`
  means the pair is not a published version of the organization.
  """
  @spec undo_assignment(Ecto.UUID.t(), Ecto.UUID.t(), [assignment_change()]) ::
          {:ok, %{applied: [assignment_change()]}}
          | {:error, {:stale, [stale_stop()]} | :invalid_selection | :not_found}
  def undo_assignment(organization_id, gtfs_version_id, applied) do
    changes = Enum.map(applied, &%{id: &1.id, from: &1.to, to: &1.from})
    write_assignment(organization_id, gtfs_version_id, changes, validate_targets?: false)
  end

  @doc """
  The zone drawer's changeset for a create or an edit form.

  `nil` starts a new zone: the ID is cast, trimmed and validated. For an
  existing zone the form's `zone_id` is an ID change only when neither its exact
  bytes nor its trimmed bytes are the stored ID. Otherwise it is a metadata edit,
  and `:keep` never casts the ID: the drawer can re-send an imported `" A"` or
  `"Zone 1"` verbatim, padding included, and those bytes are neither trimmed nor
  revalidated. A rename is trimmed and validated like a new ID. `create_zone/3`
  and `update_zone/4` make the same decision from the same form values.
  """
  @spec change_zone(FareZone.t() | nil, map()) :: Ecto.Changeset.t()
  def change_zone(nil, attrs), do: FareZone.changeset(%FareZone{}, attrs, :new)

  def change_zone(%FareZone{} = zone, attrs) do
    case changed_zone_id(zone.zone_id, attrs) do
      :same -> FareZone.changeset(zone, attrs, :keep)
      {:change, _zone_id} -> FareZone.changeset(zone, attrs, :new)
    end
  end

  @doc """
  Creates a zone in a published version of an organization.

  The name is trimmed and must be 1-60 characters, the ID is trimmed and must
  match `[A-Za-z0-9_-]{1,64}`, and the color must be a palette key. An ID that
  any inventory source already carries - a `fare_zones` record, a stop zone ID
  of any location type or a fare-rule reference - is rejected with the in-use
  message on `zone_id`, so a new zone never adopts the identity of an imported
  one. The check and the insert run in one version-locked transaction, and the
  returned zone is that version's inventory entry. A pair that is not a
  published version of the organization returns `:not_found` and writes nothing.
  """
  @spec create_zone(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, zone()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def create_zone(organization_id, gtfs_version_id, attrs) do
    transact(organization_id, gtfs_version_id, fn ->
      changeset =
        %FareZone{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
        |> FareZone.changeset(attrs, :new)
        |> reject_used_zone_id(organization_id, gtfs_version_id)

      if changeset.valid? do
        new_zone_id = Ecto.Changeset.get_change(changeset, :zone_id)
        persist_zone(changeset, nil, organization_id, gtfs_version_id, new_zone_id)
      else
        Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Edits a zone's metadata and, when the form changes it, its ID.

  The edit applies only while `current_zone_id` is in the version's inventory -
  a record, a stop zone ID of any location type or a fare-rule reference -
  otherwise it returns `:not_found` and writes nothing, so an edit that lost a
  race with the change that removed the zone never recreates it. A metadata edit
  keeps the stored ID bytes and updates the record, or inserts one for an
  implicit zone under exactly that ID, colored with the palette key the
  inventory already showed for it.

  A form `zone_id` that differs from `current_zone_id` both byte-for-byte and
  after trimming is a rename. The trimmed new ID is validated, rejected with the
  in-use message when the inventory already carries it, and otherwise written in
  one transaction to `stops.zone_id` of every location type, to
  `fare_rules.origin_id`, `destination_id` and `contains_id`, and to the metadata
  record; no row keeps the old ID, and every one of those writes uses the
  trimmed new ID. A form value that is the stored bytes or trims back to them is
  a metadata edit, not a rename. The returned zone is the inventory entry under
  the final ID. A pair that is not a published version of the organization
  returns `:not_found` and writes nothing.
  """
  @spec update_zone(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map()) ::
          {:ok, zone()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def update_zone(organization_id, gtfs_version_id, current_zone_id, attrs) do
    transact(organization_id, gtfs_version_id, fn ->
      if zone_exists?(organization_id, gtfs_version_id, current_zone_id) do
        update_zone_write(organization_id, gtfs_version_id, current_zone_id, attrs)
      else
        Repo.rollback(:not_found)
      end
    end)
  end

  @doc """
  Deletes a zone, moving its stops and fare-rule references to a replacement.

  The zone must still be in the version's inventory, otherwise the call rolls
  back `:not_found` and writes nothing. `expected` holds the boardable `stop_count`
  and `rule_count` the delete dialog showed: if either differs from the current
  inventory entry, the call rolls back `{:stale, zone}` with that entry, so a stop
  or rule the user never saw at confirm time cannot move unnoticed. A zone fare
  rules reference needs a `replacement`, otherwise `:replacement_required`.
  `replacement` may be nil only then, clearing the zone of every unreferenced
  stop; otherwise it must be another ID in the inventory or the call rolls back
  `:invalid_replacement`.

  Inside one version-locked transaction the zone's stops of every location type
  move to the exact replacement ID (nil unassigns them), every fare-rule row that
  mentions the zone in `origin_id`, `destination_id` or `contains_id` is rewritten
  with the exact replacement value and reinserted with a new ID, a rewritten row
  that would be identical to an unaffected row or to an earlier kept rewritten
  row is dropped, and the zone's metadata record is removed. Every other row keeps
  its bytes and timestamps, so no row references the deleted ID and no fare-rule
  group is destroyed or left orphaned. The result counts the stops whose zone
  changed, the rewritten rows kept and the affected rows dropped as duplicates. A
  pair that is not a published version of the organization returns `:not_found`
  and writes nothing.
  """
  @spec delete_zone(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t() | nil,
          %{stop_count: non_neg_integer(), rule_count: non_neg_integer()}
        ) ::
          {:ok,
           %{
             moved_stops: non_neg_integer(),
             rewritten_rows: non_neg_integer(),
             removed_duplicate_rows: non_neg_integer()
           }}
          | {:error, :not_found | :replacement_required | :invalid_replacement | {:stale, zone()}}
  def delete_zone(organization_id, gtfs_version_id, zone_id, replacement, expected) do
    transact(organization_id, gtfs_version_id, fn ->
      zone = inventory_zone(organization_id, gtfs_version_id, zone_id)

      cond do
        is_nil(zone) ->
          Repo.rollback(:not_found)

        stale_zone?(zone, expected) ->
          Repo.rollback({:stale, zone})

        zone.rule_count > 0 and is_nil(replacement) ->
          Repo.rollback(:replacement_required)

        not valid_replacement?(organization_id, gtfs_version_id, zone_id, replacement) ->
          Repo.rollback(:invalid_replacement)

        true ->
          delete_zone_write(organization_id, gtfs_version_id, zone_id, replacement)
      end
    end)
  end

  defp write_assignment(organization_id, gtfs_version_id, changes, opts) do
    changes = Enum.uniq_by(changes, & &1.id)

    transact(organization_id, gtfs_version_id, fn ->
      validate_targets(organization_id, gtfs_version_id, changes, opts)
      locked_stops = lock_selected_stops(organization_id, gtfs_version_id, changes)
      stale = stale_changes(locked_stops, changes)

      if stale != [] do
        Repo.rollback({:stale, stale})
      end

      write_zone_changes(organization_id, gtfs_version_id, changes)
      %{applied: changes}
    end)
  end

  # One transaction per write, opening with the organization's published version
  # row locked `FOR UPDATE` (precedent: `Calendars.published_version_for_update/2`).
  # That single row both validates the scope pair and serializes writers of this
  # version's zone aggregate; a pair that cannot be a published version - a
  # non-UUID argument included - rolls back `:not_found` without touching
  # anything.
  defp transact(organization_id, gtfs_version_id, fun) do
    Repo.transaction(fn -> lock_version_and_run(organization_id, gtfs_version_id, fun) end)
  end

  defp lock_version_and_run(organization_id, gtfs_version_id, fun) do
    version =
      if uuid?(organization_id) and uuid?(gtfs_version_id),
        do: published_version_for_update(organization_id, gtfs_version_id)

    case version do
      %GtfsVersion{} -> fun.()
      nil -> Repo.rollback(:not_found)
    end
  end

  defp published_version_for_update(organization_id, gtfs_version_id) do
    from(v in GtfsVersion,
      where:
        v.id == ^gtfs_version_id and v.organization_id == ^organization_id and
          v.publication_status == ^@published_status,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  # A preview has no lock to roll back to, so it returns the target error instead.
  defp validate_target(_organization_id, _gtfs_version_id, nil), do: :ok

  defp validate_target(organization_id, gtfs_version_id, target) when is_binary(target) do
    if zone_exists?(organization_id, gtfs_version_id, target),
      do: :ok,
      else: {:error, :unknown_zone}
  end

  defp validate_target(_organization_id, _gtfs_version_id, _target), do: {:error, :unknown_zone}

  defp validate_targets(organization_id, gtfs_version_id, changes, validate_targets?: true) do
    Enum.each(changes, &validate_target!(organization_id, gtfs_version_id, &1.to))
  end

  defp validate_targets(_organization_id, _gtfs_version_id, _changes, _opts), do: :ok

  defp validate_target!(organization_id, gtfs_version_id, target) do
    case validate_target(organization_id, gtfs_version_id, target) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A target exists when any of the three inventory sources carries the exact ID,
  # so a rule-referenced zone with no stops stays assignable.
  defp zone_exists?(organization_id, gtfs_version_id, zone_id) do
    declared_zone?(organization_id, gtfs_version_id, zone_id) or
      stop_zone?(organization_id, gtfs_version_id, zone_id) or
      rule_zone?(organization_id, gtfs_version_id, zone_id)
  end

  defp declared_zone?(organization_id, gtfs_version_id, zone_id) do
    Repo.exists?(
      from(z in FareZone,
        where:
          z.organization_id == ^organization_id and z.gtfs_version_id == ^gtfs_version_id and
            z.zone_id == ^zone_id
      )
    )
  end

  defp stop_zone?(organization_id, gtfs_version_id, zone_id) do
    Repo.exists?(
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
            s.zone_id == ^zone_id
      )
    )
  end

  defp rule_zone?(organization_id, gtfs_version_id, zone_id) do
    Repo.exists?(
      from(r in FareRule,
        where:
          r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
            (r.origin_id == ^zone_id or r.destination_id == ^zone_id or r.contains_id == ^zone_id)
      )
    )
  end

  defp selected_stops(organization_id, gtfs_version_id, stop_ids) do
    stops =
      organization_id
      |> boardable_query(gtfs_version_id)
      |> where([s], s.id in ^stop_ids)
      |> order_by([s], asc_nulls_last: s.stop_name, asc: s.stop_id)
      |> select([s], %{
        id: s.id,
        stop_id: s.stop_id,
        stop_name: s.stop_name,
        parent_station: s.parent_station,
        zone_id: s.zone_id
      })
      |> Repo.all()

    if length(stops) == length(stop_ids), do: {:ok, stops}, else: {:error, :invalid_selection}
  end

  defp assignment_row(stop, target) do
    %{
      id: stop.id,
      stop_id: stop.stop_id,
      stop_name: stop.stop_name,
      from: stop.zone_id,
      to: target
    }
  end

  defp change_of(%{id: id, from: from, to: to}), do: %{id: id, from: from, to: to}

  defp unselected_sibling_count(organization_id, gtfs_version_id, stops) do
    parent_stations =
      stops |> Enum.map(& &1.parent_station) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if parent_stations == [] do
      0
    else
      selected_ids = Enum.map(stops, & &1.id)

      organization_id
      |> boardable_query(gtfs_version_id)
      |> where([s], s.parent_station in ^parent_stations and s.id not in ^selected_ids)
      |> Repo.aggregate(:count)
    end
  end

  # The locked re-read is the fence: a stop missing from the scoped, boardable
  # result is a selection of another organization, version or location type, and
  # any stop whose locked zone differs from the reviewed value makes the whole
  # call roll back before a single write.
  defp lock_selected_stops(organization_id, gtfs_version_id, changes) do
    ids = Enum.map(changes, & &1.id)

    stops =
      organization_id
      |> boardable_query(gtfs_version_id)
      |> where([s], s.id in ^ids)
      |> select([s], %{
        id: s.id,
        stop_id: s.stop_id,
        stop_name: s.stop_name,
        zone_id: s.zone_id
      })
      |> lock("FOR UPDATE")
      |> Repo.all()

    if length(stops) != length(ids), do: Repo.rollback(:invalid_selection)
    stops
  end

  defp stale_changes(stops, changes) do
    current = Map.new(stops, &{&1.id, &1.zone_id})
    stop_by_id = Map.new(stops, &{&1.id, &1})

    changes
    |> Enum.filter(fn change -> Map.get(current, change.id) != change.from end)
    |> Enum.map(fn change ->
      stop = Map.fetch!(stop_by_id, change.id)

      %{
        id: change.id,
        stop_id: stop.stop_id,
        stop_name: stop.stop_name,
        reviewed: change.from,
        current: Map.get(current, change.id)
      }
    end)
  end

  defp write_zone_changes(organization_id, gtfs_version_id, changes) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changes
    |> Enum.group_by(& &1.to)
    |> Enum.each(fn {target, group} ->
      ids = Enum.map(group, & &1.id)

      organization_id
      |> boardable_query(gtfs_version_id)
      |> where([s], s.id in ^ids)
      |> Repo.update_all(set: [zone_id: target, updated_at: now])
    end)
  end

  # Only a form `zone_id` that is a different ID after trimming is an ID change;
  # a missing or non-string value is a metadata edit, which never casts
  # `zone_id`. The exact bytes are compared first, so the stored ID of an
  # imported zone such as `" A"` survives the drawer re-sending it verbatim or
  # with padding, while `"A"` and `" A"` stay different zones that rename each
  # other.
  defp changed_zone_id(current_zone_id, attrs) do
    case Map.get(attrs, "zone_id", Map.get(attrs, :zone_id)) do
      ^current_zone_id ->
        :same

      value when is_binary(value) ->
        case String.trim(value) do
          ^current_zone_id -> :same
          trimmed -> {:change, trimmed}
        end

      _other ->
        :same
    end
  end

  defp update_zone_write(organization_id, gtfs_version_id, current_zone_id, attrs) do
    record = zone_record(organization_id, gtfs_version_id, current_zone_id)

    struct =
      record ||
        %FareZone{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          zone_id: current_zone_id,
          color: FareZone.default_color(current_zone_id)
        }

    case changed_zone_id(current_zone_id, attrs) do
      :same ->
        changeset = FareZone.changeset(struct, attrs, :keep)

        if changeset.valid? do
          persist_zone(changeset, record, organization_id, gtfs_version_id, current_zone_id)
        else
          Repo.rollback(changeset)
        end

      {:change, new_zone_id} ->
        # The same `new_zone_id` reaches the stops, the fare rules and the
        # record: `:new` validates the form, and the change is pinned to the
        # trimmed value so Ecto cannot drop it as "unchanged" and leave the
        # record on the old ID.
        changeset =
          struct
          |> FareZone.changeset(attrs, :new)
          |> Ecto.Changeset.put_change(:zone_id, new_zone_id)
          |> reject_used_zone_id(organization_id, gtfs_version_id)

        if changeset.valid? do
          rewrite_zone_id(organization_id, gtfs_version_id, current_zone_id, new_zone_id)
          persist_zone(changeset, record, organization_id, gtfs_version_id, new_zone_id)
        else
          Repo.rollback(changeset)
        end
    end
  end

  # An ID is in use when any inventory source already carries it: a record, a
  # stop of any location type or a fare-rule reference. The unique index covers
  # only the record, so this check is what rejects an ID carried by stops alone.
  defp reject_used_zone_id(changeset, organization_id, gtfs_version_id) do
    case Ecto.Changeset.get_change(changeset, :zone_id) do
      zone_id when is_binary(zone_id) ->
        if zone_exists?(organization_id, gtfs_version_id, zone_id) do
          Ecto.Changeset.add_error(changeset, :zone_id, FareZone.zone_id_in_use_message())
        else
          changeset
        end

      _other ->
        changeset
    end
  end

  # An ID change moves the exact new ID on every location type - a station or
  # entrance carries a zone ID too - and in all three fare-rule zone columns. The
  # new ID was not in the inventory, so no rewritten fare rule can become
  # identical to another row and hit the unique row index.
  defp rewrite_zone_id(organization_id, gtfs_version_id, current_zone_id, new_zone_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.zone_id == ^current_zone_id
    )
    |> Repo.update_all(set: [zone_id: new_zone_id, updated_at: now])

    organization_id
    |> rule_scope(gtfs_version_id)
    |> where([r], r.origin_id == ^current_zone_id)
    |> Repo.update_all(set: [origin_id: new_zone_id, updated_at: now])

    organization_id
    |> rule_scope(gtfs_version_id)
    |> where([r], r.destination_id == ^current_zone_id)
    |> Repo.update_all(set: [destination_id: new_zone_id, updated_at: now])

    organization_id
    |> rule_scope(gtfs_version_id)
    |> where([r], r.contains_id == ^current_zone_id)
    |> Repo.update_all(set: [contains_id: new_zone_id, updated_at: now])
  end

  defp rule_scope(organization_id, gtfs_version_id) do
    from(r in FareRule,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id
    )
  end

  defp zone_record(organization_id, gtfs_version_id, zone_id) do
    Repo.one(
      from(z in FareZone,
        where:
          z.organization_id == ^organization_id and z.gtfs_version_id == ^gtfs_version_id and
            z.zone_id == ^zone_id
      )
    )
  end

  defp persist_zone(changeset, record, organization_id, gtfs_version_id, zone_id) do
    result = if record, do: Repo.update(changeset), else: Repo.insert(changeset)

    case result do
      {:ok, _zone} -> inventory_zone(organization_id, gtfs_version_id, zone_id)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # The inventory entry of one zone, or nil when the ID is not in the inventory.
  # A caller inside a write that just put the ID in the inventory always
  # resolves; `delete_zone/5` uses the nil result as its `:not_found` check, and
  # so does the stale fence's comparison against the counts the dialog showed.
  defp inventory_zone(organization_id, gtfs_version_id, zone_id) do
    organization_id
    |> inventory(gtfs_version_id)
    |> Map.fetch!(:zones)
    |> Enum.find(&(&1.zone_id == zone_id))
  end

  defp stale_zone?(zone, expected) do
    zone.stop_count != expected.stop_count or zone.rule_count != expected.rule_count
  end

  # nil is the unreferenced-zone unassign case, checked before this runs. Any
  # other replacement must be a different zone the inventory carries; a
  # non-string value can never be a zone ID and is refused rather than compared.
  defp valid_replacement?(_organization_id, _gtfs_version_id, _zone_id, nil), do: true

  defp valid_replacement?(organization_id, gtfs_version_id, zone_id, replacement)
       when is_binary(replacement) do
    replacement != zone_id and zone_exists?(organization_id, gtfs_version_id, replacement)
  end

  defp valid_replacement?(_organization_id, _gtfs_version_id, _zone_id, _other), do: false

  # A deletion rebuilds the affected fare rules in memory: read the version's
  # rows once, rewrite the ones that mention the zone, drop the rewritten
  # duplicates, delete the affected rows and insert the survivors with new IDs.
  # The planning envelope is a few thousand fare-rules rows per version, which is
  # why one in-memory pass is enough. If a version ever exceeds it, replace this
  # with set-based SQL: one UPDATE over the three zone columns, then a DELETE of
  # the rows the seven-column unique index would reject.
  defp delete_zone_write(organization_id, gtfs_version_id, zone_id, replacement) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {moved_stops, nil} =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
            s.zone_id == ^zone_id
      )
      |> Repo.update_all(set: [zone_id: replacement, updated_at: now])

    {affected, unaffected} =
      organization_id
      |> list_rows(gtfs_version_id)
      |> Enum.split_with(&references_zone?(&1, zone_id))

    {kept, removed_duplicate_rows} =
      deduplicate_rule_rows(affected, unaffected, zone_id, replacement)

    delete_rule_rows(organization_id, gtfs_version_id, Enum.map(affected, & &1.id))
    insert_rule_rows(organization_id, gtfs_version_id, kept, now)
    delete_zone_record(organization_id, gtfs_version_id, zone_id)

    %{
      moved_stops: moved_stops,
      rewritten_rows: length(kept),
      removed_duplicate_rows: removed_duplicate_rows
    }
  end

  defp references_zone?(row, zone_id) do
    row.origin_id == zone_id or row.destination_id == zone_id or row.contains_id == zone_id
  end

  # A rewritten row is dropped only when the five-field tuple it would become is
  # already present, so a legitimate row is never removed and only identical
  # rows merge.
  defp deduplicate_rule_rows(affected, unaffected, zone_id, replacement) do
    seen = MapSet.new(unaffected, &rule_values/1)

    {kept, _seen} =
      Enum.reduce(affected, {[], seen}, fn row, {kept, seen} ->
        rewritten = rewrite_rule_row(row, zone_id, replacement)
        values = rule_values(rewritten)

        if MapSet.member?(seen, values) do
          {kept, seen}
        else
          {[rewritten | kept], MapSet.put(seen, values)}
        end
      end)

    kept = Enum.reverse(kept)
    {kept, length(affected) - length(kept)}
  end

  defp rewrite_rule_row(row, zone_id, replacement) do
    %{
      row
      | origin_id: replace_zone(row.origin_id, zone_id, replacement),
        destination_id: replace_zone(row.destination_id, zone_id, replacement),
        contains_id: replace_zone(row.contains_id, zone_id, replacement)
    }
  end

  defp replace_zone(value, zone_id, replacement) do
    if value == zone_id, do: replacement, else: value
  end

  defp rule_values(row) do
    {row.fare_id, row.route_id, row.origin_id, row.destination_id, row.contains_id}
  end

  defp delete_rule_rows(_organization_id, _gtfs_version_id, []), do: :ok

  defp delete_rule_rows(organization_id, gtfs_version_id, ids) do
    organization_id
    |> rule_scope(gtfs_version_id)
    |> where([r], r.id in ^ids)
    |> Repo.delete_all()
  end

  defp insert_rule_rows(_organization_id, _gtfs_version_id, [], _now), do: :ok

  defp insert_rule_rows(organization_id, gtfs_version_id, rows, now) do
    rows =
      Enum.map(rows, fn row ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          fare_id: row.fare_id,
          route_id: row.route_id,
          origin_id: row.origin_id,
          destination_id: row.destination_id,
          contains_id: row.contains_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(FareRule, rows)
  end

  defp delete_zone_record(organization_id, gtfs_version_id, zone_id) do
    from(z in FareZone,
      where:
        z.organization_id == ^organization_id and z.gtfs_version_id == ^gtfs_version_id and
          z.zone_id == ^zone_id
    )
    |> Repo.delete_all()
  end

  defp boardable_query(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.location_type == 0
    )
  end

  defp apply_filter(query, :all), do: query
  defp apply_filter(query, :unassigned), do: where(query, [s], is_nil(s.zone_id))

  defp apply_filter(query, {:zone, zone_id}) do
    where(query, [s], s.zone_id == ^zone_id)
  end

  defp apply_search(query, nil), do: query
  defp apply_search(query, ""), do: query

  defp apply_search(query, q) when is_binary(q) do
    pattern = "%" <> GtfsPlanner.Gtfs.escape_like_pattern(q) <> "%"
    where(query, [s], ilike(s.stop_name, ^pattern) or ilike(s.stop_id, ^pattern))
  end

  defp restrict_to_ids(query, nil), do: query
  defp restrict_to_ids(query, []), do: where(query, [s], false)
  defp restrict_to_ids(query, ids), do: where(query, [s], s.id in ^ids)

  defp unlocated_stops(organization_id, gtfs_version_id, filter) do
    organization_id
    |> boardable_query(gtfs_version_id)
    |> apply_filter(filter)
    |> where([s], is_nil(s.stop_lat) or is_nil(s.stop_lon))
  end

  defp count_stops(query), do: Repo.aggregate(query, :count)

  defp clamp_page(page, total_count, per_page) do
    last_page = max(div(total_count + per_page - 1, per_page), 1)
    page |> max(1) |> min(last_page)
  end

  defp list_rows(organization_id, gtfs_version_id) do
    from(r in FareRule,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      select: %{
        id: r.id,
        fare_id: r.fare_id,
        route_id: r.route_id,
        origin_id: r.origin_id,
        destination_id: r.destination_id,
        contains_id: r.contains_id
      }
    )
    |> Repo.all()
  end

  defp group_key(row) do
    {row.fare_id, row.route_id, row.origin_id, row.destination_id, not is_nil(row.contains_id)}
  end

  defp build_group(
         {fare_id, route_id, origin_id, destination_id, _contains?} = key,
         rows,
         fares,
         routes
       ) do
    fare = Map.get(fares, fare_id)
    route = route_id && Map.get(routes, route_id)

    %{
      key: key,
      fare_id: fare_id,
      route_id: route_id,
      origin_id: origin_id,
      destination_id: destination_id,
      contains:
        rows
        |> Enum.map(& &1.contains_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort(),
      rows: Enum.sort_by(rows, & &1.id),
      fare: fare,
      route: route,
      unknown_fare?: is_nil(fare),
      unknown_route?: not is_nil(route_id) and is_nil(route)
    }
  end

  defp fare_index(_organization_id, _gtfs_version_id, []), do: %{}

  defp fare_index(organization_id, gtfs_version_id, fare_ids) do
    from(a in FareAttribute,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
          a.fare_id in ^Enum.uniq(fare_ids),
      select: {a.fare_id, a.price, a.currency_type}
    )
    |> Repo.all()
    |> Map.new(fn {fare_id, price, currency_type} ->
      {fare_id, %{price: price, currency_type: currency_type}}
    end)
  end

  defp route_index(organization_id, gtfs_version_id, route_ids) do
    route_ids = route_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if route_ids == [] do
      %{}
    else
      from(r in Route,
        where:
          r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
            r.route_id in ^route_ids,
        select: {r.route_id, r.route_short_name, r.route_long_name}
      )
      |> Repo.all()
      |> Map.new(fn {route_id, short_name, long_name} ->
        {route_id, %{short_name: short_name, long_name: long_name}}
      end)
    end
  end

  defp sort_key(group) do
    {group.fare_id, group.origin_id, group.destination_id, group.route_id, elem(group.key, 4)}
  end

  defp stop_zone_counts(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          not is_nil(s.zone_id),
      group_by: s.zone_id,
      select: {
        s.zone_id,
        filter(count(s.id), s.location_type == 0),
        filter(count(s.id), s.location_type != 0)
      }
    )
    |> Repo.all()
    |> Map.new(fn {zone_id, stop_count, other_stop_count} ->
      {zone_id, {stop_count, other_stop_count}}
    end)
  end

  defp boardable_counts(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.location_type == 0,
      select: {count(s.id), filter(count(s.id), is_nil(s.zone_id))}
    )
    |> Repo.one()
  end

  defp declared_zones(organization_id, gtfs_version_id) do
    from(z in FareZone,
      where: z.organization_id == ^organization_id and z.gtfs_version_id == ^gtfs_version_id,
      select: {z.zone_id, %{name: z.name, color: z.color}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp rule_zone_counts(organization_id, gtfs_version_id) do
    organization_id
    |> list_rule_groups(gtfs_version_id)
    |> Enum.reduce(%{}, fn group, counts ->
      group
      |> referenced_zone_ids()
      |> Enum.reduce(counts, fn zone_id, counts -> Map.update(counts, zone_id, 1, &(&1 + 1)) end)
    end)
  end

  defp referenced_zone_ids(group) do
    [group.origin_id, group.destination_id | group.contains]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp build_zone(zone_id, declared, stop_counts, rule_counts) do
    record = Map.get(declared, zone_id)
    {stop_count, other_stop_count} = Map.get(stop_counts, zone_id, {0, 0})

    %{
      zone_id: zone_id,
      name: if(record, do: record.name, else: zone_id),
      color: if(record, do: record.color, else: FareZone.default_color(zone_id)),
      declared?: not is_nil(record),
      stop_count: stop_count,
      other_stop_count: other_stop_count,
      rule_count: Map.get(rule_counts, zone_id, 0)
    }
  end
end
