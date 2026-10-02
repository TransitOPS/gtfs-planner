defmodule GtfsPlanner.Gtfs.RecentChanges do
  @moduledoc """
  Collapses a GTFS version's change logs into recent destination groups.

  One edit command can write many change-log rows under a shared
  `changed_fields["operation_id"]`; this module folds those rows back into one
  operation and then groups operations by the destination they touched, newest
  first. An operation's destination is its highest-precedence row: calendar,
  route-pattern build, route pattern, pattern shape, timed pattern, trip, level,
  stop, pathway, alignment segment, transfer, fare version. A trip row carrying a
  calendar combination's envelope ranks as the destination calendar, because a
  combination that leaves the destination's dates unchanged writes no calendar
  row.

  The scan is bounded: it reads 200-row keyset pages newest first, up to 2,000
  rows, and stops early once five destinations are known and it has passed the
  featured group's local day. Exact "changes that day" counts beyond that window
  are given up by design. Every read is scoped by organization and version, and
  the audience narrows them to one actor for the "your changes" resume view.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Repo

  @page_size 200
  @max_rows 2_000
  @max_groups 5
  @unknown_rank 99

  @destination_precedence %{
    "calendar" => 1,
    "route_pattern_build" => 2,
    "route_pattern" => 3,
    "pattern_shape" => 4,
    "timed_pattern" => 5,
    "trip" => 6,
    "level" => 7,
    "stop" => 8,
    "pathway" => 9,
    "alignment_segment" => 10,
    "transfer" => 11,
    "fare_version" => 12
  }

  @type destination ::
          {:calendar, service_id :: String.t()}
          | {:route_patterns, route_id :: String.t()}
          | {:route_pattern, route_id :: String.t() | nil, route_pattern_id :: String.t()}
          | {:timed_pattern, route_pattern_uuid :: Ecto.UUID.t()}
          | {:schedules, route_id :: String.t(), service_id :: String.t()}
          | {:station, station_stop_id :: String.t(), level_id :: String.t() | nil}
          | {:stop, stop_id :: String.t()}
          | :alignment
          | :fares
          | :transfers

  @type group :: %{
          destination: destination(),
          operations: [[ChangeLog.t()]],
          newest_at: DateTime.t(),
          actor_email: String.t(),
          same_day_count: pos_integer()
        }

  @doc """
  Returns up to five recent destination groups for one audience, newest first.

  `audience` is `:everyone` or `{:actor, actor_id}`.
  """
  @spec recent(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          :everyone | {:actor, Ecto.UUID.t()},
          DisplayClock.zone_resolution()
        ) :: [group()]
  def recent(organization_id, gtfs_version_id, audience, zone_resolution) do
    organization_id
    |> scan(gtfs_version_id, audience, zone_resolution)
    |> build_groups()
  end

  @doc """
  Returns the actor's own recent groups, or the whole team's when the actor has
  no rows in the version.
  """
  @spec recent_for_user(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          DisplayClock.zone_resolution()
        ) :: %{scope: :own | :team, groups: [group()]}
  def recent_for_user(organization_id, gtfs_version_id, actor_id, zone_resolution) do
    if actor_has_rows?(organization_id, gtfs_version_id, actor_id) do
      %{
        scope: :own,
        groups: recent(organization_id, gtfs_version_id, {:actor, actor_id}, zone_resolution)
      }
    else
      %{
        scope: :team,
        groups: recent(organization_id, gtfs_version_id, :everyone, zone_resolution)
      }
    end
  end

  @doc """
  Counts distinct operations and distinct non-null stations changed after `since`.
  """
  @spec count_since(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: %{
          changes: non_neg_integer(),
          stations: non_neg_integer()
        }
  def count_since(organization_id, gtfs_version_id, since) do
    from(c in ChangeLog,
      where:
        c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id and
          c.inserted_at > ^since,
      select: %{
        changes:
          count(
            fragment("DISTINCT coalesce(?->>'operation_id', ?::text)", c.changed_fields, c.id)
          ),
        stations: count(fragment("DISTINCT ?", c.station_stop_id))
      }
    )
    |> Repo.one()
  end

  defp actor_has_rows?(organization_id, gtfs_version_id, actor_id) do
    Repo.exists?(
      from(c in ChangeLog,
        where:
          c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id and
            c.actor_id == ^actor_id
      )
    )
  end

  # -- Bounded keyset scan --

  defp scan(organization_id, gtfs_version_id, audience, zone_resolution) do
    initial = %{
      operations: %{},
      destination_counts: %{},
      featured_date: nil,
      count: 0
    }

    organization_id
    |> scan_pages(gtfs_version_id, audience, zone_resolution, nil, initial)
    |> Map.fetch!(:operations)
  end

  defp scan_pages(_organization_id, _gtfs_version_id, _audience, _zone, _cursor, state)
       when state.count >= @max_rows,
       do: state

  defp scan_pages(organization_id, gtfs_version_id, audience, zone_resolution, cursor, state) do
    limit = min(@page_size, @max_rows - state.count)

    case fetch_page(organization_id, gtfs_version_id, audience, cursor, limit) do
      [] ->
        state

      page ->
        page = localize_page(page, zone_resolution)
        {state, halted?} = scan_page(page, state)

        if halted? do
          state
        else
          scan_pages(
            organization_id,
            gtfs_version_id,
            audience,
            zone_resolution,
            cursor_for(page),
            state
          )
        end
    end
  end

  defp scan_page(page, state) do
    Enum.reduce_while(page, {state, false}, fn {log, local_at}, {state, _halted?} ->
      state = add_row(state, log, local_at)

      if halt?(state, local_at) do
        {:halt, {state, true}}
      else
        {:cont, {state, false}}
      end
    end)
  end

  defp fetch_page(organization_id, gtfs_version_id, audience, cursor, limit) do
    ChangeLog
    |> where(
      [c],
      c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id
    )
    |> filter_audience(audience)
    |> filter_cursor(cursor)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_audience(query, :everyone), do: query
  defp filter_audience(query, {:actor, actor_id}), do: where(query, [c], c.actor_id == ^actor_id)

  defp filter_cursor(query, nil), do: query

  defp filter_cursor(query, {inserted_at, id}) do
    where(
      query,
      [c],
      c.inserted_at < ^inserted_at or (c.inserted_at == ^inserted_at and c.id < ^id)
    )
  end

  defp localize_page(page, zone_resolution) do
    timestamps = Enum.map(page, & &1.inserted_at)
    Enum.zip(page, DisplayClock.localize_many(timestamps, zone_resolution))
  end

  defp cursor_for(localized_page) do
    {log, _local_at} = List.last(localized_page)
    {log.inserted_at, log.id}
  end

  # Stops once five destinations are known and this row is older than the
  # featured group's local day; older rows cannot change the returned groups'
  # identity or their newest-day counts.
  defp halt?(state, local_at) do
    map_size(state.destination_counts) >= @max_groups and
      state.featured_date != nil and
      Date.compare(NaiveDateTime.to_date(local_at), state.featured_date) == :lt
  end

  # -- Row folding --

  defp add_row(state, %ChangeLog{} = log, local_at) do
    state =
      if state.featured_date == nil do
        %{state | featured_date: NaiveDateTime.to_date(local_at)}
      else
        state
      end

    key = operation_key(log)
    destination = destination(log)
    rank = rank(log)

    case Map.get(state.operations, key) do
      nil ->
        operation = %{
          rows: [log],
          destination: destination,
          rank: rank,
          newest_at: log.inserted_at,
          newest_local_date: NaiveDateTime.to_date(local_at),
          actor_email: log.actor_email
        }

        %{
          state
          | operations: Map.put(state.operations, key, operation),
            destination_counts: increment(state.destination_counts, destination),
            count: state.count + 1
        }

      operation ->
        operation = %{operation | rows: [log | operation.rows]}

        if rank < operation.rank do
          %{
            state
            | operations:
                Map.put(state.operations, key, %{
                  operation
                  | destination: destination,
                    rank: rank
                }),
              destination_counts:
                move_destination(state.destination_counts, operation.destination, destination),
              count: state.count + 1
          }
        else
          %{
            state
            | operations: Map.put(state.operations, key, operation),
              count: state.count + 1
          }
        end
    end
  end

  defp operation_key(%ChangeLog{} = log) do
    case changed_fields(log) do
      %{"operation_id" => operation_id} when is_binary(operation_id) -> operation_id
      _ -> log.id
    end
  end

  defp rank(%ChangeLog{} = log) do
    if combination_destination_id(log) do
      Map.fetch!(@destination_precedence, "calendar")
    else
      Map.get(@destination_precedence, log.entity_type, @unknown_rank)
    end
  end

  defp destination(%ChangeLog{} = log) do
    case combination_destination_id(log) do
      nil -> entity_destination(log)
      service_id -> {:calendar, service_id}
    end
  end

  defp entity_destination(%ChangeLog{} = log) do
    cond do
      log.entity_type == "calendar" ->
        {:calendar, log.entity_external_id}

      log.entity_type == "route_pattern_build" ->
        {:route_patterns, log.entity_external_id}

      # A pattern-shape snapshot carries no route_id, so both types key by the
      # pattern alone and one pattern's edits share one destination; Describe
      # resolves the route from the pattern.
      log.entity_type in ["route_pattern", "pattern_shape"] ->
        {:route_pattern, nil, snapshot_field(log, "route_pattern_id")}

      log.entity_type == "timed_pattern" ->
        {:timed_pattern, snapshot_field(log, "route_pattern_id")}

      log.entity_type == "trip" ->
        {:schedules, trip_field(log, "route_id"), trip_field(log, "service_id")}

      log.entity_type in ["level", "stop", "pathway"] and is_binary(log.station_stop_id) ->
        {:station, log.station_stop_id, level_id(log)}

      true ->
        default_destination(log)
    end
  end

  # The types the cond above does not name: a shape edit has no editor surface,
  # a transfer rule has its own screen, a fare operation has the Fares section,
  # and every other type reads through the stop vocabulary. One alignment save
  # writes a row per section without an operation id, so all alignment rows share
  # one destination instead of one per stop pair.
  defp default_destination(%ChangeLog{entity_type: "alignment_segment"}), do: :alignment

  defp default_destination(%ChangeLog{entity_type: "transfer"}), do: :transfers
  defp default_destination(%ChangeLog{entity_type: "fare_version"}), do: :fares
  defp default_destination(%ChangeLog{} = log), do: {:stop, log.entity_external_id}

  # A level's GTFS `level_id` is its external id; a stop's is its snapshot value.
  defp level_id(%ChangeLog{entity_type: "level", entity_external_id: level_id}), do: level_id
  defp level_id(%ChangeLog{snapshot: %{} = snapshot}), do: Map.get(snapshot, "level_id")
  defp level_id(%ChangeLog{}), do: nil

  defp combination_destination_id(%ChangeLog{} = log) do
    case changed_fields(log) do
      %{"combination" => %{"destination_id" => service_id}} when is_binary(service_id) ->
        service_id

      _ ->
        nil
    end
  end

  defp snapshot_field(%ChangeLog{snapshot: %{} = snapshot}, field), do: Map.get(snapshot, field)
  defp snapshot_field(%ChangeLog{}, _field), do: nil

  defp trip_field(%ChangeLog{} = log, field) do
    fields = changed_fields(log)
    after_map = Map.get(fields, "after") || %{}
    before_map = Map.get(fields, "before") || %{}

    Map.get(after_map, field) || Map.get(before_map, field)
  end

  defp changed_fields(%ChangeLog{changed_fields: %{} = fields}), do: fields
  defp changed_fields(%ChangeLog{}), do: %{}

  defp increment(counts, destination), do: Map.update(counts, destination, 1, &(&1 + 1))

  defp move_destination(counts, from, to) do
    counts
    |> Map.update!(from, &(&1 - 1))
    |> then(fn counts ->
      if Map.fetch!(counts, from) == 0, do: Map.delete(counts, from), else: counts
    end)
    |> increment(to)
  end

  # -- Operation and destination grouping --

  defp build_groups(operations) do
    operations
    |> Map.values()
    |> Enum.group_by(& &1.destination)
    |> Enum.map(fn {destination, operations} -> build_group(destination, operations) end)
    |> Enum.sort_by(&DateTime.to_unix(&1.newest_at, :microsecond), :desc)
    |> Enum.take(@max_groups)
  end

  defp build_group(destination, operations) do
    newest = Enum.max_by(operations, &DateTime.to_unix(&1.newest_at, :microsecond))

    %{
      destination: destination,
      operations:
        operations
        |> Enum.sort_by(&DateTime.to_unix(&1.newest_at, :microsecond), :desc)
        |> Enum.map(&Enum.reverse(&1.rows)),
      newest_at: newest.newest_at,
      actor_email: newest.actor_email,
      same_day_count: Enum.count(operations, &(&1.newest_local_date == newest.newest_local_date))
    }
  end
end
