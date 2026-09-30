defmodule GtfsPlanner.Gtfs.Fares.Interpreter do
  @moduledoc """
  Reads one version's fare rows and turns one leg into the products that price it.

  `load_rows/2` loads the version's rows into a
  `GtfsPlanner.Gtfs.Fares.Interpreter.Rows` struct and every other function is pure
  over that struct: nothing here queries the database, calls a `Fares` writer or
  calls `Fares.Normalize` (CR-2), so a conversion check and a journey price are both
  worked out from the rows as they stand. Every load is scoped by
  `organization_id` and `gtfs_version_id` together, and the unscoped `get_*!`
  helpers in `GtfsPlanner.Gtfs` are never used (INV-5).

  `leg_products/5` follows the five steps the reference gives for pricing one leg
  (`fare_leg_rules.txt` in the GTFS reference, "Leg matching", as quoted in
  `.specs/_references/reports/GTFS fares v1 and v2 authoring research.md`):

  1. filter the rules on `network_id`, `from_area_id`, `to_area_id`,
     `from_timeframe_group_id` and `to_timeframe_group_id`;
  2. an exact match is processed;
  3. when no `rule_priority` value exists in the version's rules, an empty
     `network_id`, `from_area_id` or `to_area_id` "corresponds to all networks
     [areas] ... excluding the ones listed" in the other rules of the file;
  4. when a `rule_priority` value exists, an empty value "indicates the network
     [departure area, arrival area] of the leg does not affect the matching of this
     rule", and "the rule or set of rules with the highest value for
     `rule_priority` will be selected";
  5. otherwise the fare is unknown, which this function answers as an empty list.

  Step 3's exclusion is read as excluding the values that another rule *also
  applying to this leg* lists, so a version holding one network rule and one rule
  with three empty conditions prices that network's own legs from the first and
  every other leg from the second (AC-4). A rule listing a value no other rule
  demands does not narrow the empty rule, which is the reading that keeps a
  "any network, any area" rule usable for the legs the file never enumerated.

  The timeframe columns use step 4's "does not affect" reading in both modes: an
  empty timeframe matches at any time, and a rule naming a timeframe group matches
  only when `active_timeframes/3` reports that group as active for the leg.

  The mode is chosen the way OpenTripPlanner chooses it: one `rule_priority` value
  anywhere in the version's rules turns on priority semantics for all of them, and a
  version whose rules name the column but store no value keeps the older reading.
  Issue #575 may reword this; `Fares.Normalize` is the only writer of these columns
  and this module is the only reader of the priority semantics (INV-4).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Calendar, as: ServiceCalendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Interpreter.Rows
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.Timeframe
  alias GtfsPlanner.Repo

  # The columns the reference filters a leg rule on. The first three carry the
  # "all others" reading when no `rule_priority` value exists; the timeframe pair
  # always means "does not affect" when empty.
  @condition_fields [:network_id, :from_area_id, :to_area_id]
  @timeframe_fields [:from_timeframe_group_id, :to_timeframe_group_id]
  @rule_fields @condition_fields ++ @timeframe_fields

  # `Date.day_of_week/1` counts Monday as 1, which is the order of the
  # `calendar.txt` weekday columns.
  @weekday_fields [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]

  @added_exception 1
  @removed_exception 2

  @end_of_day 86_400

  @doc """
  Loads the version's fare rows, once, for the interpreter to read.

  Each table is one scoped query filtered by this organization and version. A stop's
  areas are the version's `stop_areas` rows, or its `stops.zone_id` values when the
  version is managed, because a managed version's areas are its fare zones and
  `GtfsPlanner.Gtfs.FareZones` writes the zone ids those rows are built from.
  """
  @spec load_rows(Ecto.UUID.t(), Ecto.UUID.t()) :: Rows.t()
  def load_rows(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    managed? = Fares.managed?(organization_id, gtfs_version_id)

    %Rows{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      managed?: managed?,
      fare_products: scoped(FareProduct, organization_id, gtfs_version_id),
      fare_leg_rules: scoped(FareLegRule, organization_id, gtfs_version_id),
      fare_transfer_rules: scoped(FareTransferRule, organization_id, gtfs_version_id),
      timeframes: scoped(Timeframe, organization_id, gtfs_version_id),
      networks: scoped(Network, organization_id, gtfs_version_id),
      route_networks: route_networks(organization_id, gtfs_version_id),
      route_network_ids: route_network_ids(organization_id, gtfs_version_id),
      stop_areas: stop_areas(organization_id, gtfs_version_id, managed?),
      stop_zones: stop_zones(organization_id, gtfs_version_id),
      fare_attributes: scoped(FareAttribute, organization_id, gtfs_version_id),
      fare_rules: scoped(FareRule, organization_id, gtfs_version_id),
      calendars: scoped(ServiceCalendar, organization_id, gtfs_version_id),
      calendar_dates: scoped(CalendarDate, organization_id, gtfs_version_id)
    }
  end

  @doc """
  The `fare_product_id` values that price one leg, in rule order, without repeats.

  `network_id`, `from_area_id` and `to_area_id` are the leg's own values and `nil`
  where the leg has none — a route in no network, a stop in no area. `timeframe_ids`
  are the groups `active_timeframes/3` reports for the leg, read against both
  timeframe columns of a rule.

  An empty list is the reference's "the fare is unknown", which callers report as a
  problem rather than a free leg.
  """
  @spec leg_products(Rows.t(), String.t() | nil, String.t() | nil, String.t() | nil, [String.t()]) ::
          [String.t()]
  def leg_products(%Rows{} = rows, network_id, from_area_id, to_area_id, timeframe_ids) do
    leg = %{
      network_id: presence(network_id),
      from_area_id: presence(from_area_id),
      to_area_id: presence(to_area_id),
      timeframes: MapSet.new(timeframe_ids, &presence/1)
    }

    if priority_semantics?(rows.fare_leg_rules) do
      rows.fare_leg_rules
      |> Enum.filter(&matches?(&1, leg))
      |> highest_priority()
    else
      empty_semantics(rows.fare_leg_rules, leg)
    end
  end

  @doc """
  The timeframe group ids whose service runs on `date` and whose interval holds `time`.

  `time` is seconds after local midnight, as a journey's departure is carried. A group
  counts when *any* of its rows matches, which is how the reference reads a timeframe
  group; a row matches when its `start_time` (empty is `00:00:00`) is at or before the
  time and its `end_time` (empty, or `24:00:00`, is the end of the day) is after it.
  A `calendar_dates` row for the date decides the service either way: added runs, and
  removed does not.
  """
  @spec active_timeframes(Rows.t(), Date.t(), non_neg_integer()) :: [String.t()]
  def active_timeframes(%Rows{} = rows, %Date{} = date, time)
      when is_integer(time) and time >= 0 do
    running = services_on(rows, date)

    rows.timeframes
    |> Enum.filter(&(MapSet.member?(running, &1.service_id) and within?(&1, time)))
    |> Enum.map(& &1.timeframe_group_id)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  @doc """
  The network a route belongs to, or `nil` when the feed places it in none.

  `route_networks.txt` answers when the version has it, because a route belongs to at
  most one network; otherwise `routes.network_id` does, which is how a feed that uses
  only that column is read. The reference forbids the two carriers together, and a
  managed version's export drops `route_networks.txt` (R8).
  """
  @spec network_for_route(Rows.t(), String.t()) :: String.t() | nil
  def network_for_route(%Rows{} = rows, route_id) do
    presence(Map.get(rows.route_networks, route_id) || Map.get(rows.route_network_ids, route_id))
  end

  defp scoped(queryable, organization_id, gtfs_version_id) do
    Repo.all(
      from row in queryable,
        where:
          row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id
    )
  end

  defp route_networks(organization_id, gtfs_version_id) do
    RouteNetwork
    |> scoped(organization_id, gtfs_version_id)
    |> Map.new(&{&1.route_id, &1.network_id})
  end

  defp route_network_ids(organization_id, gtfs_version_id) do
    Repo.all(
      from route in Route,
        where:
          route.organization_id == ^organization_id and
            route.gtfs_version_id == ^gtfs_version_id and
            not is_nil(route.network_id) and
            route.network_id != "",
        select: {route.route_id, route.network_id}
    )
    |> Map.new()
  end

  defp stop_areas(organization_id, gtfs_version_id, managed?) do
    if managed? do
      stop_zones(organization_id, gtfs_version_id)
      |> Map.new(fn {stop_id, zone_id} -> {stop_id, [zone_id]} end)
    else
      StopArea
      |> scoped(organization_id, gtfs_version_id)
      |> Enum.group_by(& &1.stop_id, & &1.area_id)
    end
  end

  defp stop_zones(organization_id, gtfs_version_id) do
    Repo.all(
      from stop in Stop,
        where:
          stop.organization_id == ^organization_id and
            stop.gtfs_version_id == ^gtfs_version_id and
            not is_nil(stop.zone_id) and
            stop.zone_id != "",
        select: {stop.stop_id, stop.zone_id}
    )
    |> Map.new()
  end

  # Reference step 4: one `rule_priority` value anywhere switches every rule of the
  # version to the priority reading. An empty value is 0, as the reference says.
  defp priority_semantics?(rules), do: Enum.any?(rules, &(not blank?(&1.rule_priority)))

  defp highest_priority([]), do: []

  defp highest_priority(matched) do
    top = matched |> Enum.map(&rule_priority/1) |> Enum.max()
    matched |> Enum.filter(&(rule_priority(&1) == top)) |> products()
  end

  defp rule_priority(%{rule_priority: nil}), do: 0
  defp rule_priority(%{rule_priority: priority}), do: priority

  # Reference steps 2 and 3.
  defp empty_semantics(rules, leg) do
    case Enum.filter(rules, &exact_match?(&1, leg)) do
      [] -> rules |> Enum.filter(&others_semantics_match?(&1, rules, leg)) |> products()
      exact -> products(exact)
    end
  end

  defp exact_match?(rule, leg) do
    Enum.all?(@rule_fields, &(not blank?(Map.get(rule, &1)))) and matches?(rule, leg)
  end

  defp others_semantics_match?(rule, rules, leg) do
    matches?(rule, leg) and
      Enum.all?(@condition_fields, fn field ->
        if blank?(Map.get(rule, field)) do
          not listed_by_a_matching_rule?(rules, rule, field, Map.get(leg, field), leg)
        else
          true
        end
      end)
  end

  defp listed_by_a_matching_rule?(rules, rule, field, value, leg) do
    not blank?(value) and
      Enum.any?(rules, fn other ->
        Map.get(other, field) == value and not same_row?(other, rule) and matches?(other, leg)
      end)
  end

  # Two literal rows built for the same product are the same rule when they agree on
  # every condition; a stored row is itself.
  defp same_row?(%{id: id}, %{id: id}) when not is_nil(id), do: true
  defp same_row?(other, rule), do: same_literal?(other, rule)

  defp same_literal?(other, rule) do
    Enum.all?(@rule_fields, fn field ->
      presence(Map.get(other, field)) == presence(Map.get(rule, field))
    end) and presence(other.fare_product_id) == presence(rule.fare_product_id)
  end

  # A rule's condition holds when the column is empty or equals the leg's value, and
  # a timeframe group it names is one the leg's own groups contain.
  defp matches?(rule, leg) do
    Enum.all?(
      @condition_fields,
      &(blank?(Map.get(rule, &1)) or Map.get(rule, &1) == Map.get(leg, &1))
    ) and
      Enum.all?(@timeframe_fields, fn field ->
        blank?(Map.get(rule, field)) or
          MapSet.member?(leg.timeframes, presence(Map.get(rule, field)))
      end)
  end

  defp products(rules) do
    rules
    |> Enum.map(& &1.fare_product_id)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp services_on(rows, date) do
    exceptions =
      rows.calendar_dates
      |> Enum.filter(&(&1.date == date))
      |> Map.new(&{&1.service_id, &1.exception_type})

    running =
      rows.calendars
      |> Enum.filter(&calendar_runs?(&1, date))
      |> Enum.map(& &1.service_id)
      |> MapSet.new()

    Enum.reduce(exceptions, running, fn
      {service_id, @added_exception}, set -> MapSet.put(set, service_id)
      {service_id, @removed_exception}, set -> MapSet.delete(set, service_id)
      _other, set -> set
    end)
  end

  defp calendar_runs?(calendar, date) do
    not is_nil(calendar.start_date) and not is_nil(calendar.end_date) and
      Date.compare(calendar.start_date, date) != :gt and
      Date.compare(calendar.end_date, date) != :lt and
      weekday_field(calendar, date) == 1
  end

  defp weekday_field(calendar, date) do
    case Enum.at(@weekday_fields, Date.day_of_week(date) - 1) do
      nil -> 0
      field -> Map.get(calendar, field) || 0
    end
  end

  defp within?(timeframe, time) do
    start_seconds = time_seconds(timeframe.start_time) || 0
    end_seconds = time_seconds(timeframe.end_time) || @end_of_day

    time >= start_seconds and time < end_seconds
  end

  # `timeframes.txt` stores local wall-clock times as text, and the reference allows
  # `H:MM:SS` through `HH:MM:SS` and hours above 24.
  defp time_seconds(value) do
    with [hours, minutes, seconds] <- value |> presence() |> String.split(":"),
         {hour_value, ""} <- Integer.parse(hours),
         {minute_value, ""} <- Integer.parse(minutes),
         {second_value, ""} <- Integer.parse(seconds) do
      hour_value * 3600 + minute_value * 60 + second_value
    else
      _other -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_other), do: false

  defp presence(value) do
    if blank?(value), do: nil, else: value
  end
end
