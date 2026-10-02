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

  ## The older format

  `price_journey_v1/2` is the same journey read the way an app that reads
  `fare_attributes.txt` and `fare_rules.txt` reads it (AC-6, AC-29). It reads the
  same struct — the derived rows of a managed version and the imported rows of an
  unconverted one — and never queries or writes, so the older price and the rows
  behind it come from one snapshot.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Calendar, as: ServiceCalendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Interpreter.Rows
  alias GtfsPlanner.Gtfs.Fares.PeriodCalendar
  alias GtfsPlanner.Gtfs.FareTimePeriod
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RiderCategory
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

  @zero Decimal.new(0)

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

    rows = %Rows{
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
      fare_product_details: scoped(FareProductDetail, organization_id, gtfs_version_id),
      rider_categories: scoped(RiderCategory, organization_id, gtfs_version_id),
      fare_media: scoped(FareMedia, organization_id, gtfs_version_id),
      calendars: scoped(ServiceCalendar, organization_id, gtfs_version_id),
      calendar_dates: scoped(CalendarDate, organization_id, gtfs_version_id)
    }

    periods = if managed?, do: scoped(FareTimePeriod, organization_id, gtfs_version_id), else: []

    {calendars, renames} = PeriodCalendar.build(periods, rows)

    timeframes =
      Enum.map(rows.timeframes, fn timeframe ->
        %{timeframe | service_id: Map.get(renames, timeframe.service_id, timeframe.service_id)}
      end)

    %{rows | fare_calendars: calendars, timeframes: timeframes}
  end

  @doc """
  The rules that price one leg: the ones the five steps select, in rule order.

  `leg_products/5` is this function's `fare_product_id` values, and a caller that
  also needs the rules themselves — `GtfsPlanner.Gtfs.Fares.Pricing` reads their
  `leg_group_id` — reads them here, so the two never match a leg differently.
  """
  @spec leg_rules(Rows.t(), String.t() | nil, String.t() | nil, String.t() | nil, [String.t()]) ::
          [map()]
  def leg_rules(%Rows{} = rows, network_id, from_area_id, to_area_id, timeframe_ids) do
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
    rows
    |> leg_rules(network_id, from_area_id, to_area_id, timeframe_ids)
    |> products()
  end

  @doc """
  Prices one journey the way an app reading the older format prices it (AC-6).

  The journey is the same list of legs `GtfsPlanner.Gtfs.Fares.Pricing.price_journey/2`
  takes — each with a route, its two stops and its departure and arrival in seconds
  after local midnight — and a rider and medium are ignored, because
  `fare_attributes` rows carry one price and no rider dimension. The result is

      %{total: Decimal.t() | nil, parts: [map()], split?: boolean(), unknown?: boolean()}

  A fare covers the journey when the route of every leg is named by one of that
  fare's `fare_rules` rows, that row's `origin_id` is the first leg's zone and its
  `destination_id` the last leg's zone (an empty value matching any zone), the fare's
  `transfers` allows the journey's changes and its `transfer_duration` covers the first
  departure to the last arrival. A `contains_id` row is matched only when the journey
  passes through the zone it names, and a fare with more than one `contains_id` row
  needs every one of them crossed, which is the reading the reference's "all
  `contains_id` zones must be matched" gives. Zones are the stops' `zone_id` values —
  a v1 feed addresses zones that way and never uses areas.

  The cheapest covering fare prices the whole journey, because the older model has a
  fare per journey and not a product per leg. When no one fare covers it, each leg is
  priced on its own with the cheapest covering fare and the parts are summed, which is
  what the Check a journey line reads when the v2 rules give a cheaper answer. A leg no
  fare covers is reported as `unknown` and leaves `total` as `nil`, because a journey
  nobody can price must not read as a free ride.

  A fare with no `transfers` value covers unlimited changes and a `transfer_duration` that
  cannot be measured — a leg with no departure or arrival — is not read as a limit that
  has passed. A fare with `transfers` of `-1` spans every change.
  """
  @spec price_journey_v1(Rows.t(), map()) :: %{
          total: Decimal.t() | nil,
          parts: [map()],
          split?: boolean(),
          unknown?: boolean()
        }
  def price_journey_v1(%Rows{} = rows, journey) do
    legs = journey |> Map.get(:legs, []) |> Enum.map(&v1_leg(rows, &1))

    if legs == [] do
      %{total: @zero, parts: [], split?: false, unknown?: false}
    else
      case v1_cheapest_covering(rows, legs) do
        nil -> v1_split_price(rows, legs)
        fare -> %{total: fare.price, parts: [v1_part(fare, legs)], split?: false, unknown?: false}
      end
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

  # A leg of the older-format price: the values its fare rules are matched against,
  # with an empty column read as absent the way the reference reads an empty field.
  defp v1_leg(rows, leg) do
    from_stop_id = leg |> Map.get(:from_stop_id) |> presence()
    to_stop_id = leg |> Map.get(:to_stop_id) |> presence()

    %{
      route_id: leg |> Map.get(:route_id) |> presence(),
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id,
      from_zone: v1_zone(rows, from_stop_id),
      to_zone: v1_zone(rows, to_stop_id),
      departs: leg |> Map.get(:departs) |> v1_time(),
      arrives: leg |> Map.get(:arrives) |> v1_time()
    }
  end

  defp v1_zone(_rows, nil), do: nil
  defp v1_zone(rows, stop_id), do: rows.stop_zones |> Map.get(stop_id) |> presence()

  defp v1_time(value) when is_integer(value) and value >= 0, do: value
  defp v1_time(_value), do: nil

  defp v1_cheapest_covering(rows, legs) do
    covering =
      rows.fare_attributes
      |> Enum.filter(&(not is_nil(&1.price) and v1_covers?(rows, &1, legs)))

    case covering do
      [] -> nil
      fares -> v1_cheapest(fares)
    end
  end

  # A tie keeps the fare that comes first in the rows, so the answer is the same on
  # every read of the same version.
  defp v1_cheapest([cheapest | rest]), do: Enum.reduce(rest, cheapest, &v1_cheaper/2)

  defp v1_cheaper(fare, cheapest) do
    if Decimal.compare(fare.price, cheapest.price) == :lt, do: fare, else: cheapest
  end

  defp v1_covers?(rows, fare, legs) do
    rules = Enum.filter(rows.fare_rules, &(presence(&1.fare_id) == presence(fare.fare_id)))
    plain = Enum.reject(rules, &v1_contains?/1)
    contains = Enum.filter(rules, &v1_contains?/1)

    rules_cover? =
      Enum.any?(plain, &v1_rule_covers?(&1, legs)) or
        (contains != [] and Enum.all?(contains, &v1_rule_covers?(&1, legs)))

    rules_cover? and v1_allows_changes?(fare, length(legs) - 1) and
      v1_duration_covers?(fare, legs)
  end

  defp v1_contains?(rule), do: not is_nil(presence(rule.contains_id))

  defp v1_rule_covers?(rule, legs) do
    v1_endpoint_matches?(rule.origin_id, v1_first(legs, :from_zone)) and
      v1_endpoint_matches?(rule.destination_id, v1_last(legs, :to_zone)) and
      Enum.all?(legs, &v1_route_allows?(rule, &1)) and
      (not v1_contains?(rule) or v1_zone_passed?(rule, legs))
  end

  # An empty rule value is any zone, and a journey endpoint in no zone is not an
  # endpoint the rule can name.
  defp v1_endpoint_matches?(rule_value, zone) do
    case {presence(rule_value), zone} do
      {nil, _zone} -> true
      {_rule_value, nil} -> false
      {rule_value, zone} -> rule_value == zone
    end
  end

  defp v1_route_allows?(rule, leg) do
    case presence(rule.route_id) do
      nil -> true
      route_id -> route_id == leg.route_id
    end
  end

  defp v1_zone_passed?(rule, legs) do
    contains_id = presence(rule.contains_id)

    Enum.any?(legs, &(&1.from_zone == contains_id or &1.to_zone == contains_id))
  end

  # `transfers` of `-1` spans every change, a value is the number of changes allowed,
  # and no value at all also spans every change.
  defp v1_allows_changes?(_fare, 0), do: true
  defp v1_allows_changes?(%{transfers: transfers}, _changes) when transfers in [nil, -1], do: true

  defp v1_allows_changes?(%{transfers: transfers}, changes) when is_integer(transfers),
    do: changes <= transfers

  defp v1_allows_changes?(_fare, _changes), do: false

  # Google's clock for the older format runs from the first departure to the last
  # arrival, and a limit with no endpoint to measure is not read as passed.
  defp v1_duration_covers?(%{transfer_duration: limit}, _legs) when is_nil(limit), do: true

  defp v1_duration_covers?(%{transfer_duration: limit}, legs)
       when is_integer(limit) and limit >= 0 do
    with departure when is_integer(departure) <- v1_first(legs, :departs),
         arrival when is_integer(arrival) <- v1_last(legs, :arrives) do
      arrival - departure <= limit
    else
      _missing_endpoint -> true
    end
  end

  defp v1_duration_covers?(_fare, _legs), do: true

  defp v1_first(legs, key), do: legs |> hd() |> Map.get(key)
  defp v1_last(legs, key), do: legs |> List.last() |> Map.get(key)

  defp v1_split_price(rows, legs) do
    parts = Enum.map(legs, &v1_split_part(rows, &1))
    unknown? = Enum.any?(parts, &is_nil(&1.price))

    %{
      total: if(unknown?, do: nil, else: v1_total(parts)),
      parts: parts,
      split?: length(parts) > 1,
      unknown?: unknown?
    }
  end

  defp v1_split_part(rows, leg) do
    case v1_cheapest_covering(rows, [leg]) do
      nil -> v1_part(nil, [leg])
      fare -> v1_part(fare, [leg])
    end
  end

  defp v1_total(parts) do
    Enum.reduce(parts, @zero, fn part, total -> Decimal.add(total, part.price) end)
  end

  defp v1_part(fare, legs) do
    %{
      fare_id: fare && fare.fare_id,
      price: fare && fare.price,
      currency: fare && fare.currency_type,
      payment_method: fare && fare.payment_method,
      legs: length(legs),
      from_stop_id: v1_first(legs, :from_stop_id),
      to_stop_id: v1_last(legs, :to_stop_id)
    }
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
    Enum.filter(matched, &(rule_priority(&1) == top))
  end

  defp rule_priority(%{rule_priority: nil}), do: 0
  defp rule_priority(%{rule_priority: priority}), do: priority

  # Reference steps 2 and 3.
  defp empty_semantics(rules, leg) do
    case Enum.filter(rules, &exact_match?(&1, leg)) do
      [] -> Enum.filter(rules, &others_semantics_match?(&1, rules, leg))
      exact -> exact
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
      (rows.calendars ++ rows.fare_calendars)
      |> Map.new(&{&1.service_id, &1})
      |> Map.values()
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
    case GtfsTime.parse(presence(value)) do
      {:ok, seconds} -> seconds
      {:error, :invalid_time} -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_other), do: false

  defp presence(value) do
    if blank?(value), do: nil, else: value
  end
end
