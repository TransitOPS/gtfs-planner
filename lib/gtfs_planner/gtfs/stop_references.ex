defmodule GtfsPlanner.Gtfs.StopReferences do
  @moduledoc """
  The version-scoped catalog of natural stop ID references.

  Call `rename!/3` and `dependents/3` inside a transaction after taking the
  version's exclusive lock. Reference writers take the version's share lock
  before resolving a natural stop ID.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.{
    AlignmentSegment,
    DeadheadTime,
    FareLegJoinRule,
    FlexService,
    Pathway,
    ReliefPoint,
    RoutePatternStop,
    Stop,
    StopArea,
    StopTime,
    Transfer,
    Translation
  }

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.WalkabilityTest

  @catalog [
    {:pathways_from, Pathway, :from_stop_id, :scalar},
    {:pathways_to, Pathway, :to_stop_id, :scalar},
    {:stop_times, StopTime, :stop_id, :scalar},
    {:transfers_from, Transfer, :from_stop_id, :scalar},
    {:transfers_to, Transfer, :to_stop_id, :scalar},
    {:stop_areas, StopArea, :stop_id, :scalar},
    {:fare_leg_join_rules_from, FareLegJoinRule, :from_stop_id, :scalar},
    {:fare_leg_join_rules_to, FareLegJoinRule, :to_stop_id, :scalar},
    {:parent_stations, Stop, :parent_station, :scalar},
    {:translations, Translation, :record_id, {:translation, "stops"}},
    {:walkability_tests, WalkabilityTest, :stop_id, :scalar},
    {:route_pattern_stops, RoutePatternStop, :stop_id, :scalar},
    {:alignment_segments_from, AlignmentSegment, :from_stop_id, :scalar},
    {:alignment_segments_to, AlignmentSegment, :to_stop_id, :scalar},
    {:relief_points, ReliefPoint, :stop_id, :scalar},
    {:deadhead_times_from, DeadheadTime, :from_ref, {:prefixed, "stop:"}},
    {:deadhead_times_to, DeadheadTime, :to_ref, {:prefixed, "stop:"}},
    {:flex_first, FlexService, :first_stop_id, :scalar},
    {:flex_last, FlexService, :last_stop_id, :scalar},
    {:flex_hubs, FlexService, :hub_stop_ids, :array}
  ]

  @doc "Returns the fixed reference inventory as `{key, schema, field, kind}` tuples."
  def catalog, do: @catalog

  @doc "Counts matching rows in one organization and version, once per catalog field."
  @spec count(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: map()
  def count(organization_id, version_id, stop_ids) do
    ids = Enum.uniq(stop_ids)

    counts =
      Map.new(@catalog, fn {key, schema, field, kind} ->
        {key, count_entry(schema, field, kind, organization_id, version_id, ids)}
      end)

    Map.put(counts, :total, Enum.sum(Map.values(counts)))
  end

  @doc """
  Renames stop IDs and every catalog reference in two phases, inside the caller's
  transaction holding the version `FOR UPDATE` lock.

  Temporary IDs let a swap pass immediate uniqueness constraints. The returned
  counts count matching rows per field, including an array row only once when
  it contains multiple renamed IDs.
  """
  @spec rename!(Ecto.UUID.t(), Ecto.UUID.t(), %{String.t() => String.t()}) :: map()
  def rename!(organization_id, version_id, mapping) do
    mapping = Map.reject(mapping, fn {old_id, new_id} -> old_id == new_id end)
    counts = count(organization_id, version_id, Map.keys(mapping))

    temporary =
      Map.new(mapping, fn {old_id, _new_id} ->
        {old_id, "__tmp_station_naming_#{Ecto.UUID.generate()}_#{Stop.slugify(old_id)}"}
      end)

    final = Map.new(temporary, fn {old_id, temp_id} -> {temp_id, Map.fetch!(mapping, old_id)} end)
    now = DateTime.utc_now()

    for phase <- [temporary, final] do
      update_entry(Stop, :stop_id, :scalar, organization_id, version_id, phase, now)

      Enum.each(@catalog, fn {_key, schema, field, kind} ->
        update_entry(schema, field, kind, organization_id, version_id, phase, now)
      end)
    end

    counts
  end

  @doc """
  Returns non-zero references that prevent stop deletion. The caller holds the
  version's exclusive lock; station-owned pathways are deleted by the caller.
  """
  @spec dependents(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: map()
  def dependents(organization_id, version_id, stop_ids) do
    organization_id
    |> count(version_id, stop_ids)
    |> Map.drop([:pathways_from, :pathways_to, :total])
    |> Map.reject(fn {_key, value} -> value == 0 end)
  end

  defp count_entry(_schema, _field, _kind, _organization_id, _version_id, []), do: 0

  defp count_entry(schema, field, kind, organization_id, version_id, ids) do
    schema
    |> scoped_query(organization_id, version_id, kind)
    |> where_match(field, kind, ids)
    |> Repo.aggregate(:count)
  end

  defp scoped_query(schema, organization_id, version_id, {:translation, table_name}) do
    from(row in schema,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id and
          row.table_name == ^table_name
    )
  end

  defp scoped_query(schema, organization_id, version_id, _kind) do
    from(row in schema,
      where: row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id
    )
  end

  defp where_match(query, field, :array, ids) do
    from(row in query,
      where: fragment("? && ?", field(row, ^field), type(^ids, {:array, :string}))
    )
  end

  defp where_match(query, field, {:prefixed, prefix}, ids) do
    encoded = Enum.map(ids, &(prefix <> &1))
    from(row in query, where: field(row, ^field) in ^encoded)
  end

  defp where_match(query, field, _kind, ids) do
    from(row in query, where: field(row, ^field) in ^ids)
  end

  defp update_entry(schema, field, kind, organization_id, version_id, mapping, now) do
    Enum.each(mapping, fn {old_id, new_id} ->
      query = scoped_query(schema, organization_id, version_id, kind)

      case kind do
        :array ->
          from(row in query,
            where: fragment("? = ANY(?)", ^old_id, row.hub_stop_ids),
            update: [
              set: [
                hub_stop_ids:
                  fragment("array_replace(?, ?, ?)", row.hub_stop_ids, ^old_id, ^new_id),
                updated_at: ^now
              ]
            ]
          )
          |> Repo.update_all([])

        {:prefixed, prefix} ->
          query
          |> where([row], field(row, ^field) == ^(prefix <> old_id))
          |> Repo.update_all(set: [{field, prefix <> new_id}, {:updated_at, now}])

        _ ->
          query
          |> where([row], field(row, ^field) == ^old_id)
          |> Repo.update_all(set: [{field, new_id}, {:updated_at, now}])
      end
    end)
  end
end
