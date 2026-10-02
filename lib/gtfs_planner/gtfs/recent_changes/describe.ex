defmodule GtfsPlanner.Gtfs.RecentChanges.Describe do
  @moduledoc """
  Resolves recent-change destination groups into resume items.

  `GtfsPlanner.Gtfs.RecentChanges` groups a version's change logs by destination
  and knows nothing about names, existence or wording. This module performs one
  scoped lookup per destination type — routes, calendars, route patterns, stops
  and levels — and turns each group into the `resume_item` the homepage renders:
  a title, a kind-labelled context line with the agency-local time, a bounded
  change description, the route badge, and the params the web layer turns into an
  editor path.

  A group whose entity no longer exists keeps its computed text but becomes
  `kind: :none` with no params, so a deleted entity is shown without a link
  (AC-16). Alignment destinations have no editor surface and are always `:none`.
  Calendars are named the way the calendars screen names them: the stored
  `service_description`, else the service ID. A calendar exists while it has a
  `calendar` or `calendar_dates` row or an attribute anchor, because an imported
  calendar gets an anchor only when it is first edited. Every lookup is scoped
  by the caller's organization and version ids, and nothing is written.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.RecentChanges
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values
  alias GtfsPlanner.Wording

  @weekday_fields ~w(monday tuesday wednesday thursday friday saturday sunday)
  @position_fields ~w(stop_lat stop_lon)

  @type resume_item :: %{
          kind:
            :schedules
            | :calendar
            | :route_pattern
            | :route_patterns
            | :station
            | :stop
            | :transfers
            | :none,
          title: String.t(),
          context: String.t(),
          detail: String.t(),
          route:
            %{
              route_id: String.t(),
              route_short_name: String.t() | nil,
              route_color: String.t() | nil,
              route_text_color: String.t() | nil
            }
            | nil,
          params: %{
            optional(:route_id | :service_id | :route_pattern_id | :stop_id | :level_id) =>
              String.t()
          },
          actor_email: String.t(),
          local_at: NaiveDateTime.t(),
          same_day_count: pos_integer()
        }

  @doc """
  Describes recent-change groups as resume items, newest first.

  Group order, actor and day counts pass through unchanged; only the displayed
  text, the resolved names, the route badge and the link params are derived here.
  """
  @spec describe(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          [RecentChanges.group()],
          DisplayClock.zone_resolution()
        ) :: [resume_item()]
  def describe(organization_id, gtfs_version_id, groups, zone_resolution) do
    lookups = load_lookups(organization_id, gtfs_version_id, groups)
    local_times = DisplayClock.localize_many(Enum.map(groups, & &1.newest_at), zone_resolution)

    groups
    |> Enum.zip(local_times)
    |> Enum.map(fn {group, local_at} -> describe_group(group, local_at, lookups) end)
  end

  # -- One scoped lookup per destination type --

  defp load_lookups(organization_id, version_id, groups) do
    route_ids = destination_keys(groups, &route_key/1)
    service_ids = destination_keys(groups, &service_key/1)
    pattern_ids = destination_keys(groups, &pattern_key/1)
    pattern_uuids = destination_keys(groups, &timed_pattern_key/1)
    stop_ids = destination_keys(groups, &stop_key/1)
    level_ids = destination_keys(groups, &level_key/1)

    patterns = route_patterns(organization_id, version_id, pattern_ids, pattern_uuids)

    %{
      routes: routes(organization_id, version_id, route_ids),
      calendars: calendars(organization_id, version_id, service_ids),
      services: services(organization_id, version_id, service_ids),
      patterns: Map.new(patterns, &{&1.route_pattern_id, &1}),
      pattern_uuids: Map.new(patterns, &{&1.id, &1}),
      stops: stops(organization_id, version_id, stop_ids),
      levels: levels(organization_id, version_id, level_ids)
    }
  end

  defp destination_keys(groups, extractor) do
    groups
    |> Enum.map(& &1.destination)
    |> Enum.map(extractor)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp route_key({:schedules, route_id, _service_id}), do: route_id
  defp route_key({:route_patterns, route_id}), do: route_id
  defp route_key({:route_pattern, route_id, _route_pattern_id}), do: route_id
  defp route_key(_destination), do: nil

  defp service_key({:calendar, service_id}), do: service_id
  defp service_key({:schedules, _route_id, service_id}), do: service_id
  defp service_key(_destination), do: nil

  defp pattern_key({:route_pattern, _route_id, route_pattern_id}), do: route_pattern_id
  defp pattern_key(_destination), do: nil

  defp timed_pattern_key({:timed_pattern, route_pattern_uuid}), do: route_pattern_uuid
  defp timed_pattern_key(_destination), do: nil

  defp stop_key({:station, station_stop_id, _level_id}), do: station_stop_id
  defp stop_key({:stop, stop_id}), do: stop_id
  defp stop_key(_destination), do: nil

  defp level_key({:station, _station_stop_id, level_id}), do: level_id
  defp level_key(_destination), do: nil

  defp routes(_organization_id, _version_id, []), do: %{}

  defp routes(organization_id, version_id, route_ids) do
    Route
    |> where([r], r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id)
    |> where([r], r.route_id in ^route_ids)
    |> select([r], %{
      route_id: r.route_id,
      route_short_name: r.route_short_name,
      route_long_name: r.route_long_name,
      route_color: r.route_color,
      route_text_color: r.route_text_color
    })
    |> Repo.all()
    |> Map.new(&{&1.route_id, &1})
  end

  defp calendars(_organization_id, _version_id, []), do: %{}

  defp calendars(organization_id, version_id, service_ids) do
    CalendarAttribute
    |> where([c], c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id)
    |> where([c], c.service_id in ^service_ids)
    |> select([c], %{service_id: c.service_id, service_description: c.service_description})
    |> Repo.all()
    |> Map.new(&{&1.service_id, &1})
  end

  defp services(_organization_id, _version_id, []), do: MapSet.new()

  defp services(organization_id, version_id, service_ids) do
    calendar_dates =
      CalendarDate
      |> where([d], d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id)
      |> where([d], d.service_id in ^service_ids)
      |> select([d], d.service_id)

    # Fully qualified: an alias would shadow Elixir's `Calendar.strftime/2` below.
    GtfsPlanner.Gtfs.Calendar
    |> where([c], c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id)
    |> where([c], c.service_id in ^service_ids)
    |> select([c], c.service_id)
    |> union(^calendar_dates)
    |> Repo.all()
    |> MapSet.new()
  end

  defp route_patterns(_organization_id, _version_id, [], []), do: []

  defp route_patterns(organization_id, version_id, pattern_ids, pattern_uuids) do
    RoutePattern
    |> join(:inner, [rp], r in Route,
      on:
        r.organization_id == rp.organization_id and r.gtfs_version_id == rp.gtfs_version_id and
          r.route_id == rp.route_id
    )
    |> where([rp], rp.organization_id == ^organization_id and rp.gtfs_version_id == ^version_id)
    |> filter_pattern_keys(pattern_ids, pattern_uuids)
    |> select([rp, r], %{
      id: rp.id,
      route_pattern_id: rp.route_pattern_id,
      route_id: rp.route_id,
      route_short_name: r.route_short_name,
      route_long_name: r.route_long_name,
      route_color: r.route_color,
      route_text_color: r.route_text_color
    })
    |> Repo.all()
  end

  defp filter_pattern_keys(query, [], pattern_uuids),
    do: where(query, [rp, _r], rp.id in ^pattern_uuids)

  defp filter_pattern_keys(query, pattern_ids, []),
    do: where(query, [rp, _r], rp.route_pattern_id in ^pattern_ids)

  defp filter_pattern_keys(query, pattern_ids, pattern_uuids) do
    where(query, [rp, _r], rp.route_pattern_id in ^pattern_ids or rp.id in ^pattern_uuids)
  end

  defp stops(_organization_id, _version_id, []), do: %{}

  defp stops(organization_id, version_id, stop_ids) do
    Stop
    |> where([s], s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id)
    |> where([s], s.stop_id in ^stop_ids)
    |> select([s], %{stop_id: s.stop_id, stop_name: s.stop_name})
    |> Repo.all()
    |> Map.new(&{&1.stop_id, &1})
  end

  defp levels(_organization_id, _version_id, []), do: %{}

  defp levels(organization_id, version_id, level_ids) do
    Level
    |> where([l], l.organization_id == ^organization_id and l.gtfs_version_id == ^version_id)
    |> where([l], l.level_id in ^level_ids)
    |> select([l], %{level_id: l.level_id, level_name: l.level_name})
    |> Repo.all()
    |> Map.new(&{&1.level_id, &1})
  end

  # -- Item assembly --

  defp describe_group(group, local_at, lookups) do
    resolved = resolve(group, lookups)

    %{
      kind: resolved.kind,
      title: resolved.title,
      context: context(resolved.label, local_at, resolved.level_name),
      detail: resolved.detail,
      route: resolved.route,
      params: resolved.params,
      actor_email: group.actor_email,
      local_at: local_at,
      same_day_count: group.same_day_count
    }
  end

  defp resolve(%{destination: {:schedules, route_id, service_id}} = group, lookups) do
    route = Map.get(lookups.routes, route_id)
    trips = trip_count(group)

    detail =
      "#{trips} #{Wording.noun(trips, "trip")} changed on #{calendar_name(lookups, service_id)}"

    base_item(:schedules, "Schedules", route_title(route, route_id), detail,
      exists?: not is_nil(route),
      route: route_badge(route),
      params: %{route_id: route_id, service_id: service_id}
    )
  end

  defp resolve(%{destination: {:calendar, service_id}} = group, lookups) do
    base_item(:calendar, "Calendar", calendar_name(lookups, service_id), calendar_detail(group),
      exists?:
        Map.has_key?(lookups.calendars, service_id) or
          MapSet.member?(lookups.services, service_id),
      params: %{service_id: service_id}
    )
  end

  defp resolve(%{destination: {:route_patterns, route_id}} = group, lookups) do
    route = Map.get(lookups.routes, route_id)

    base_item(
      :route_patterns,
      "Patterns",
      route_title(route, route_id),
      change_detail(newest_row(group), "patterns built"),
      exists?: not is_nil(route),
      route: route_badge(route),
      params: %{route_id: route_id}
    )
  end

  defp resolve(%{destination: {:route_pattern, route_id, route_pattern_id}} = group, lookups) do
    pattern = Map.get(lookups.patterns, route_pattern_id)
    resolved_route_id = route_id || (pattern && pattern.route_id)

    base_item(
      :route_pattern,
      "Pattern",
      route_title(pattern, resolved_route_id || route_pattern_id),
      pattern_detail(group),
      exists?: not is_nil(pattern),
      route: route_badge(pattern),
      params: %{route_id: resolved_route_id, route_pattern_id: route_pattern_id}
    )
  end

  defp resolve(%{destination: {:timed_pattern, route_pattern_uuid}} = group, lookups) do
    pattern = Map.get(lookups.pattern_uuids, route_pattern_uuid)

    base_item(
      :route_pattern,
      "Pattern",
      route_title(pattern, route_pattern_uuid),
      pattern_detail(group),
      exists?: not is_nil(pattern),
      route: route_badge(pattern),
      params: pattern && pattern_params(pattern)
    )
  end

  defp resolve(%{destination: {:station, station_stop_id, level_id}} = group, lookups) do
    stop = Map.get(lookups.stops, station_stop_id)
    level = level_id && Map.get(lookups.levels, level_id)

    base_item(:station, "Station", stop_title(stop, station_stop_id), station_detail(group),
      exists?: not is_nil(stop),
      params: station_params(station_stop_id, level_id),
      level_name: level && level.level_name
    )
  end

  defp resolve(%{destination: {:stop, stop_id}} = group, lookups) do
    stop = Map.get(lookups.stops, stop_id)

    base_item(:stop, "Stop", stop_title(stop, stop_id), stop_detail(group),
      exists?: not is_nil(stop),
      params: %{stop_id: stop_id}
    )
  end

  defp resolve(%{destination: :transfers} = group, _lookups) do
    base_item(:transfers, "Transfers", "Transfers", transfer_detail(group), params: %{})
  end

  defp resolve(%{destination: :alignment} = group, _lookups) do
    base_item(:none, "Shape", "Shape", alignment_detail(group), exists?: false)
  end

  # A missing entity keeps the computed text but loses its kind, badge, params
  # and therefore its link (AC-16).
  defp base_item(kind, label, title, detail, opts) do
    exists? = Keyword.get(opts, :exists?, true)

    %{
      kind: if(exists?, do: kind, else: :none),
      label: label,
      title: title,
      detail: detail,
      route: if(exists?, do: Keyword.get(opts, :route), else: nil),
      params: if(exists?, do: Keyword.get(opts, :params, %{}), else: %{}),
      level_name: Keyword.get(opts, :level_name)
    }
  end

  defp pattern_params(pattern) do
    %{route_id: pattern.route_id, route_pattern_id: pattern.route_pattern_id}
  end

  defp station_params(station_stop_id, nil), do: %{stop_id: station_stop_id}

  defp station_params(station_stop_id, level_id),
    do: %{stop_id: station_stop_id, level_id: level_id}

  defp context(label, local_at, level_name) when is_binary(level_name) and level_name != "" do
    "#{label} · #{level_name} · #{local_time(local_at)}"
  end

  defp context(label, local_at, _level_name), do: "#{label} · #{local_time(local_at)}"

  defp local_time(local_at) do
    Calendar.strftime(local_at, "%b %-d") <> ", " <> DisplayClock.format_time(local_at)
  end

  defp route_title(nil, fallback), do: fallback || "Unknown"

  defp route_title(route, fallback) do
    cond do
      Values.present?(route.route_long_name) -> route.route_long_name
      Values.present?(route.route_short_name) -> route.route_short_name
      is_binary(route.route_id) -> route.route_id
      true -> fallback || "Unknown"
    end
  end

  defp route_badge(nil), do: nil

  defp route_badge(route) do
    %{
      route_id: route.route_id,
      route_short_name: route.route_short_name,
      route_color: route.route_color,
      route_text_color: route.route_text_color
    }
  end

  defp stop_title(nil, fallback), do: fallback
  defp stop_title(%{stop_name: name}, _fallback) when is_binary(name) and name != "", do: name
  defp stop_title(_stop, fallback), do: fallback

  defp calendar_name(lookups, service_id) do
    case Map.get(lookups.calendars, service_id) do
      %{service_description: name} when is_binary(name) and name != "" -> name
      _ -> service_id
    end
  end

  # -- Bounded description vocabulary --

  defp trip_count(group) do
    group.operations
    |> List.flatten()
    |> Enum.filter(&(&1.entity_type == "trip"))
    |> Enum.map(& &1.entity_external_id)
    |> Enum.uniq()
    |> length()
  end

  # The newest operation describes the item. A combination's envelope sits on
  # the destination calendar's row, or on one trip row when the destination's
  # dates did not change.
  defp calendar_detail(%{operations: [operation | _]}) do
    row =
      Enum.find(operation, &match?(%{"combination" => %{}}, changed_fields(&1))) ||
        Enum.find(operation, &(&1.entity_type == "calendar")) || hd(operation)

    fields = changed_fields(row)

    case fields["combination"] do
      %{"selected_service_ids" => ids} when is_list(ids) -> combination_detail(ids)
      _ -> change_detail(row, calendar_change_detail(fields))
    end
  end

  defp combination_detail(ids) when length(ids) > 1 do
    count = length(ids) - 1
    "combined with #{count} #{Wording.noun(count, "calendar")}"
  end

  defp combination_detail(_ids), do: "calendar changed"

  defp calendar_change_detail(fields) do
    before = calendar_snapshot(fields, "before")
    after_snapshot = calendar_snapshot(fields, "after")
    before_weekly = Map.get(before, "weekly") || %{}
    after_weekly = Map.get(after_snapshot, "weekly") || %{}

    cond do
      moved?(before_weekly, after_weekly, "end_date") ->
        "end date moved to " <> format_date(after_weekly["end_date"])

      moved?(before_weekly, after_weekly, "start_date") ->
        "start date moved to " <> format_date(after_weekly["start_date"])

      weekdays_changed?(before_weekly, after_weekly) ->
        "days of service changed"

      Map.get(before, "dates") != Map.get(after_snapshot, "dates") ->
        "dates added or removed"

      true ->
        "calendar changed"
    end
  end

  defp calendar_snapshot(fields, key) do
    case Map.get(fields, key) do
      %{} = snapshot -> snapshot
      _ -> %{}
    end
  end

  defp moved?(before, after_snapshot, key) do
    value = Map.get(after_snapshot, key)
    is_binary(value) and value != Map.get(before, key)
  end

  defp weekdays_changed?(before, after_snapshot) do
    Enum.any?(@weekday_fields, &(Map.get(before, &1) != Map.get(after_snapshot, &1)))
  end

  defp format_date(iso_date) do
    case Date.from_iso8601(iso_date) do
      {:ok, date} -> Calendar.strftime(date, "%b %-d")
      {:error, _reason} -> iso_date
    end
  end

  defp pattern_detail(group) do
    row = newest_row(group)
    fallback = if row.entity_type == "pattern_shape", do: "shape redrawn", else: "pattern changed"
    change_detail(row, fallback)
  end

  defp station_detail(group) do
    row = newest_row(group)

    case row.entity_type do
      "level" -> change_detail(row, "level changed")
      "pathway" -> pathway_detail(row)
      _ -> stop_detail(group)
    end
  end

  defp pathway_detail(row) do
    case row.action do
      "created" -> "pathway added"
      "deleted" -> "pathway removed"
      _ -> "pathway changed"
    end
  end

  defp stop_detail(group) do
    row = newest_row(group)
    change_detail(row, stop_fields_detail(changed_fields(row)))
  end

  defp stop_fields_detail(fields) do
    keys = fields |> Map.keys() |> Enum.reject(&(&1 == "operation_id"))

    cond do
      Enum.any?(keys, &(&1 in @position_fields)) -> "location moved"
      "stop_name" in keys -> "renamed"
      true -> "#{length(keys)} #{Wording.noun(length(keys), "field")} changed"
    end
  end

  defp transfer_detail(group) do
    case newest_row(group).action do
      "created" -> "transfer rule added"
      "deleted" -> "transfer rule removed"
      _ -> "transfer rule changed"
    end
  end

  defp alignment_detail(group), do: change_detail(newest_row(group), "shape redrawn")

  defp change_detail(row, fallback) do
    case row.action do
      "created" -> "created"
      "deleted" -> "deleted"
      _ -> fallback
    end
  end

  defp newest_row(%{operations: [operation | _]}), do: hd(operation)

  defp changed_fields(%ChangeLog{changed_fields: %{} = fields}), do: fields
  defp changed_fields(%ChangeLog{}), do: %{}
end
