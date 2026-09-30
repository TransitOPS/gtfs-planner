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
          via: via()
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
      via: :string
    },
    %{
      key: :route_pattern_stops,
      table: "route_pattern_stops",
      schema: RoutePatternStop,
      column: :stop_id,
      kind: :blocking,
      replace: :rewrite,
      label: "Patterns",
      via: :string
    },
    %{
      key: :relief_points,
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
      via: :array
    },
    %{
      key: :flex_first,
      table: "flex_services",
      schema: FlexService,
      column: :first_stop_id,
      kind: :blocking,
      replace: :rewrite,
      label: "Flex first stop",
      via: :string
    },
    %{
      key: :flex_last,
      table: "flex_services",
      schema: FlexService,
      column: :last_stop_id,
      kind: :blocking,
      replace: :rewrite,
      label: "Flex last stop",
      via: :string
    },
    %{
      key: :child_stops,
      table: "stops",
      schema: Stop,
      column: :parent_station,
      kind: :blocking,
      replace: :refuse,
      label: "Stops in this station",
      via: :string
    },
    %{
      key: :pathways_from,
      table: "pathways",
      schema: Pathway,
      column: :from_stop_id,
      kind: :blocking,
      replace: :refuse,
      label: "Pathways from this stop",
      via: :string
    },
    %{
      key: :pathways_to,
      table: "pathways",
      schema: Pathway,
      column: :to_stop_id,
      kind: :blocking,
      replace: :refuse,
      label: "Pathways to this stop",
      via: :string
    },
    %{
      key: :stop_levels,
      table: "stop_levels",
      schema: StopLevel,
      column: :stop_id,
      kind: :blocking,
      replace: :refuse,
      label: "Floorplans for this station",
      via: :fk_uuid
    },
    %{
      key: :journal_entries,
      table: "journal_entries",
      schema: JournalEntry,
      column: :station_id,
      kind: :blocking,
      replace: :refuse,
      label: "Journal entries for this station",
      via: :fk_uuid
    },
    %{
      key: :editing_statuses,
      table: "station_editing_statuses",
      schema: StationEditingStatus,
      column: :station_id,
      kind: :blocking,
      replace: :refuse,
      label: "Editing status for this station",
      via: :fk_uuid
    },
    %{
      key: :transfers_from,
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
      via: :string
    },
    %{
      key: :segments_from,
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

  # Which refs get labelled details rather than a bare count. Every other kind
  # reports its count, which is all the delete confirmation needs.
  @detailed ~w(route_pattern_stops transfers_from transfers_to relief_points flex_hubs flex_first flex_last deadhead_from deadhead_to child_stops stop_areas)a

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
  defp detail_query(%{key: :route_pattern_stops} = ref, stop) do
    ref
    |> scope_query(stop)
    |> join(:inner, [row], pattern in RoutePattern, on: pattern.id == row.route_pattern_id)
    |> join(:left, [row, pattern], r in Route, on: r.route_id == pattern.route_id)
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
