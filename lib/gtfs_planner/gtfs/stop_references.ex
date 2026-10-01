defmodule GtfsPlanner.Gtfs.StopReferences do
  @moduledoc """
  The one list of every table and column that can name a stop.

  Delete, replace, "where this stop is used" and the import review all read this
  list instead of naming tables themselves. A column that is missing from it is a
  column that delete or replace would leave pointing at a stop that no longer
  exists, which then reaches the exported feed as a dangling `stop_id`. The
  catalog test in `test/gtfs_planner/gtfs/stop_references_catalog_test.exs`
  reflects `information_schema` back onto this list, so adding a stop-referencing
  column without classifying it fails a test rather than shipping a dangling
  reference.

  ## Kinds

  * `:blocking` — the row changes service or a station's records. Deleting the
    stop is refused while one exists (`stop_times`, `route_pattern_stops`,
    `relief_points`, flex references, child stops, pathways, and the rows that
    cascade from `stops.id`).
  * `:descriptive` — the row describes the stop's surroundings. Deleting the stop
    removes these rows with it (transfers, fare leg join rules, translations,
    walkability tests, stop areas, deadhead times, map-line sections).

  ## Replace rules

  * `:rewrite` — point the column at the replacement.
  * `:rewrite_dedupe_array` — replace the element in a stop-ID array and drop
    duplicates.
  * `:rewrite_keep_existing` — rewrite, but where the rewritten row would
    collide with a row that already names the replacement, keep the
    replacement's row and delete the old one.
  * `:drop` — the row cannot be rewritten, so it goes (translations, which are
    the deleted stop's own text).
  * `:rekey_segments` — re-point a shared map-line pair, dropping a row that
    collides or becomes `(new, new)`.
  * `:refuse` — replace is refused while any row of this kind exists.

  ## Matching

  `via: :fk_uuid` entries match the stop's `stops.id` UUID. `via: :string`
  entries match `stops.stop_id`. `via: :array` is `flex_services.hub_stop_ids`,
  where the stop appears anywhere in a stop-ID array.
  """

  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.FareLegJoinRule
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StationEditingStatus
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.WalkabilityTest

  import Ecto.Query

  @type kind :: :blocking | :descriptive

  @type replace_rule ::
          :rewrite
          | :rewrite_dedupe_array
          | :rewrite_keep_existing
          | :drop
          | :rekey_segments
          | :refuse

  @type via :: :string | :array | :fk_uuid

  @type ref :: %{
          key: atom(),
          table: String.t(),
          schema: module(),
          column: atom(),
          kind: kind(),
          replace: replace_rule(),
          label: String.t(),
          via: via(),
          collision_key: [atom()] | nil
        }

  @ref_keys ~w(
          stop_times route_pattern_stops relief_points flex_hubs flex_first flex_last
          child_stops pathways_from pathways_to levels stop_levels journal_entries
          editing_statuses transfers_from transfers_to fare_leg_join_from
          fare_leg_join_to stop_areas walkability_tests deadhead_from deadhead_to
          translations segments_from segments_to
        )a

  @kinds [:blocking, :descriptive]

  @replace_rules [
    :rewrite,
    :rewrite_dedupe_array,
    :rewrite_keep_existing,
    :drop,
    :rekey_segments,
    :refuse
  ]

  @vias [:string, :array, :fk_uuid]

  # Order follows the reference table in the spec's Architecture 4.3: service and
  # station rows first, then the descriptive rows, then history.
  @all [
    %{
      key: :stop_times,
      table: "stop_times",
      schema: StopTime,
      column: :stop_id,
      kind: :blocking,
      replace: :rewrite,
      label: "Stop times",
      via: :string,
      collision_key: nil
    },
    %{
      key: :route_pattern_stops,
      table: "route_pattern_stops",
      schema: RoutePatternStop,
      column: :stop_id,
      kind: :blocking,
      replace: :rewrite,
      label: "Patterns",
      via: :string,
      collision_key: nil
    },
    %{
      key: :relief_points,
      collision_key: [:stop_id],
      table: "relief_points",
      schema: ReliefPoint,
      column: :stop_id,
      kind: :blocking,
      replace: :rewrite_keep_existing,
      label: "Relief points",
      via: :string
    },
    %{
      key: :flex_hubs,
      table: "flex_services",
      schema: FlexService,
      column: :hub_stop_ids,
      kind: :blocking,
      replace: :rewrite_dedupe_array,
      label: "Flex hubs",
      via: :array,
      collision_key: nil
    },
    %{
      key: :flex_first,
      table: "flex_services",
      schema: FlexService,
      column: :first_stop_id,
      kind: :blocking,
      replace: :rewrite,
      label: "Flex first stop",
      via: :string,
      collision_key: nil
    },
    %{
      key: :flex_last,
      table: "flex_services",
      schema: FlexService,
      column: :last_stop_id,
      kind: :blocking,
      replace: :rewrite,
      label: "Flex last stop",
      via: :string,
      collision_key: nil
    },
    %{
      key: :child_stops,
      table: "stops",
      schema: Stop,
      column: :parent_station,
      kind: :blocking,
      replace: :refuse,
      label: "Stops in this station",
      via: :string,
      collision_key: nil
    },
    %{
      key: :pathways_from,
      table: "pathways",
      schema: Pathway,
      column: :from_stop_id,
      kind: :blocking,
      replace: :refuse,
      label: "Pathways from this stop",
      via: :string,
      collision_key: nil
    },
    %{
      key: :pathways_to,
      table: "pathways",
      schema: Pathway,
      column: :to_stop_id,
      kind: :blocking,
      replace: :refuse,
      label: "Pathways to this stop",
      via: :string,
      collision_key: nil
    },
    %{
      key: :stop_levels,
      table: "stop_levels",
      schema: StopLevel,
      column: :stop_id,
      kind: :blocking,
      replace: :refuse,
      label: "Floorplans for this station",
      via: :fk_uuid,
      collision_key: nil
    },
    %{
      key: :journal_entries,
      table: "journal_entries",
      schema: JournalEntry,
      column: :station_id,
      kind: :blocking,
      replace: :refuse,
      label: "Journal entries for this station",
      via: :fk_uuid,
      collision_key: nil
    },
    %{
      key: :editing_statuses,
      table: "station_editing_statuses",
      schema: StationEditingStatus,
      column: :station_id,
      kind: :blocking,
      replace: :refuse,
      label: "Editing status for this station",
      via: :fk_uuid,
      collision_key: nil
    },
    %{
      key: :transfers_from,
      collision_key: [
        :from_stop_id,
        :to_stop_id,
        :from_route_id,
        :to_route_id,
        :from_trip_id,
        :to_trip_id
      ],
      table: "transfers",
      schema: Transfer,
      column: :from_stop_id,
      kind: :descriptive,
      replace: :rewrite_keep_existing,
      label: "Transfers from",
      via: :string
    },
    %{
      key: :transfers_to,
      collision_key: [
        :from_stop_id,
        :to_stop_id,
        :from_route_id,
        :to_route_id,
        :from_trip_id,
        :to_trip_id
      ],
      table: "transfers",
      schema: Transfer,
      column: :to_stop_id,
      kind: :descriptive,
      replace: :rewrite_keep_existing,
      label: "Transfers to",
      via: :string
    },
    %{
      key: :fare_leg_join_from,
      collision_key: [:from_network_id, :to_network_id, :from_stop_id, :to_stop_id],
      table: "fare_leg_join_rules",
      schema: FareLegJoinRule,
      column: :from_stop_id,
      kind: :descriptive,
      replace: :rewrite_keep_existing,
      label: "Fare leg joins from",
      via: :string
    },
    %{
      key: :fare_leg_join_to,
      collision_key: [:from_network_id, :to_network_id, :from_stop_id, :to_stop_id],
      table: "fare_leg_join_rules",
      schema: FareLegJoinRule,
      column: :to_stop_id,
      kind: :descriptive,
      replace: :rewrite_keep_existing,
      label: "Fare leg joins to",
      via: :string
    },
    %{
      key: :stop_areas,
      collision_key: [:area_id, :stop_id],
      table: "stop_areas",
      schema: StopArea,
      column: :stop_id,
      kind: :descriptive,
      replace: :rewrite_keep_existing,
      label: "Stop areas",
      via: :string
    },
    %{
      key: :walkability_tests,
      collision_key: [:stop_id, :address],
      table: "walkability_tests",
      schema: WalkabilityTest,
      column: :stop_id,
      kind: :descriptive,
      replace: :rewrite_keep_existing,
      label: "Walkability tests",
      via: :string
    },
    %{
      key: :deadhead_from,
      collision_key: [:from_ref, :to_ref],
      table: "deadhead_times",
      schema: DeadheadTime,
      column: :from_ref,
      kind: :descriptive,
      replace: :rewrite_keep_existing,
      label: "Deadhead times from",
      via: :string
    },
    %{
      key: :deadhead_to,
      collision_key: [:from_ref, :to_ref],
      table: "deadhead_times",
      schema: DeadheadTime,
      column: :to_ref,
      kind: :descriptive,
      replace: :rewrite_keep_existing,
      label: "Deadhead times to",
      via: :string
    },
    %{
      key: :translations,
      table: "translations",
      schema: Translation,
      column: :record_id,
      kind: :descriptive,
      replace: :drop,
      label: "Translations",
      via: :string,
      collision_key: nil
    },
    %{
      key: :segments_from,
      collision_key: [:from_stop_id, :to_stop_id],
      table: "alignment_segments",
      schema: AlignmentSegment,
      column: :from_stop_id,
      kind: :descriptive,
      replace: :rekey_segments,
      label: "Map line sections from",
      via: :string
    },
    %{
      key: :segments_to,
      collision_key: [:from_stop_id, :to_stop_id],
      table: "alignment_segments",
      schema: AlignmentSegment,
      column: :to_stop_id,
      kind: :descriptive,
      replace: :rekey_segments,
      label: "Map line sections to",
      via: :string
    }
  ]

  # GTFS lets a station name a parent level through `levels.parent_station_id`,
  # and a delete must be refused while such a row exists. This schema has no such
  # column: `levels` is scoped by organization and version and reaches a station
  # through `stop_levels`, which `all/0` already blocks on. The entry therefore
  # cannot live in `all/0`, whose queries must name real columns, so it is
  # declared here and the catalog test fails if the column ever appears without
  # somebody moving the entry into `all/0`.
  @dormant_levels_ref %{
    key: :levels,
    table: "levels",
    schema: Level,
    column: :parent_station_id,
    kind: :blocking,
    replace: :refuse,
    label: "Levels in this station",
    via: :fk_uuid
  }

  @doc """
  Every table and column that can name a stop, with its kind and replace rule.

  A row's `key` is how the rest of the code names it (the import review's noun,
  a usage item, a replace count), and is unique across the list even when two
  entries share a table — `flex_first` and `flex_last` are both
  `flex_services`.

  `collision_key` is the set of columns a row of that table must be unique on,
  **beyond** the `organization_id` and `gtfs_version_id` every query in this
  module already scopes by. It is the key `replace_review/3` and
  `replace_stop/4` test a rewritten row against, so a rewrite that would land on
  an existing row is reported as a collision instead of raising a unique
  violation halfway through a replace. It is `nil` where a rewrite cannot
  collide — a table whose only unique index is the row's own id, or one where
  the rewritten column is not part of any index.

  The list lives here rather than in the replace command so CR-1 holds: the
  commands read it off the entry and never name a table. The catalog test
  proves each list is a real unique index on that table, so the two cannot
  drift.
  """
  @spec all() :: [ref()]
  def all, do: @all

  @doc """
  Catalog columns the name rules match that are not stop references, each with a
  reason.

  Keeping them here rather than silently dropping them means the catalog test can
  tell "deliberately not a reference" apart from "nobody looked".
  """
  @spec excluded() :: [{String.t(), String.t(), String.t()}]
  def excluded do
    [
      {"stops", "stop_id",
       "The stop's own GTFS ID, not a reference to another row. It never changes after creation."},
      {"change_logs", "station_stop_id",
       "History keeps the station ID that was written when the entry was made. Rewriting it would rewrite the past."},
      {"change_logs", "entity_external_id",
       "History keeps the external ID the entry was written with, for the same reason as station_stop_id."},
      {"timed_pattern_stops", "route_pattern_stop_id",
       "Matches the name rule only as a substring. It references a route_pattern_stops row, which in turn references a stop."}
    ]
  end

  @doc """
  The one reference this schema cannot query yet: a level naming its parent
  station.

  `all/0` stays honest by excluding it, because every entry there must name a
  real column. When `levels.parent_station_id` is added, move this entry into
  `all/0` and the catalog test will hold it there.
  """
  @spec dormant_refs() :: [ref()]
  def dormant_refs, do: [@dormant_levels_ref]

  @doc "The ref with the given key, or nil."
  @spec fetch(atom()) :: ref() | nil
  def fetch(key), do: Enum.find(@all, &(&1.key == key))

  @doc """
  Builds the query that finds one ref's rows for one stop.

  `via: :fk_uuid` matches the stop's `stops.id`; `via: :string` matches its
  `stops.stop_id`; `via: :array` matches the stop's ID anywhere in a stop-ID
  array. Every query is scoped to the stop's organization and version, so a row
  in another version never counts. The translations entry also carries its
  `table_name` discriminator, so it counts only the rows that translate a stop.

  The column is a runtime value, so the comparison is built with
  `Ecto.Query.field/2`'s pinned form. Every entry names a real column of its
  schema and the catalog test proves that, so an unknown field raises when the
  query is built rather than silently matching nothing.
  """
  @spec scope_query(ref(), Stop.t()) :: Ecto.Query.t()
  def scope_query(%{via: :fk_uuid} = ref, stop) do
    where(ref.schema, [row], field(row, ^ref.column) == ^stop.id)
    |> scope_to_version(stop)
  end

  def scope_query(%{via: :array} = ref, stop) do
    where(ref.schema, [row], ^stop.stop_id in field(row, ^ref.column))
    |> scope_to_version(stop)
  end

  def scope_query(%{key: :translations} = ref, stop) do
    ref.schema
    |> where([row], row.table_name == "stops")
    |> where([row], row.record_id == ^stop.stop_id)
    |> scope_to_version(stop)
  end

  # A deadhead reference stores `stop:<stop_id>` or `garage:<uuid>`, not the bare
  # ID, so the encoded form is matched too. A row written before the encoding
  # existed holds the bare ID, and both forms belong to this stop.
  def scope_query(%{key: key} = ref, stop) when key in [:deadhead_from, :deadhead_to] do
    where(ref.schema, [row], field(row, ^ref.column) in ^deadhead_refs(stop))
    |> scope_to_version(stop)
  end

  def scope_query(%{column: column} = ref, stop) do
    where(ref.schema, [row], field(row, ^column) == ^stop.stop_id)
    |> scope_to_version(stop)
  end

  defp scope_to_version(query, stop) do
    where(query, [row], field(row, :organization_id) == ^stop.organization_id)
    |> where([row], field(row, :gtfs_version_id) == ^stop.gtfs_version_id)
  end

  defp deadhead_refs(%Stop{stop_id: stop_id}), do: [stop_id, "stop:#{stop_id}"]

  @type counts :: %{String.t() => %{atom() => pos_integer()}}

  @doc """
  How many rows of each kind still name each of the given stop IDs.

  The import review holds natural keys before any row exists, so this takes stop
  IDs rather than a `Stop` struct and cannot match the `via: :fk_uuid` entries —
  those need a `stops.id` UUID that an unimported stop does not have yet. They
  are absent from the result rather than reported as zero, because nothing is
  counted for them rather than "nothing was found".

  A stop ID nothing uses is absent from the map, matching
  `Gtfs.import_dependent_counts/4`. Kinds are reported under the names the
  import review already renders, so `transfers_from` and `transfers_to` both
  report as `:transfers` and a row naming one stop in both columns counts once.
  """
  @spec counts(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: counts()
  def counts(_organization_id, _gtfs_version_id, []), do: %{}

  def counts(organization_id, gtfs_version_id, stop_ids) do
    @all
    |> Enum.filter(&(&1.via != :fk_uuid))
    |> Enum.reduce(%{}, fn ref, counts ->
      counted_rows(ref, organization_id, gtfs_version_id, stop_ids)
      |> Enum.reduce(counts, &add_count(&2, ref, &1))
    end)
  end

  # `[stop_id, count]` pairs, one per row that names one of the given stops.
  defp counted_rows(%{via: :array} = ref, organization_id, gtfs_version_id, stop_ids) do
    ref.schema
    |> scope_to_ids(ref, organization_id, gtfs_version_id)
    # `array <@ column`: does this array hold any of the given IDs? Ecto's `in`
    # would need a compile-time list on the left of an array column.
    |> where(
      [row],
      fragment("? <@ ?", type(^stop_ids, {:array, :string}), field(row, ^ref.column))
    )
    |> select([row], field(row, ^ref.column))
    |> Repo.all()
    # One flex service naming the stop twice in its hub array is still one row.
    |> Enum.flat_map(fn ids ->
      ids |> Enum.filter(&(&1 in stop_ids)) |> Enum.uniq() |> Enum.map(&{&1, 1})
    end)
    |> merge_pairs()
  end

  defp counted_rows(%{via: :string} = ref, organization_id, gtfs_version_id, stop_ids) do
    ref.schema
    |> scope_to_ids(ref, organization_id, gtfs_version_id)
    |> where([row], field(row, ^ref.column) in ^match_values(ref, stop_ids))
    |> select([row], field(row, ^ref.column))
    |> Repo.all()
    |> Enum.map(&{natural_key(ref, &1), 1})
    |> merge_pairs()
  end

  defp scope_to_ids(query, ref, organization_id, gtfs_version_id) do
    query
    |> maybe_stop_table(ref)
    |> where([row], field(row, :organization_id) == ^organization_id)
    |> where([row], field(row, :gtfs_version_id) == ^gtfs_version_id)
    |> skip_counted_column(ref)
  end

  # A translation naming the same GTFS ID on a route is a different row; only the
  # `stops` table's translations refer to this stop.
  defp maybe_stop_table(query, %{key: :translations}),
    do: where(query, [row], row.table_name == "stops")

  defp maybe_stop_table(query, _ref), do: query

  # A row naming one stop as both its from and its to stop is one dependency, so
  # the second column skips exactly the rows whose two columns are equal.
  defp skip_counted_column(query, %{key: key})
       when key in [:transfers_to, :pathways_to, :fare_leg_join_to],
       do: where(query, [row], field(row, ^counted_in(key)) != field(row, ^ref_column(key)))

  defp skip_counted_column(query, _ref), do: query

  defp merge_pairs(pairs) do
    pairs
    |> Enum.reduce(%{}, fn {stop_id, count}, acc ->
      Map.update(acc, stop_id, count, &(&1 + count))
    end)
    |> Enum.map(fn {stop_id, count} -> {stop_id, count} end)
  end

  # A deadhead row stores `stop:<id>` or a bare `<id>`; both name the same stop, so
  # the stored value is mapped back to the GTFS ID before it becomes a map key.
  defp natural_key(%{key: key}, "stop:" <> stop_id) when key in [:deadhead_from, :deadhead_to],
    do: stop_id

  defp natural_key(_ref, stop_id), do: stop_id

  defp add_count(counts, _ref, {stop_id, _count}) when stop_id in [nil, ""], do: counts

  defp add_count(counts, ref, {stop_id, count}) do
    key = report_key(ref)

    Map.update(counts, stop_id, %{key => count}, fn kinds ->
      Map.update(kinds, key, count, &(&1 + count))
    end)
  end

  @doc """
  The name a review or a delete result reports this ref under.

  The shared list splits a two-column table into a from and a to entry; a
  delete says "2 transfers removed", not "1 from, 1 to". Public so
  `StopEditing.delete_stop/3` names its removed counts the same way the review
  that listed them did — two spellings of one count would be worse than one.
  """
  @spec report_key(ref()) :: atom()
  def report_key(%{key: key}) when key in [:transfers_from, :transfers_to], do: :transfers
  def report_key(%{key: key}) when key in [:pathways_from, :pathways_to], do: :pathways

  def report_key(%{key: key}) when key in [:fare_leg_join_from, :fare_leg_join_to],
    do: :fare_leg_join_rules

  def report_key(ref), do: ref.key

  # The column a "to" entry's paired "from" entry already counted.
  defp counted_in(:transfers_to), do: :from_stop_id
  defp counted_in(:pathways_to), do: :from_stop_id
  defp counted_in(:fare_leg_join_to), do: :from_stop_id

  defp ref_column(:transfers_to), do: :to_stop_id
  defp ref_column(:pathways_to), do: :to_stop_id
  defp ref_column(:fare_leg_join_to), do: :to_stop_id

  # A deadhead row's stored value is `stop:<id>` or a bare `<id>`; both name the
  # same stop, so the comparison matches either.
  defp match_values(ref, stop_ids), do: deadhead_refs(ref, stop_ids) ++ stop_ids

  defp deadhead_refs(%{key: key}, stop_ids) when key in [:deadhead_from, :deadhead_to],
    do: Enum.map(stop_ids, &"stop:#{&1}")

  defp deadhead_refs(_ref, _stop_ids), do: []

  # Which refs get labelled details rather than a bare count. Every other kind
  # reports its count, which is all the delete confirmation needs.
  @detailed ~w(route_pattern_stops transfers_from transfers_to relief_points flex_hubs flex_first flex_last deadhead_from deadhead_to child_stops stop_areas translations)a

  @type item :: %{
          key: atom(),
          label: String.t(),
          count: pos_integer(),
          details: [map()]
        }

  @doc """
  Where one stop is used, split into the rows that block a delete and the
  descriptive rows a delete removes.

  Every kind in `all/0` with at least one row appears once, with its count and
  labelled details; a kind nothing uses is absent, so an unused stop returns
  `%{blocking: [], descriptive: []}`. Every query is scoped to the stop's own
  organization and version, so a row in another version never counts even when it
  names the same `stop_id`.

  Details carry what a person needs to act on the row: a pattern shows its
  route's short name and colour, its headsign and how many weekday trips run it;
  a transfer and a deadhead time show the other end and the minutes; a relief
  point, a flex service and a child stop show their name.
  """
  @spec usage(Ecto.UUID.t(), Ecto.UUID.t(), Stop.t()) :: %{
          blocking: [item()],
          descriptive: [item()]
        }
  def usage(_organization_id, _gtfs_version_id, %Stop{} = stop) do
    blocking = @all |> Enum.filter(&(&1.kind == :blocking)) |> collect(stop)
    descriptive = @all |> Enum.filter(&(&1.kind == :descriptive)) |> collect(stop)

    %{blocking: blocking, descriptive: descriptive}
  end

  @doc """
  Whether any row of the given kind references this stop, in its own scope.

  `usage/3` answers "what would a delete remove", which deliberately means
  rows this organization's own import created. A move review is a different
  question — "is anything drawing riders to this stop" — and routing
  materialization is something an operator may have produced outside that
  boundary, so a stop in a delivered feed must not read as unserved just
  because no import of this app wrote the pattern row.

  Every `via` shape is handled by `scope_query/2` itself, so the flex array
  columns and the encoded deadhead references are answered as carefully as the
  plain ones. A key that is not in the list is `false` rather than an error, so
  a caller that misspells one gets a visible wrong answer instead of a raise
  in the middle of a review.
  """
  @spec serving?(atom(), Stop.t()) :: boolean()
  def serving?(key, %Stop{} = stop) when is_atom(key) do
    case Enum.find(@all, &(&1.key == key)) do
      nil -> false
      ref -> Repo.exists?(scope_query(ref, stop))
    end
  end

  defp collect(refs, stop) do
    refs
    |> Enum.map(fn ref -> item(ref, stop) end)
    |> Enum.reject(&is_nil/1)
  end

  defp item(ref, stop) do
    count = count_rows(ref, stop)

    if count == 0 do
      nil
    else
      %{
        key: ref.key,
        label: ref.label,
        count: count,
        details: details_for(ref, stop)
      }
    end
  end

  defp count_rows(ref, stop) do
    ref
    |> scope_query(stop)
    |> select([row], count(row.id))
    |> Repo.one()
  end

  defp details_for(ref, stop) do
    if ref.key in @detailed do
      detail_query(ref, stop)
    else
      []
    end
  end

  # Pattern rows are what an editor needs most: which route serves this stop, in
  # which direction, and how much service that is. Weekday trips are counted from
  # the patterns' linked trips whose service runs Monday through Friday, so the
  # number reflects regular service rather than a one-off Saturday-only trip. One
  # grouped query counts them for every pattern at once, so a stop on ten patterns
  # still costs two queries here, not ten.
  # The route join is scoped to the pattern's own organization and version.
  # Joining on `route_id` alone looks right — route IDs are unique inside a
  # feed, not inside a database — and in a single-organization database it is.
  # In any real deployment every organization has a route "1", so the join
  # fanned out once per matching row in the whole table: `usage/3` reported a
  # count of 4 beside a list of a hundred duplicates, and anything that summed
  # the details — the step 14 move review's weekday figure — was off by the
  # size of the database. Found by the review, not by a test of this module.
  defp detail_query(%{key: :route_pattern_stops} = ref, stop) do
    ref
    |> scope_query(stop)
    |> join(:inner, [row], pattern in RoutePattern, on: pattern.id == row.route_pattern_id)
    |> join(
      :left,
      [row, pattern],
      r in Route,
      on:
        r.route_id == pattern.route_id and
          r.organization_id == pattern.organization_id and
          r.gtfs_version_id == pattern.gtfs_version_id
    )
    |> select([_row, pattern, r], %{
      route_short_name: r.route_short_name,
      route_long_name: r.route_long_name,
      route_id: pattern.route_id,
      headsign: pattern.headsign,
      route_pattern_id: pattern.route_pattern_id,
      detail: %{
        route_pattern_id: pattern.route_pattern_id,
        route_id: pattern.route_id,
        headsign: pattern.headsign,
        route_short_name: r.route_short_name,
        route_color: r.route_color
      }
    })
    |> Repo.all()
    |> Enum.map(&pattern_detail(&1, stop))
  end

  defp detail_query(%{key: :transfers_from} = ref, stop) do
    ref
    |> scope_query(stop)
    |> join(
      :left,
      [row],
      other in Stop,
      on:
        other.stop_id == row.to_stop_id and other.organization_id == row.organization_id and
          other.gtfs_version_id == row.gtfs_version_id
    )
    |> select([row, other], %{
      other_stop_name: other.stop_name,
      other_stop_id: row.to_stop_id,
      detail: %{to_stop_id: row.to_stop_id, min_transfer_time: row.min_transfer_time}
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      %{label: other_stop_label(row.other_stop_id, row.other_stop_name), detail: row.detail}
    end)
  end

  defp detail_query(%{key: :transfers_to} = ref, stop) do
    ref
    |> scope_query(stop)
    |> join(
      :left,
      [row],
      other in Stop,
      on:
        other.stop_id == row.from_stop_id and other.organization_id == row.organization_id and
          other.gtfs_version_id == row.gtfs_version_id
    )
    |> select([row, other], %{
      other_stop_name: other.stop_name,
      other_stop_id: row.from_stop_id,
      detail: %{from_stop_id: row.from_stop_id, min_transfer_time: row.min_transfer_time}
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      %{label: other_stop_label(row.other_stop_id, row.other_stop_name), detail: row.detail}
    end)
  end

  defp detail_query(%{key: :deadhead_from} = ref, stop) do
    ref
    |> scope_query(stop)
    |> select([row], %{from_ref: row.from_ref, to_ref: row.to_ref, minutes: row.minutes})
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        label: deadhead_label(row.from_ref, row.to_ref, row.minutes),
        detail: %{from_ref: row.from_ref, to_ref: row.to_ref, minutes: row.minutes}
      }
    end)
  end

  defp detail_query(%{key: :deadhead_to} = ref, stop) do
    ref
    |> scope_query(stop)
    |> select([row], %{from_ref: row.from_ref, to_ref: row.to_ref, minutes: row.minutes})
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        label: deadhead_label(row.from_ref, row.to_ref, row.minutes),
        detail: %{from_ref: row.from_ref, to_ref: row.to_ref, minutes: row.minutes}
      }
    end)
  end

  defp detail_query(%{key: :relief_points} = ref, stop) do
    ref
    |> scope_query(stop)
    |> select([row], row.stop_id)
    |> Repo.all()
    |> Enum.map(fn stop_id ->
      %{label: "Relief at #{stop_id}", detail: %{stop_id: stop_id}}
    end)
  end

  # A translation is listed by what it says, not by how many rows there are: a
  # delete confirmation has to name the Spanish name it is about to remove, and
  # a bare count of "1 translation" cannot.
  defp detail_query(%{key: :translations} = ref, stop) do
    ref
    |> scope_query(stop)
    |> select([row], %{language: row.language, translation: row.translation})
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        label: "#{language_name(row.language)} name: “#{row.translation}”",
        detail: %{language: row.language, translation: row.translation}
      }
    end)
  end

  defp detail_query(%{key: :child_stops} = ref, stop) do
    ref
    |> scope_query(stop)
    |> select([row], %{
      stop_name: row.stop_name,
      stop_id: row.stop_id,
      location_type: row.location_type
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        label: row.stop_name || row.stop_id,
        detail: %{stop_id: row.stop_id, location_type: row.location_type}
      }
    end)
  end

  defp detail_query(%{key: key} = ref, stop) when key in [:flex_hubs, :flex_first, :flex_last] do
    ref
    |> scope_query(stop)
    |> Repo.all()
    |> Enum.map(fn row ->
      %{label: row.name || row.key, detail: %{key: row.key, kind: row.kind}}
    end)
  end

  defp detail_query(%{key: :stop_areas} = ref, stop) do
    ref
    |> scope_query(stop)
    |> Repo.all()
    |> Enum.map(fn area_id -> %{label: area_id, detail: %{area_id: area_id}} end)
  end

  # GTFS language codes are a fixed list in practice and unbounded on paper, so
  # the codes riders actually see are named and anything else is reported as the
  # code itself rather than guessed at.
  defp language_name(language) do
    Map.get(
      %{
        "en" => "English",
        "es" => "Spanish",
        "fr" => "French",
        "de" => "German",
        "it" => "Italian",
        "pt" => "Portuguese",
        "zh" => "Chinese",
        "ja" => "Japanese",
        "ko" => "Korean",
        "ar" => "Arabic",
        "ru" => "Russian"
      },
      language,
      language
    )
  end

  # Detail helpers. Kept together after the `detail_query/2` clauses so the
  # clauses of one function stay grouped.
  defp pattern_detail(row, stop) do
    %{
      label: route_label(row.route_short_name, row.route_long_name, row.route_id, row.headsign),
      detail: row.detail,
      weekday_trips: Map.get(weekday_trip_counts(stop), row.route_pattern_id, 0)
    }
  end

  defp weekday_trip_counts(stop) do
    {:ok, %{rows: rows}} =
      Repo.query(
        "select t.route_pattern_id, count(*) from trips t " <>
          "join calendars c on c.service_id = t.service_id " <>
          "and c.organization_id = t.organization_id and c.gtfs_version_id = t.gtfs_version_id " <>
          "where t.organization_id = $1 and t.gtfs_version_id = $2 and " <>
          "(c.monday = 1 or c.tuesday = 1 or c.wednesday = 1 or c.thursday = 1 or c.friday = 1) " <>
          "group by t.route_pattern_id",
        [Ecto.UUID.dump!(stop.organization_id), Ecto.UUID.dump!(stop.gtfs_version_id)]
      )

    Map.new(rows, fn [route_pattern_id, count] -> {route_pattern_id, count} end)
  end

  defp route_label(short_name, long_name, route_id, headsign) do
    route = short_name || long_name || route_id

    "#{route} · #{headsign || "all stops"}"
  end

  # A deadhead row stores `stop:<id>` or `garage:<uuid>`; the label drops the
  # prefix so an editor reads "Depot → 1434", not the encoded form.
  defp deadhead_label(from_ref, to_ref, minutes) do
    "#{pretty_ref(from_ref)} → #{pretty_ref(to_ref)} · #{minutes} min"
  end

  defp pretty_ref("stop:" <> stop_id), do: stop_id
  defp pretty_ref("garage:" <> garage_id), do: garage_id
  defp pretty_ref(ref), do: ref

  defp other_stop_label(_stop_id, name) when is_binary(name) and name != "", do: name
  defp other_stop_label(stop_id, _name), do: stop_id

  @doc false
  def valid_keys, do: @ref_keys
  @doc false
  def valid_kinds, do: @kinds
  @doc false
  def valid_replace_rules, do: @replace_rules
  @doc false
  def valid_vias, do: @vias
end
