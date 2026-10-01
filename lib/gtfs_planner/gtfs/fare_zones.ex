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

  Each write takes an `AuditContext` built from trusted server state. Its
  transaction checks the actor's current editor membership before locking the
  published version or reading entities; revoked access returns `:forbidden`.

  `list_rule_groups/2` is the read side of the rule projection. One UI fare rule
  is exactly the set of `fare_rules` rows sharing `(fare_id, route_id, origin_id,
  destination_id, contains_id IS NOT NULL)`: a `contains_id` of NULL forms the
  rule for the journey itself, and rows with a `contains_id` form one rule whose
  `contains` values are the through zones. Every row of the version belongs to
  exactly one group, duplicate rows included, so the projection is lossless.
  Trip planners do not read the groups apart: they combine every group of one
  fare, so `list_combined_fares/2` reports the fares whose groups disagree.

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

  Reviewed bulk assignment uses `preview_assignment/4`, `apply_assignment/2`
  and `undo_assignment/2`. A preview is a read that reports
  each selected boardable stop's current and target zone; an apply writes the
  reviewed changes in one transaction that first locks the actor's membership
  `FOR SHARE` and then the organization's published version row `FOR UPDATE`,
  so cooperating writers of one version
  serialize and a pair that is not a published version of the organization
  changes nothing (`:not_found`). Every change is fenced: the locked current zone
  must still equal the reviewed `from`, otherwise nothing is written and the
  changed stops are returned. `undo_assignment/2` takes exactly the `applied`
  list of a successful apply, swaps its values back and restores them without
  inventory validation, so a zone that left the inventory when its last stop
  moved is restored byte-for-byte. Only boardable stops are assignable and only
  a zone in the inventory can be an assignment target.

  Zone metadata is written by `create_zone/2` and `update_zone/3`, both inside
  the same version-locked transaction. `update_zone/3` edits only a zone that is
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

  `delete_zone/4` removes a zone inside the same version-locked transaction. It
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

  The rule drawer's reads are `list_fares/2` and `list_rule_routes/2`, and its
  form is `change_rule_group/2`. `save_rule_group/3` writes one reviewed rule
  inside the same version-locked transaction: it fences the review against the
  version's current rows under the reviewed key, refuses a fare, route or zone
  outside the version, refuses a new reference to a stopless zone and a key
  another rule already holds, then deletes exactly the reviewed rows and inserts
  one row per contains zone (or one row without a `contains_id`) with the exact
  chosen values. `delete_rule_group/2` removes exactly the reviewed rows under
  the same fence. So a rule edit can neither merge two rules, orphan a row, trim
  an ID nor overwrite a review the user never saw.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"

  @rule_key_message "A rule with this fare, route, start and end already exists. Edit that rule instead."
  @stopless_zone_message "This zone has no stops yet. Assign stops before using it in a fare rule."
  @unknown_fare_message "This fare is not in this version. Choose another."
  @unknown_route_message "This route is not in this version. Choose another."
  @unknown_zone_message "This zone is not in this version. Choose another."

  # The drawer's form fields. `contains` is a list of through zones; the four
  # scalars are strings, where an empty string means "any".
  @rule_group_fields %{
    fare_id: :string,
    route_id: :string,
    origin_id: :string,
    destination_id: :string,
    contains: {:array, :string}
  }
  @rule_group_field_names Map.keys(@rule_group_fields)

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

  @type combined_fare :: %{
          fare_id: String.t(),
          route_ids: [String.t() | nil],
          contains: [String.t()],
          routes_differ?: boolean(),
          contains_differ?: boolean()
        }

  @type checks :: %{
          stopless_referenced: [zone()],
          unassigned_count: non_neg_integer(),
          empty_declared: [zone()],
          rules_reference_zones?: boolean(),
          combined_fares: [combined_fare()]
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

    project_rule_groups(rules, fares, routes)
  end

  @doc """
  Lists the version's fares whose rule groups disagree on route or through zones.

  Trip planners do not read a fare's rules one by one. OpenTripPlanner builds one
  rule set per `fare_id`: the origin and destination pairs are alternatives, but
  the routes named on any row apply to every pair, and the `contains_id` zones of
  all rows are one set that a journey's zones must equal. So a fare whose groups
  do not all share one `route_id` (nil is the value "all routes") or one
  `contains` set applies differently than each rule alone reads.

  Each entry is `find_combined_fares/1` over this version's groups, ordered by
  `fare_id`. It reads the `fare_rules` rows once and projects them with the same
  grouping as `list_rule_groups/2`. A pair that is not a version of the
  organization returns an empty list.
  """
  @spec list_combined_fares(Ecto.UUID.t(), Ecto.UUID.t()) :: [combined_fare()]
  def list_combined_fares(organization_id, gtfs_version_id) do
    organization_id
    |> list_rows(gtfs_version_id)
    |> project_rule_groups(%{}, %{})
    |> find_combined_fares()
  end

  @doc """
  The fares among `groups` whose rules disagree on route or through zones.

  `groups` need only carry `fare_id`, `route_id` and `contains`, so the rule
  drawer can add the rule it is editing to the page's own groups. A fare is
  reported when its groups do not all share the same `route_id` (`routes_differ?`)
  or the same sorted `contains` set (`contains_differ?`). `route_ids` lists the
  distinct route IDs with nil, "all routes", first, and `contains` the union of
  the fare's through zones.
  """
  @spec find_combined_fares([map()]) :: [combined_fare()]
  def find_combined_fares(groups) do
    groups
    |> Enum.group_by(& &1.fare_id)
    |> Enum.flat_map(fn {fare_id, fare_groups} -> combined_fare(fare_id, fare_groups) end)
    |> Enum.sort_by(& &1.fare_id)
  end

  defp combined_fare(fare_id, groups) do
    route_ids = groups |> Enum.map(& &1.route_id) |> Enum.uniq() |> Enum.sort()

    contains_sets =
      groups |> Enum.map(&(&1.contains |> Enum.uniq() |> Enum.sort())) |> Enum.uniq()

    routes_differ? = length(route_ids) > 1
    contains_differ? = length(contains_sets) > 1

    if routes_differ? or contains_differ? do
      [
        %{
          fare_id: fare_id,
          route_ids: route_ids,
          contains: contains_sets |> Enum.concat() |> Enum.uniq() |> Enum.sort(),
          routes_differ?: routes_differ?,
          contains_differ?: contains_differ?
        }
      ]
    else
      []
    end
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
  `empty_declared` the declared zones that have no stops and no rules,
  `rules_reference_zones?` whether any fare rule references a zone at all and
  `combined_fares` the fares from `list_combined_fares/2`.
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
      rules_reference_zones?: Enum.any?(zones, &(&1.rule_count > 0)),
      combined_fares: list_combined_fares(organization_id, gtfs_version_id)
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
  transaction the actor's membership is checked and the published version row
  is locked `FOR UPDATE` before the selected
  stops are locked and re-read: if any stop's current zone differs from its
  reviewed `from`, the transaction rolls back with
  `{:stale, [%{id, stop_id, stop_name, reviewed, current}]}` and nothing is
  written. Otherwise one `update_all/3` per distinct target writes the exact
  zone ID (nil for unassign) and `updated_at`, and the applied changes are
  returned for `undo_assignment/2`. A pair that is not a published version of the
  organization returns `:not_found` and changes nothing.
  """
  @spec apply_assignment(AuditContext.t(), [assignment_change()]) ::
          {:ok, %{applied: [assignment_change()]}}
          | {:error,
             {:stale, [stale_stop()]}
             | :invalid_selection
             | :unknown_zone
             | :not_found
             | :forbidden}
  def apply_assignment(%AuditContext{} = audit, changes) do
    write_assignment(audit, changes, validate_targets?: true)
  end

  @doc """
  Restores the zones an `apply_assignment/2` replaced, under the same fence.

  Call only with the exact `applied` list returned by a successful
  `apply_assignment/2`: the values are swapped back and written with no inventory
  validation, so a zone that left the inventory when its last stop moved, or was
  unassigned, is restored byte-for-byte. The same transaction, version-row lock,
  selection check and stale fence apply: if any stop changed after the save,
  nothing is written and `{:error, {:stale, stops}}` is returned. `:not_found`
  means the pair is not a published version of the organization.
  """
  @spec undo_assignment(AuditContext.t(), [assignment_change()]) ::
          {:ok, %{applied: [assignment_change()]}}
          | {:error, {:stale, [stale_stop()]} | :invalid_selection | :not_found | :forbidden}
  def undo_assignment(%AuditContext{} = audit, applied) do
    changes = Enum.map(applied, &%{id: &1.id, from: &1.to, to: &1.from})
    write_assignment(audit, changes, validate_targets?: false)
  end

  @doc """
  The zone drawer's changeset for a create or an edit form.

  `nil` starts a new zone: the ID is cast, trimmed and validated. For an
  existing zone the form's `zone_id` is an ID change only when neither its exact
  bytes nor its trimmed bytes are the stored ID. Otherwise it is a metadata edit,
  and `:keep` never casts the ID: the drawer can re-send an imported `" A"` or
  `"Zone 1"` verbatim, padding included, and those bytes are neither trimmed nor
  revalidated. A rename is trimmed and validated like a new ID. `create_zone/2`
  and `update_zone/3` make the same decision from the same form values.
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
  @spec create_zone(AuditContext.t(), map()) ::
          {:ok, zone()} | {:error, Ecto.Changeset.t()} | {:error, :not_found | :forbidden}
  def create_zone(%AuditContext{} = audit, attrs) do
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id

    transact(audit, fn ->
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
  @spec update_zone(AuditContext.t(), String.t(), map()) ::
          {:ok, zone()} | {:error, Ecto.Changeset.t()} | {:error, :not_found | :forbidden}
  def update_zone(%AuditContext{} = audit, current_zone_id, attrs) do
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id

    transact(audit, fn ->
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
          AuditContext.t(),
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
          | {:error,
             :not_found
             | :forbidden
             | :replacement_required
             | :invalid_replacement
             | {:stale, zone()}}
  def delete_zone(%AuditContext{} = audit, zone_id, replacement, expected) do
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id

    transact(audit, fn ->
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

  @doc """
  Lists the version's fare attributes for the rule drawer's fare options.

  Each entry is `%{fare_id, price, currency_type}`, ordered by `fare_id`. A pair
  that is not a version of the organization returns an empty list.
  """
  @spec list_fares(Ecto.UUID.t(), Ecto.UUID.t()) :: [
          %{fare_id: String.t(), price: Decimal.t(), currency_type: String.t()}
        ]
  def list_fares(organization_id, gtfs_version_id) do
    from(a in FareAttribute,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
      order_by: a.fare_id,
      select: %{fare_id: a.fare_id, price: a.price, currency_type: a.currency_type}
    )
    |> Repo.all()
  end

  @doc """
  Lists the version's routes for the rule drawer's route options.

  Each entry is `%{route_id, short_name, long_name}`, ordered by `route_id`. A
  pair that is not a version of the organization returns an empty list.
  """
  @spec list_rule_routes(Ecto.UUID.t(), Ecto.UUID.t()) :: [
          %{route_id: String.t(), short_name: String.t() | nil, long_name: String.t() | nil}
        ]
  def list_rule_routes(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: r.route_id,
      select: %{
        route_id: r.route_id,
        short_name: r.route_short_name,
        long_name: r.route_long_name
      }
    )
    |> Repo.all()
  end

  @doc """
  The rule drawer's schemaless changeset for a create or an edit form.

  `nil` starts a new rule; a reviewed group seeds the form with its current fare,
  route, origin, destination and contains zones, so an untouched field keeps the
  values the drawer showed. An empty string in a fare, route, origin or
  destination becomes nil, which is how the drawer's "Any origin", "Any
  destination" and "All routes" arrive; `contains` is deduplicated, empty entries
  dropped and a nil or empty list kept empty. `fare_id` is required. The same
  changeset seeds `save_rule_group/3`, so the form checks what the save will do;
  the save adds its own field errors for the values only the database can settle.
  """
  @spec change_rule_group(rule_group() | nil, map()) :: Ecto.Changeset.t()
  def change_rule_group(reviewed, attrs) do
    {rule_group_data(reviewed), @rule_group_fields}
    |> Ecto.Changeset.cast(attrs, @rule_group_field_names)
    |> Ecto.Changeset.update_change(:fare_id, &empty_to_nil/1)
    |> Ecto.Changeset.update_change(:route_id, &empty_to_nil/1)
    |> Ecto.Changeset.update_change(:origin_id, &empty_to_nil/1)
    |> Ecto.Changeset.update_change(:destination_id, &empty_to_nil/1)
    |> Ecto.Changeset.update_change(:contains, &contains_list/1)
    |> Ecto.Changeset.validate_required([:fare_id])
  end

  @doc """
  Saves one reviewed rule group, replacing exactly its rows.

  `reviewed` is the group the drawer showed, or nil for a new rule. When it is
  given, the version's rows under its key must still be exactly `reviewed.rows`
  (IDs and the five values), otherwise the call rolls back `:stale` and writes
  nothing - a rule another editor renamed a zone in, extended with a member,
  moved to another key or removed cannot be overwritten from a review the user
  never saw again.

  A save is refused with a changeset whose field errors the drawer renders: a
  fare that is not in `fare_attributes` and is not the rule's current fare, a
  route that is not in `routes` and is not the rule's current route, a zone that
  is not in the version's inventory, a zone with no boardable stops that the
  reviewed rule did not already reference, and a key another rule holds - so a
  save can neither create a reference it cannot serve nor merge two rules into
  one. Otherwise the reviewed rows are deleted and one row is inserted per
  contains zone, or one row without a `contains_id`, carrying the exact chosen
  values (never through `FareRule.changeset/2`, which trims), and the saved group
  is returned. A pair that is not a published version of the organization returns
  `:not_found` and writes nothing.
  """
  @spec save_rule_group(AuditContext.t(), rule_group() | nil, map()) ::
          {:ok, rule_group()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :stale | :not_found | :forbidden}
  def save_rule_group(%AuditContext{} = audit, reviewed, attrs) do
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id

    transact(audit, fn ->
      save_rule_group_write(organization_id, gtfs_version_id, reviewed, attrs)
    end)
  end

  @doc """
  Removes one reviewed rule group, deleting exactly its rows.

  `reviewed` is the group the drawer showed, fenced exactly as `save_rule_group/3`
  fences a save: the version's rows under its key must still be `reviewed.rows`
  (IDs and the five values), otherwise the call rolls back `:stale` and writes
  nothing. Otherwise the reviewed rows are deleted and their count returned; the
  fare attribute is untouched. A pair that is not a published version of the
  organization returns `:not_found` and writes nothing.
  """
  @spec delete_rule_group(AuditContext.t(), rule_group()) ::
          {:ok, non_neg_integer()} | {:error, :stale | :not_found | :forbidden}
  def delete_rule_group(%AuditContext{} = audit, reviewed) do
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id

    transact(audit, fn ->
      if stale_rule_review?(list_rows(organization_id, gtfs_version_id), reviewed) do
        Repo.rollback(:stale)
      else
        delete_rule_rows(organization_id, gtfs_version_id, reviewed_row_ids(reviewed))
      end
    end)
  end

  defp write_assignment(%AuditContext{} = audit, changes, opts) do
    changes = Enum.uniq_by(changes, & &1.id)
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id

    transact(audit, fn ->
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

  # Membership is checked on every write attempt before the published version
  # lock. The version row then validates the selected scope and serializes zone
  # writers; an invalid or unpublished version rolls back with :not_found.
  defp transact(%AuditContext{} = audit, fun) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(audit)
      lock_version_and_run(audit.organization_id, audit.gtfs_version_id, fun)
    end)
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

  # One check per distinct target: a select-all review sends thousands of changes
  # that share a single target, and each check is up to three queries.
  defp validate_targets(organization_id, gtfs_version_id, changes, validate_targets?: true) do
    changes
    |> Enum.map(& &1.to)
    |> Enum.uniq()
    |> Enum.each(&validate_target!(organization_id, gtfs_version_id, &1))
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
  # resolves; `delete_zone/4` uses the nil result as its `:not_found` check, and
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

  defp delete_rule_rows(organization_id, gtfs_version_id, ids) do
    {deleted, nil} =
      organization_id
      |> rule_scope(gtfs_version_id)
      |> where([r], r.id in ^ids)
      |> Repo.delete_all()

    deleted
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

  # The stale fence compares the version's rows under the reviewed key as a set
  # of ID plus the five values. A member added to the key, a renamed zone that
  # moved the rows to another key, a deleted row and a replaced rule all leave a
  # different set, so a review the user never saw again never overwrites rows.
  defp stale_rule_review?(current_rows, reviewed) do
    key = reviewed.key

    current_rows
    |> Enum.filter(&(group_key(&1) == key))
    |> rule_row_set()
    |> Kernel.!=(rule_row_set(reviewed.rows))
  end

  defp rule_row_set(rows), do: MapSet.new(rows, &rule_row_values/1)

  defp rule_row_values(row) do
    {row.id, row.fare_id, row.route_id, row.origin_id, row.destination_id, row.contains_id}
  end

  defp reviewed_row_ids(nil), do: []
  defp reviewed_row_ids(reviewed), do: Enum.map(reviewed.rows, & &1.id)

  defp save_rule_group_write(organization_id, gtfs_version_id, reviewed, attrs) do
    current_rows = list_rows(organization_id, gtfs_version_id)

    if reviewed != nil and stale_rule_review?(current_rows, reviewed) do
      Repo.rollback(:stale)
    end

    changeset =
      change_rule_group(reviewed, attrs)
      |> validate_rule_group(organization_id, gtfs_version_id, reviewed, current_rows)

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, data} ->
        delete_rule_rows(organization_id, gtfs_version_id, reviewed_row_ids(reviewed))
        insert_saved_rule_rows(organization_id, gtfs_version_id, data)
        saved_rule_group(organization_id, gtfs_version_id, rule_group_key(data))

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  # Only a format-valid form reaches the database checks, so a blank fare keeps
  # its single "can't be blank" error instead of a second message about a version
  # catalog the user never got to choose from.
  defp validate_rule_group(changeset, organization_id, gtfs_version_id, reviewed, current_rows) do
    if changeset.valid? do
      data = Ecto.Changeset.apply_changes(changeset)

      changeset
      |> validate_rule_fare(organization_id, gtfs_version_id, reviewed, data)
      |> validate_rule_route(organization_id, gtfs_version_id, reviewed, data)
      |> validate_rule_zones(organization_id, gtfs_version_id, reviewed, data)
      |> validate_rule_key(current_rows, reviewed, data)
    else
      changeset
    end
  end

  defp validate_rule_fare(changeset, organization_id, gtfs_version_id, reviewed, data) do
    known? =
      organization_id
      |> list_fares(gtfs_version_id)
      |> MapSet.new(& &1.fare_id)
      |> MapSet.member?(data.fare_id)

    # The rule's own fare stays usable even when `fare_attributes` has no row for
    # it, so an imported rule with an unknown fare remains editable.
    if known? or data.fare_id == reviewed_value(reviewed, :fare_id) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :fare_id, @unknown_fare_message)
    end
  end

  defp validate_rule_route(changeset, organization_id, gtfs_version_id, reviewed, data) do
    known? =
      organization_id
      |> list_rule_routes(gtfs_version_id)
      |> Enum.any?(&(&1.route_id == data.route_id))

    cond do
      is_nil(data.route_id) -> changeset
      known? -> changeset
      data.route_id == reviewed_value(reviewed, :route_id) -> changeset
      true -> Ecto.Changeset.add_error(changeset, :route_id, @unknown_route_message)
    end
  end

  # Every chosen zone must be one the version's inventory carries, and a zone the
  # reviewed rule did not already reference must have a boardable stop, so a rule
  # cannot gain a reference the fare could never serve. A reference the rule
  # already had may stay, so an imported rule that cites a stopless zone remains
  # editable. Each error lands on the field the user chose it in.
  defp validate_rule_zones(changeset, organization_id, gtfs_version_id, reviewed, data) do
    zones = Map.new(inventory(organization_id, gtfs_version_id).zones, &{&1.zone_id, &1})
    kept = reviewed_zone_ids(reviewed)

    data
    |> rule_zone_selections()
    |> Enum.reduce(changeset, fn {field, zone_id}, changeset ->
      cond do
        is_nil(zone_id) ->
          changeset

        not Map.has_key?(zones, zone_id) ->
          Ecto.Changeset.add_error(changeset, field, @unknown_zone_message)

        not MapSet.member?(kept, zone_id) and Map.fetch!(zones, zone_id).stop_count == 0 ->
          Ecto.Changeset.add_error(changeset, field, @stopless_zone_message)

        true ->
          changeset
      end
    end)
  end

  # A group's key is its fare, route, origin, destination and whether it has
  # contains rows, so a key another group holds is the projected key the save
  # would merge into. The reviewed rule's own key is allowed: that is an edit in
  # place (its contains content may change freely).
  defp validate_rule_key(changeset, current_rows, reviewed, data) do
    key = rule_group_key(data)

    if key != reviewed_value(reviewed, :key) and
         MapSet.member?(MapSet.new(current_rows, &group_key/1), key) do
      Ecto.Changeset.add_error(changeset, :fare_id, @rule_key_message)
    else
      changeset
    end
  end

  defp reviewed_value(nil, _field), do: nil
  defp reviewed_value(reviewed, field), do: Map.get(reviewed, field)

  defp rule_zone_selections(data) do
    [{:origin_id, data.origin_id}, {:destination_id, data.destination_id}] ++
      Enum.map(contains_list(data.contains), &{:contains, &1})
  end

  # The zones the reviewed rule already referenced: a save may keep them even
  # when they have no boardable stops, so an imported rule stays editable.
  defp reviewed_zone_ids(nil), do: MapSet.new()

  defp reviewed_zone_ids(reviewed) do
    [
      Map.get(reviewed, :origin_id),
      Map.get(reviewed, :destination_id) | contains_list(Map.get(reviewed, :contains))
    ]
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp rule_group_data(nil) do
    %{fare_id: nil, route_id: nil, origin_id: nil, destination_id: nil, contains: []}
  end

  defp rule_group_data(reviewed) do
    %{
      fare_id: Map.get(reviewed, :fare_id),
      route_id: Map.get(reviewed, :route_id),
      origin_id: Map.get(reviewed, :origin_id),
      destination_id: Map.get(reviewed, :destination_id),
      contains: contains_list(Map.get(reviewed, :contains))
    }
  end

  # One row per contains zone, or one row without a `contains_id` when the
  # journey has no through-zone requirement. The rows carry the chosen values
  # exactly as the form sent them; nothing here trims or normalizes them.
  defp insert_saved_rule_rows(organization_id, gtfs_version_id, data) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    base = %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      fare_id: data.fare_id,
      route_id: data.route_id,
      origin_id: data.origin_id,
      destination_id: data.destination_id,
      inserted_at: now,
      updated_at: now
    }

    rows =
      Enum.map(contains_ids(data), fn contains_id ->
        Map.merge(base, %{id: Ecto.UUID.generate(), contains_id: contains_id})
      end)

    Repo.insert_all(FareRule, rows)
  end

  defp contains_ids(data) do
    case contains_list(data.contains) do
      [] -> [nil]
      contains -> contains
    end
  end

  defp rule_group_key(data) do
    {data.fare_id, data.route_id, data.origin_id, data.destination_id,
     contains_list(data.contains) != []}
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp contains_list(values) when is_list(values) do
    values |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
  end

  defp contains_list(_values), do: []

  # The projection of the rows just written must carry their key, so a missing
  # group is a defect rather than a caller error; `Map.fetch!/2` fails loudly
  # inside the transaction instead of returning a group-shaped nil.
  defp saved_rule_group(organization_id, gtfs_version_id, key) do
    organization_id
    |> list_rule_groups(gtfs_version_id)
    |> Map.new(&{&1.key, &1})
    |> Map.fetch!(key)
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

  defp project_rule_groups(rows, fares, routes) do
    rows
    |> Enum.group_by(&group_key/1)
    |> Enum.map(fn {key, rows} -> build_group(key, rows, fares, routes) end)
    |> Enum.sort_by(&sort_key/1)
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
