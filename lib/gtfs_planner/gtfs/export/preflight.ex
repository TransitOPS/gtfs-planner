defmodule GtfsPlanner.Gtfs.Export.Preflight do
  @moduledoc """
  Checks one version for known GTFS violations before an export is built.

  Each check runs scoped SQL for the organization and version and reports at most
  one aggregate issue with a count and up to five example IDs, so no check can
  crowd another out of the run's warning limit. The export still builds; the
  export worker stores each issue as a warning.

  The pathways export contains only stops, levels and pathways, so it runs only
  the stop and pathway checks.

  Fares are checked here through `GtfsPlanner.Gtfs.Fares.Checks`, the same read
  model the Checks tab draws. Its repair and review items become one warning each
  under a `fares_` code, and its notes stay out of the run because a note is not a
  fault with this version. Every other check answers one aggregate issue, so
  `run/3` flattens a check that answers a list.

  `inspect_summary/3` returns the same checks as `run/3` with each aggregate
  count, the entity it counts and its retained examples as values, so a caller
  never has to parse a message to learn how much of a feed is affected.

  Transfers are checked here with their own set-based query. The Transfers page
  flags rules that need attention through `GtfsPlanner.Gtfs.Transfers`, but that
  logic loads every transfer and its stops, routes and trips before it judges
  them, and it also reports conflicts and in-seat rows differently, so it cannot
  answer "how many transfers name something that does not exist" in SQL.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.{
    Agency,
    Calendar,
    CalendarDate,
    FeedSettings,
    Pathway,
    Route,
    Stop,
    Transfer,
    Trip
  }

  alias GtfsPlanner.Gtfs.Fares.Checks, as: FareChecks
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Wording

  @sample_size 5
  @exit_gate 7
  @pathway_checks [:station_with_parent, :stops_missing_coordinates, :bidirectional_exit_gate]
  @feed_checks [
    :mixed_agency_timezones,
    :transfer_missing_reference,
    :trip_missing_service,
    :fares
  ]

  # Each transfer column with the schema and key that must contain its value.
  @transfer_references [
    {:from_stop_id, Stop, :stop_id},
    {:to_stop_id, Stop, :stop_id},
    {:from_route_id, Route, :route_id},
    {:to_route_id, Route, :route_id},
    {:from_trip_id, Trip, :trip_id},
    {:to_trip_id, Trip, :trip_id}
  ]

  @type issue :: %{code: String.t(), message: String.t()}

  @typedoc """
  One check that has findings, with the count itself instead of only prose.

  `total` counts every affected entity the check's own SQL matched, `unit`
  names the kind of entity that count is about, and `examples` retains at most
  five of them in the query's own deterministic order. `completeness` is
  `"complete"` only when those examples cover the whole count; it is
  `"sampled"` whenever the list is shorter than the count, and for transfers
  always, because a transfer's example names the reference it is missing rather
  than the transfer itself. A fare finding is one repair or review item, so its
  total is one and it retains no examples.
  """
  @type summary :: %{
          code: String.t(),
          message: String.t(),
          total: non_neg_integer(),
          unit: :transfers | :trips | :stations | :timezones | :pathways | :fares,
          examples: [String.t()],
          completeness: String.t()
        }

  @doc """
  Returns `:ok`, or `{:error, issues}` with one issue per check that has findings.

  `export_type` selects the checks that apply to the files the export contains.
  """
  @spec run(Ecto.UUID.t(), Ecto.UUID.t(), :full | :pathways | :operations) ::
          :ok | {:error, [issue()]}
  def run(organization_id, gtfs_version_id, export_type \\ :full) do
    case inspect_summary(organization_id, gtfs_version_id, export_type) do
      [] -> :ok
      summaries -> {:error, Enum.map(summaries, &%{code: &1.code, message: &1.message})}
    end
  end

  @doc """
  Returns one structured finding per check that has findings, in check order.

  This is the same scoped SQL as `run/3`, with the aggregate count, the entity
  it counts and the retained examples returned as values instead of only being
  written into a message. Nothing here parses a message or infers a total from
  one, so a caller can show an exact number next to its examples.

  `mixed_agency_timezones` reports the number of conflicting timezones the
  existing message states, with `unit: :timezones` naming what that number counts
  (not the agencies that use them).
  """
  @spec inspect_summary(Ecto.UUID.t(), Ecto.UUID.t(), :full | :pathways | :operations) ::
          [summary()]
  def inspect_summary(organization_id, gtfs_version_id, export_type \\ :full) do
    export_type
    |> checks()
    |> Enum.flat_map(&List.wrap(check(&1, organization_id, gtfs_version_id)))
    |> Enum.reject(&is_nil/1)
  end

  defp checks(:pathways), do: @pathway_checks
  defp checks(_export_type), do: @pathway_checks ++ @feed_checks

  # A station (location_type 1) with a parent_station.
  defp check(:station_with_parent, organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      where: s.location_type == 1 and not is_nil(s.parent_station) and s.parent_station != ""
    )
    |> count_and_sample(:stop_id)
    |> finding("station_with_parent", :stations, fn count, examples ->
      "#{count} #{Wording.noun(count, "station has", "stations have")} a parent station " <>
        "(for example #{examples}). GTFS does not allow a station inside another station. " <>
        "Change its type on the parent station's Floorplans tab or re-import the stops."
    end)
  end

  # Stops, stations and entrances need coordinates; nil location_type means 0.
  # Generic nodes (3) and boarding areas (4) may leave them empty.
  defp check(:stops_missing_coordinates, organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      where: is_nil(s.location_type) or s.location_type in [0, 1, 2],
      where: is_nil(s.stop_lat) or is_nil(s.stop_lon)
    )
    |> count_and_sample(:stop_id)
    |> finding("stops_missing_coordinates", :stations, fn count, examples ->
      "#{count} #{Wording.noun(count, "stop, station or entrance has", "stops, stations or entrances have")} " <>
        "no latitude/longitude (for example #{examples}). GTFS requires coordinates for these. " <>
        "Add them on the station's Floorplans tab or re-import the stops."
    end)
  end

  defp check(:bidirectional_exit_gate, organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id,
      where: p.pathway_mode == @exit_gate and p.is_bidirectional
    )
    |> count_and_sample(:pathway_id)
    |> finding("bidirectional_exit_gate", :pathways, fn count, examples ->
      "#{count} #{Wording.noun(count, "exit gate is", "exit gates are")} two-way " <>
        "(for example #{examples}). GTFS requires exit gates to be one-way. " <>
        "Open each pathway on the station's Floorplans tab and save it to make it one-way."
    end)
  end

  # `FeedSettings.agency_health/2` owns the timezone verdict. A version with no
  # agency or one agency never resolves as conflicting.
  defp check(:mixed_agency_timezones, organization_id, gtfs_version_id) do
    case FeedSettings.agency_health(organization_id, gtfs_version_id).zone do
      {:unresolved, :conflicting} -> mixed_timezones_issue(organization_id, gtfs_version_id)
      _other -> nil
    end
  end

  defp check(:transfer_missing_reference, organization_id, gtfs_version_id) do
    references = subquery(missing_transfer_references(organization_id, gtfs_version_id))

    case Repo.one(from(r in references, select: count(r.transfer_id, :distinct))) do
      0 ->
        nil

      count ->
        examples =
          from(r in references,
            distinct: true,
            order_by: r.reference,
            limit: @sample_size,
            select: r.reference
          )
          |> Repo.all()

        finding({count, examples}, "transfer_missing_reference", :transfers, fn count, examples ->
          "#{count} #{Wording.noun(count, "transfer names", "transfers name")} a stop, route or trip " <>
            "that does not exist in this version (for example #{examples}). " <>
            "GTFS requires transfers to name existing stops, routes and trips. " <>
            "Fix or delete #{Wording.noun(count, "it", "them")} on the Transfers page."
        end)
    end
  end

  # Anti-joins each trip's service against calendar and calendar_dates. DISTINCT ON
  # makes the sample the missing service IDs while the window count stays the
  # number of trips, because the window is evaluated before DISTINCT. Trips of an
  # explicitly inactive route are skipped because the export leaves them out.
  defp check(:trip_missing_service, organization_id, gtfs_version_id) do
    from(t in Trip,
      as: :trip,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      where:
        not exists(
          from(r in Route,
            where:
              r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
                r.route_id == parent_as(:trip).route_id and r.active == false
          )
        ),
      where:
        not exists(
          from(c in Calendar,
            where:
              c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id and
                c.service_id == parent_as(:trip).service_id
          )
        ),
      where:
        not exists(
          from(d in CalendarDate,
            where:
              d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id and
                d.service_id == parent_as(:trip).service_id
          )
        ),
      distinct: t.service_id
    )
    |> count_and_sample(:service_id)
    |> finding("trip_missing_service", :trips, fn count, examples ->
      "#{count} #{Wording.noun(count, "trip uses", "trips use")} a service ID that has no calendar or " <>
        "calendar dates (for example #{examples}). GTFS requires every trip's service to be " <>
        "defined. Add the service on the Calendars page or re-import the calendars."
    end)
  end

  # `Fares.Checks` reads the version's fares through the same model every fare
  # tab draws, so a warning names a hole the operator can also see on the Checks
  # tab. Its repair and review items are faults; its notes are not (R16, AC-32).
  defp check(:fares, organization_id, gtfs_version_id) do
    %{repair: repair, review: review} =
      FareChecks.run(organization_id, gtfs_version_id)

    Enum.map(repair ++ review, &fare_finding/1)
  end

  # One repair or review item is one finding with no retained example: the item
  # itself is the whole of what the check found.
  defp fare_finding(%{code: code, title: title} = item) do
    body = Map.get(item, :body)

    message =
      if is_binary(body) and body != "",
        do: title <> ". " <> body,
        else: title

    %{
      code: "fares_" <> code,
      unit: :fares,
      total: 1,
      examples: [],
      completeness: "complete",
      message: message
    }
  end

  defp mixed_timezones_issue(organization_id, gtfs_version_id) do
    from(a in Agency,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
      where: fragment("btrim(?) <> ''", a.agency_timezone),
      group_by: fragment("btrim(?)", a.agency_timezone),
      order_by: fragment("btrim(?)", a.agency_timezone),
      limit: @sample_size,
      select: {fragment("btrim(?)", a.agency_timezone), over(count())}
    )
    |> Repo.all()
    |> summarize()
    |> finding("mixed_agency_timezones", :timezones, fn count, examples ->
      "Agencies in this feed use #{count} different timezones (#{examples}). " <>
        "GTFS requires one timezone for every agency in a feed. " <>
        "Set the same timezone on every agency in Settings > Agencies."
    end)
  end

  # One row per (transfer, missing reference). Each anti-join is scoped to the
  # transfer's own organization and version.
  defp missing_transfer_references(organization_id, gtfs_version_id) do
    [first | rest] =
      Enum.map(@transfer_references, fn {column, schema, key} ->
        from(t in Transfer,
          as: :transfer,
          where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
          where: not is_nil(field(t, ^column)),
          where:
            not exists(
              from(r in schema,
                where:
                  r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
                    field(r, ^key) == field(parent_as(:transfer), ^column)
              )
            ),
          select: %{transfer_id: t.id, reference: field(t, ^column)}
        )
      end)

    Enum.reduce(rest, first, &union_all(&2, ^&1))
  end

  # `count(*) OVER ()` is evaluated before LIMIT, so one query returns both the
  # number of matching rows and the first few IDs.
  defp count_and_sample(query, id_field) do
    from(r in query,
      order_by: field(r, ^id_field),
      limit: @sample_size,
      select: {field(r, ^id_field), over(count())}
    )
    |> Repo.all()
    |> summarize()
  end

  defp summarize([]), do: nil
  defp summarize([{_id, count} | _] = rows), do: {count, Enum.map(rows, &elem(&1, 0))}

  defp finding(nil, _code, _unit, _message), do: nil

  defp finding({count, examples}, code, unit, message) do
    %{
      code: code,
      unit: unit,
      total: count,
      examples: examples,
      completeness: completeness(unit, count, length(examples)),
      message: message.(count, Enum.join(examples, ", "))
    }
  end

  # A transfer's examples name the reference it is missing, so several examples
  # can stand for one transfer and a transfer with one missing reference can be
  # indistinguishable from a transfer with two. No list of them can claim to
  # cover every affected transfer, so this unit is never complete.
  defp completeness(:transfers, _total, _retained), do: "sampled"
  defp completeness(_unit, total, retained) when retained >= total, do: "complete"
  defp completeness(_unit, _total, _retained), do: "sampled"
end
