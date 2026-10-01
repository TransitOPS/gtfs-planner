defmodule GtfsPlanner.Gtfs.Fares.Checks do
  @moduledoc """
  The Checks tab's rows, and the export's fare warnings (R16, AC-31).

  `run/2` reads a version's fares once and returns
  `%{repair: [...], review: [...], notes: [...], passed: [...]}`. A repair item
  is something an operator fixes before the feed is worth exporting, a review item
  is something they should look at, and a note is something the older format
  cannot say rather than something wrong with the version. Every item is
  `%{code, title, body, action, tab}`: `code` is one of AC-31's, `tab` the tab an
  `action` sends the operator to, and both are `nil` for a note that opens
  nothing. `passed` is a list of sentences, one for each thing that is right,
  which the tab folds into a disclosure.

  A managed version is read through `GtfsPlanner.Gtfs.Fares.load_workspace/2` and
  `GtfsPlanner.Gtfs.Fares.Interpreter.load_rows/2`, so a check answers from the
  same facts every fare tab draws and cannot disagree with one. A version that is
  not managed is not edited and its fares are the importer's rows rather than an
  operator's model, so it is asked only the questions an imported feed can be wrong
  about: both route network files at once, stored rows that break this package's
  own rules, its default rider type and its stops' zones.

  `GtfsPlanner.Gtfs.Export.Preflight` turns the repair and review items into
  warnings (AC-32) and leaves the notes alone, because a note is not a fault.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Fares.Pricing
  alias GtfsPlanner.Gtfs.FareSavedJourney
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @type item :: %{
          code: String.t(),
          title: String.t(),
          body: String.t() | nil,
          action: String.t() | nil,
          tab: atom() | nil
        }

  @type result :: %{
          repair: [item()],
          review: [item()],
          notes: [item()],
          passed: [String.t()]
        }

  @difference_type 2
  @every_weekday 127
  @before_midnight "23:59:00"

  # The codes an unmanaged version is asked about. Its fares are the importer's
  # rows rather than an operator's own model, so a gap or an unused fare is not a
  # fact about this editor.
  @unmanaged_codes ~w(
    network_in_both_files
    invalid_imported_fare_rows
    no_default_rider_type
    multiple_default_rider_types
    zoned_route_stop_without_zone
  )

  @doc """
  The version's check items, in repair, review and notes order.

  Every read filters by `organization_id` and `gtfs_version_id` together (INV-5).
  A pair that is not a version of the organization finds nothing to report, which
  is the empty answer rather than an error: a check has nothing to say about a
  version the caller may not see.
  """
  @spec run(Ecto.UUID.t(), Ecto.UUID.t()) :: result()
  def run(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    rows = Interpreter.load_rows(organization_id, gtfs_version_id)
    {:ok, workspace} = Fares.load_workspace(organization_id, gtfs_version_id)
    facts = facts(organization_id, gtfs_version_id, rows, workspace)

    if empty_version?(rows) do
      %{repair: [], review: [], notes: [], passed: []}
    else
      findings(facts, workspace)
    end
  end

  # A version holding no fare rows has no fares to check, which is the empty answer
  # rather than a set of findings about a pair that is not this organization's
  # version at all (INV-5).
  defp empty_version?(rows) do
    rows.fare_products == [] and rows.fare_leg_rules == [] and rows.fare_attributes == []
  end

  defp findings(facts, workspace) do
    found =
      facts
      |> run_checks(managed_checks())
      |> Enum.filter(&(&1.code in @unmanaged_codes or workspace.managed?))

    %{
      repair: for(%{bucket: :repair} = finding <- found, do: finding.item),
      review: for(%{bucket: :review} = finding <- found, do: finding.item),
      notes: for(%{bucket: :notes} = finding <- found, do: finding.item),
      passed: found |> Enum.flat_map(& &1.passed) |> Enum.uniq()
    }
  end

  # -- The checks, in the order the tab shows them --------------------------------------

  # Each entry pairs the code it reports with the check that reads the facts for it.
  # A check answers a list of items and the sentences for what it found right, so
  # one fact set feeds the rows and the disclosure together.
  defp managed_checks do
    [
      {"zone_pair_without_fare", :repair, &zone_pair_gaps/1},
      {"route_without_fare", :repair, &routes_without_fare/1},
      {"zoned_route_stop_without_zone", :repair, &zoned_route_stops/1},
      {"no_default_rider_type", :repair, &no_default_rider/1},
      {"multiple_default_rider_types", :repair, &multiple_default_riders/1},
      {"invalid_imported_fare_rows", :repair, &invalid_rows/1},
      {"network_in_both_files", :repair, &both_network_files/1},
      {"ride_with_two_fares", :review, &rides_with_two_fares/1},
      {"fare_never_charged", :review, &never_charged_fares/1},
      {"missing_rider_media_price", :review, &rider_media_holes/1},
      {"missing_agency_id", :review, &missing_agencies/1},
      {"saved_journey_price_changed", :review, &changed_journey_prices/1},
      {"time_period_overlap", :review, &overlapping_periods/1},
      {"time_period_ends_2359", :review, &periods_ending_2359/1},
      {"fare_calendar_collision", :review, &calendar_collisions/1},
      {"difference_transfer_undercharges", :review, &undercharging_differences/1},
      {"older_format_leaves_out", :notes, &older_format_leaves_out/1}
    ]
  end

  defp run_checks(facts, checks) do
    Enum.flat_map(checks, fn {code, bucket, check} ->
      {items, passed} = check.(facts)

      for item <- items do
        %{code: code, bucket: bucket, item: item, passed: []}
      end ++ [%{code: code, bucket: nil, item: nil, passed: passed}]
    end)
  end

  # -- Repair --------------------------------------------------------------------------

  # A zone pair with no fare is a hole in what a rider can be told. The matrix is
  # the read model's own: a cell holding no products is a gap by construction, so
  # this reports what the Where tab draws as "No fare".
  defp zone_pair_gaps(facts) do
    gaps =
      for matrix <- facts.matrices,
          gap = Enum.filter(matrix.cells, fn {_pair, cell} -> cell.gap? end),
          gap != [],
          do: {matrix, gap}

    items =
      for {matrix, gap} <- gaps do
        count = length(gap)

        item(
          "zone_pair_without_fare",
          "#{plural(count, "ride", "rides")} between zones on #{group_name(facts, matrix.network_id)} " <>
            "#{if count == 1, do: "has", else: "have"} no fare",
          pairs_text(gap, matrix) <>
            ". Trip planners show no price for these rides.",
          "Set the missing fare",
          :where
        )
      end

    passed =
      for matrix <- facts.matrices,
          group <- [group_name(facts, matrix.network_id)],
          group != nil do
        "Every ride between zones on #{group} has a fare"
      end

    {items, passed}
  end

  defp pairs_text(gap, matrix) do
    zone_names = Map.new(matrix.zones, &{&1.area_id, &1.name})

    gap
    |> Enum.sort_by(fn {{from_id, to_id}, _cell} -> {from_id, to_id} end)
    |> Enum.map_join(" · ", fn {{from_id, to_id}, _cell} ->
      "#{Map.get(zone_names, from_id, from_id)} → #{Map.get(zone_names, to_id, to_id)}"
    end)
  end

  # A route in no route group is priced only by a rule naming "any route group"
  # (R3). While such a rule exists every route is priced by it, so the routes in
  # no group are not missing a fare and are left out.
  defp routes_without_fare(facts) do
    # A rule that names no group and no zone either prices nothing a rider rides:
    # it is the blanket row a pass accepting every group carries, not an "any route
    # group" fare, so it does not cover a route in no group.
    any_group_rule? =
      Enum.any?(facts.rules, fn rule ->
        is_nil(rule.network_id) and
          not is_nil(rule.from_area_id) and not is_nil(rule.to_area_id)
      end)

    loose =
      if any_group_rule? do
        []
      else
        grouped = facts.groups |> Enum.flat_map(& &1.route_ids) |> MapSet.new()
        facts.routes |> Enum.filter(&(not MapSet.member?(grouped, &1.route_id))) |> Enum.sort()
      end

    passed =
      if loose == [] and not any_group_rule? do
        ["Every route is in a route group"]
      else
        []
      end

    count = length(loose)

    items =
      if count == 0 do
        []
      else
        [
          item(
            "route_without_fare",
            "#{plural(count, "route is", "routes are")} in no route group",
            "#{Enum.map_join(loose, ", ", &"Route #{&1.route_id} #{&1.name}")} " <>
              "#{if count == 1, do: "has", else: "have"} no fare. " <>
              "Add #{if count == 1, do: "it", else: "them"} to a route group.",
            "Edit route groups",
            :where
          )
        ]
      end

    {items, passed}
  end

  # A stop on a route that prices by zone, with no zone of its own, is a ride the
  # matrix cannot place. Stops no zone-priced route serves are not this check's:
  # an agency's Intercity route may serve a stop outside every fare zone.
  defp zoned_route_stops(facts) do
    bare =
      facts.route_stops
      |> Enum.filter(fn {route_id, _stops} ->
        MapSet.member?(facts.zone_priced_routes, route_id)
      end)
      |> Enum.flat_map(fn {_route_id, stops} -> stops end)
      |> Enum.filter(&match?({_stop_id, nil}, &1))
      |> Enum.map(fn {stop_id, _zone_id} -> Map.get(facts.stop_names, stop_id, stop_id) end)
      |> Enum.uniq()
      |> Enum.sort()

    case bare do
      [] ->
        {[],
         [
           "Every stop on a zone-priced route is in a zone (#{facts.unzoned_stop_count} " <>
             "stops outside every fare zone need none: only Intercity serves them)"
         ]}

      bare ->
        {[
           item(
             "zoned_route_stop_without_zone",
             "Stops on zone-priced routes have no zone",
             Enum.join(bare, ", "),
             "Assign zones",
             :zones
           )
         ], []}
    end
  end

  # R8: the newer format needs one default rider type, which is the one trip
  # planners show first.
  defp default_riders(facts), do: Enum.filter(facts.riders, & &1.default?)

  # R8 speaks of a version that has rider categories, so a version with none has
  # nothing to choose and nothing to report.
  defp no_default_rider(facts) do
    if facts.riders != [] and default_riders(facts) == [] do
      {[
         item(
           "no_default_rider_type",
           "No rider type is shown first",
           "The newer format needs one default rider type, usually Adult. " <>
             "Trip planners show its prices first.",
           "Choose a default",
           :prices
         )
       ], []}
    else
      {[], []}
    end
  end

  defp multiple_default_riders(facts) do
    case default_riders(facts) do
      [default] ->
        {[], ["#{default.name} is the rider type trip planners show first"]}

      [_, _ | _rest] = several ->
        {[
           item(
             "multiple_default_rider_types",
             "More than one rider type is shown first",
             "More than one rider type is marked default: " <>
               Enum.map_join(several, ", ", & &1.name) <> ".",
             "Choose a default",
             :prices
           )
         ], []}

      _none ->
        {[], []}
    end
  end

  # Stored rows that break the rules this package's own writers hold, which is what
  # an import can leave behind: a negative price on a fare that is not a transfer
  # fee, and a negative older-format price (R9).
  defp invalid_rows(facts) do
    products =
      facts.products
      |> Enum.reject(
        &(MapSet.member?(facts.transfer_fee_products, &1.fare_product_id) or not negative?(&1))
      )
      |> Enum.map(&"#{fare_name(&1)} (#{&1.fare_product_id})")

    attributes =
      facts.attributes
      |> Enum.filter(&(&1.price && Decimal.lt?(&1.price, 0)))
      |> Enum.map(&"Fare attribute #{&1.fare_id}")

    offenders = products ++ attributes

    case offenders do
      [] ->
        {[], []}

      offenders ->
        {[
           item(
             "invalid_imported_fare_rows",
             "#{plural(length(offenders), "stored fare row breaks", "stored fare rows break")} " <>
               "this editor's rules",
             "A price may not be negative: #{Enum.join(offenders, ", ")}. Re-enter each price " <>
               "in the grid, or fix the imported feed.",
             "Show the price grid",
             :prices
           )
         ], []}
    end
  end

  defp negative?(%FareProduct{amount: amount}), do: amount && Decimal.lt?(amount, 0)

  # `route_networks.txt` and the `routes.network_id` column are two carriers of the
  # same fact, and a feed carrying both states the route-to-group map twice.
  defp both_network_files(facts) do
    if map_size(facts.route_networks) > 0 and map_size(facts.route_network_ids) > 0 do
      {[
         item(
           "network_in_both_files",
           "Routes name a network in two files",
           "#{map_size(facts.route_network_ids)} routes carry a `network_id` and " <>
             "#{map_size(facts.route_networks)} more are named by `route_networks.txt`. " <>
             "Trip planners disagree about which route runs in which group.",
           "Review the route groups",
           :where
         )
       ], []}
    else
      {[], []}
    end
  end

  # -- Review --------------------------------------------------------------------------

  # Two fares for one ride is a cell a rider is charged two prices for. The cell is
  # compared by fare rather than by product, because one fare is one product per
  # rider type and payment method, so the four rules an imported cell carries are
  # one fare rather than four.
  defp rides_with_two_fares(facts) do
    overlaps =
      for matrix <- facts.matrices,
          {{from_id, to_id}, cell} <- Enum.sort_by(matrix.cells, &elem(&1, 0)),
          names = fare_names_of(cell.products, facts),
          length(names) > 1 do
        zone_names = Map.new(matrix.zones, &{&1.area_id, &1.name})

        %{
          network_id: matrix.network_id,
          from: Map.get(zone_names, from_id, from_id),
          to: Map.get(zone_names, to_id, to_id),
          fares: names
        }
      end

    case overlaps do
      [] ->
        {[], ["No ride has two single-ride fares"]}

      overlaps ->
        shown =
          overlaps
          |> Enum.take(2)
          |> Enum.map_join(" · ", fn overlap ->
            "#{group_name(facts, overlap.network_id)}, #{overlap.from} → #{overlap.to}: " <>
              Enum.join(overlap.fares, " and ")
          end)

        {[
           item(
             "ride_with_two_fares",
             "#{plural(length(overlaps), "ride has", "rides have")} two fares",
             shown <> ". Trip planners show both prices.",
             "Choose one fare",
             :where
           )
         ], []}
    end
  end

  # A fare no rule charges is a fare a rider never sees. A single ride is named by a
  # rule; a pass is sold by the groups that accept it, so a pass no group accepts
  # is never sold. A transfer fee is never named by a rule and is not flagged.
  defp never_charged_fares(facts) do
    unused =
      facts.fares
      |> Enum.filter(fn fare ->
        case fare.kind do
          "pass" -> fare.accepted_network_ids == []
          "single" -> not charged?(fare, facts)
          _other -> false
        end
      end)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    case unused do
      [] ->
        {[], ["Every fare is charged somewhere"]}

      unused ->
        count = length(unused)

        {[
           item(
             "fare_never_charged",
             "#{plural(count, "fare is", "fares are")} never charged",
             "#{names_text(unused)}: no fare rule uses " <>
               "#{if count == 1, do: "it", else: "them"}, so riders never see " <>
               "#{if count == 1, do: "it", else: "them"}.",
             "Show where fares apply",
             :where
           )
         ], []}
    end
  end

  # A fare sold at two payment methods with a rider type priced at one of them and
  # not the other is a hole in the grid: the rider can buy the fare one way and not
  # the other, and the fare's own row shows the gap.
  defp rider_media_holes(facts) do
    holes =
      facts.fares
      |> Enum.filter(&(&1.kind == "single"))
      |> Enum.flat_map(fn fare -> rider_media_holes(fare.name, facts) end)
      |> Enum.sort()

    case holes do
      [] ->
        {[], []}

      holes ->
        {[
           item(
             "missing_rider_media_price",
             "#{plural(length(holes), "fare is", "fares are")} missing a rider price for one " <>
               "of its payment methods",
             names_text(holes) <>
               ". A rider type priced on one method is not priced on the other, so a rider " <>
               "cannot buy that fare one way.",
             "Show the price grid",
             :prices
           )
         ], []}
    end
  end

  defp rider_media_holes(fare_name, facts) do
    priced = rider_media(fare_name, facts)
    media = priced |> Map.keys() |> Enum.sort()

    if length(media) < 2 do
      []
    else
      for rider_id <- riders_of(priced),
          sold_on = Enum.filter(media, &Map.has_key?(Map.get(priced, &1, %{}), rider_id)),
          sold_on != [] and sold_on != media,
          do:
            "#{fare_name}: #{rider_name(facts, rider_id)} has no price on " <>
              Enum.map_join(media -- sold_on, " or ", &medium_name(facts, &1))
    end
  end

  defp riders_of(priced) do
    priced
    |> Enum.flat_map(fn {_medium, amounts} -> Map.keys(amounts) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The fare's own rows as `{medium, %{rider => amount}}`, read the way the read
  # model reads them: a row naming no payment method is the fare's base one.
  defp rider_media(fare_name, facts) do
    facts.fare_products
    |> Enum.filter(&(fare_name(&1) == fare_name))
    |> Enum.group_by(& &1.fare_media_id)
    |> Map.new(fn {medium, products} ->
      {medium, Map.new(products, &{&1.rider_category_id, &1.amount})}
    end)
  end

  # R11: with one agency every fare names it, so there is nothing to report. With
  # several, a fare whose charging groups' routes run on more than one agency has
  # no agency to write, and its `fare_attributes` row leaves the field blank.
  defp missing_agencies(facts) do
    if length(facts.agencies) <= 1 do
      {[], []}
    else
      unshared =
        facts.fares
        |> Enum.filter(fn fare ->
          fare.kind == "single" and charging_groups(fare, facts) != [] and
            fare
            |> charging_groups(facts)
            |> routes_of(facts)
            |> Enum.map(&Map.get(facts.route_agencies, &1))
            |> Enum.uniq()
            |> length() != 1
        end)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      case unshared do
        [] ->
          {[], []}

        unshared ->
          {[
             item(
               "missing_agency_id",
               "#{plural(length(unshared), "fare has", "fares have")} no agency to name",
               names_text(unshared) <>
                 ". Their route groups run on more than one agency, so the older-format row " <>
                 "leaves `agency_id` blank.",
               "Review the route groups",
               :where
             )
           ], []}
      end
    end
  end

  # A saved journey is the operator's own statement of what a ride should cost.
  # Pricing it again is the only way to see a fare edit's effect on journeys
  # somebody already saved (AC-33).
  defp changed_journey_prices(facts) do
    changed =
      for journey <- facts.journeys,
          changed = changed_price(journey, facts),
          changed,
          do: changed

    case {changed, facts.journeys} do
      {[], []} ->
        {[], []}

      {[], journeys} ->
        {[], ["All #{length(journeys)} saved journeys cost what you expect"]}

      {changed, _journeys} ->
        {[
           item(
             "saved_journey_price_changed",
             "#{plural(length(changed), "saved journey costs", "saved journeys cost")} " <>
               "a different amount",
             Enum.map_join(changed, " · ", & &1.text) <>
               ". Update the fares, or accept the new price if the change is intended.",
             "Review saved journeys",
             :checks
           )
         ], []}
    end
  end

  defp changed_price(journey, facts) do
    total = Pricing.price_journey(facts.rows, journey).total

    if is_nil(total) or not Decimal.equal?(total, journey.expected_amount) do
      now =
        if is_nil(total) do
          "no price"
        else
          Money.format(total, facts.currency)
        end

      %{
        name: journey.name,
        text:
          "#{journey.name}: expected #{Money.format(journey.expected_amount, facts.currency)}, " <>
            "now #{now}"
      }
    end
  end

  # Two periods that cover the same minute of the same weekday: a rider on that
  # ride is priced by whichever rule the interpreter picks, and which one is not
  # something the feed says.
  defp overlapping_periods(facts) do
    overlaps =
      facts.periods
      |> Enum.sort_by(& &1.timeframe_group_id)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [first, second] ->
        if periods_overlap?(first, second), do: [first.name, second.name], else: []
      end)

    case overlaps do
      [] ->
        {[], []}

      overlaps ->
        {[
           item(
             "time_period_overlap",
             "Time periods overlap",
             names_text(overlaps) <>
               ". A rider on one of those rides is charged whichever rule the app picks first.",
             "Review the time periods",
             :where
           )
         ], []}
    end
  end

  defp periods_overlap?(first, second) do
    Bitwise.band(weekday_mask(first), weekday_mask(second)) != 0 and
      Enum.any?(first.ranges, fn range ->
        Enum.any?(second.ranges, fn other ->
          overlapping_range?(range, other)
        end)
      end)
  end

  # `24:00:00` is the end of the service day rather than midnight of the next one,
  # and is 86,400 seconds within the day (R10).
  defp overlapping_range?(range, other) do
    with start when is_integer(start) <- seconds(range.start_time),
         finish when is_integer(finish) <- seconds(range.end_time),
         other_start when is_integer(other_start) <- seconds(other.start_time),
         other_finish when is_integer(other_finish) <- seconds(other.end_time) do
      start < other_finish and other_start < finish
    else
      _unknown -> false
    end
  end

  # A blank mask is every day, which is what `FareTimePeriod.changeset/2` says a
  # period with no weekday chosen carries (R10).
  defp weekday_mask(%{weekdays: nil}), do: @every_weekday
  defp weekday_mask(%{weekdays: mask}), do: mask

  # A period ending at 23:59:00 leaves the last minute of the service day without a
  # fare, because GTFS reads `24:00:00` as the end of the day rather than midnight
  # of the next one (R10).
  defp periods_ending_2359(facts) do
    ending =
      for period <- facts.periods,
          period.until_end_of_day == false,
          last_end(period.ranges) == @before_midnight,
          do: period.name

    case ending do
      [] ->
        {[], []}

      ending ->
        {[
           item(
             "time_period_ends_2359",
             "A time period ends before the service day does",
             names_text(ending) <>
               ". Rides between 23:59:00 and midnight have no fare unless the period runs to " <>
               "the end of the service day.",
             "Review the time periods",
             :where
           )
         ], []}
    end
  end

  defp last_end(ranges) do
    ranges
    |> Enum.map(& &1.end_time)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  # R10 writes a period's service id under `fare_` and the export re-checks it, so
  # a calendar row already holding the id is a state an operator can reach by
  # editing the feed after import.
  defp calendar_collisions(facts) do
    taken = facts.calendar_service_ids

    colliding =
      for period <- facts.periods,
          MapSet.member?(taken, period.service_id),
          do: period.name

    case colliding do
      [] ->
        {[], []}

      colliding ->
        {[
           item(
             "fare_calendar_collision",
             "A time period shares a service id with the calendar",
             names_text(colliding) <>
               ". The export renames the calendar row, so the feed's own services and its fare " <>
               "services do not line up.",
             "Review the time periods",
             :where
           )
         ], []}
    end
  end

  # R6: a difference transfer naming a destination the group does not charge exactly
  # one fare for, or charging less than the origin did, would total less than the
  # ride it follows. A price edit can make a stored rule stale, so this reads the
  # rows rather than what the writer last checked, and only for a rule whose two
  # leg groups are groups this version's own rules still price.
  defp undercharging_differences(facts) do
    live = facts.leg_groups

    undercharging =
      for rule <- facts.transfer_rules,
          rule.fare_transfer_type == @difference_type,
          MapSet.member?(live, rule.from_leg_group_id),
          MapSet.member?(live, rule.to_leg_group_id),
          reason = undercharge_reason(rule, facts),
          reason != "",
          do: %{from: rule.from_leg_group_id, to: rule.to_leg_group_id, reason: reason}

    case undercharging do
      [] ->
        {[], []}

      undercharging ->
        {[
           item(
             "difference_transfer_undercharges",
             "A pays-the-difference transfer charges less than the ride before it",
             Enum.map_join(undercharging, " · ", &"#{&1.from} → #{&1.to}: #{&1.reason}") <>
               ". A rider pays less than the origin fare.",
             "Review the transfers",
             :transfers
           )
         ], []}
    end
  end

  defp undercharge_reason(rule, facts) do
    destination = group_fares(rule.to_leg_group_id, facts)
    origin = Enum.flat_map(group_fares(rule.from_leg_group_id, facts), & &1.rows)

    case destination do
      [fare] ->
        origin
        |> undercharged_pairs(fare.rows, facts)
        |> Enum.join("; ")

      other ->
        "the destination charges #{plural(length(other), "fare", "fares")}, not one"
    end
  end

  defp undercharged_pairs(origin_rows, destination_rows, facts) do
    Enum.uniq(pairs_of(destination_rows) ++ pairs_of(origin_rows))
    |> Enum.sort()
    |> Enum.filter(fn {rider, medium} ->
      case {amount_for(destination_rows, rider, medium),
            highest_amount(origin_rows, rider, medium)} do
        {nil, _other} -> false
        {_amount, nil} -> false
        {amount, highest} -> Decimal.lt?(amount, highest)
      end
    end)
    |> Enum.map(fn {rider, medium} ->
      "#{rider_name(facts, rider)} at #{medium_name(facts, medium)} is cheaper than the origin fare"
    end)
  end

  # -- Note -----------------------------------------------------------------------------

  # R11: what the older format cannot say. Google Maps reads only the older format,
  # so it shows adult single-ride prices and no passes, and every sentence here is
  # one a rider on that app would notice.
  defp older_format_leaves_out(facts) do
    sentences = leave_out_sentences(facts)

    case sentences do
      [] ->
        {[], []}

      sentences ->
        {[
           item(
             "older_format_leaves_out",
             "Some fares appear only in the newer format",
             Enum.join(sentences, " "),
             nil,
             nil
           )
         ], []}
    end
  end

  defp leave_out_sentences(facts) do
    others =
      facts.riders
      |> Enum.reject(& &1.default?)
      |> Enum.filter(&sold_to?(&1.rider_category_id, facts))
      |> Enum.map(&short_name(&1.name))

    sentences =
      if others == [] do
        []
      else
        [
          "Prices for #{names_text(others)} riders. Apps that read only the older format show " <>
            "adult prices."
        ]
      end

    passes = Enum.filter(facts.fares, &sold_without_a_ride?(&1, facts))

    sentences =
      if passes == [] do
        sentences
      else
        sentences ++ ["Passes: #{names_text(Enum.map(passes, & &1.name))}."]
      end

    sentences =
      if Enum.any?(facts.fares, &(&1.media_prices != %{})) do
        sentences ++
          ["Lower prices in the NCT Ride app. The older format shows the cash price."]
      else
        sentences
      end

    cross =
      facts.transfers
      |> Enum.filter(fn entry ->
        entry.from_leg_group_id != entry.to_leg_group_id and is_map(entry.policy) and
          Map.get(entry.policy, :pay) != :full
      end)
      |> Enum.map(
        &"#{group_name(facts, &1.from_leg_group_id)} to #{group_name(facts, &1.to_leg_group_id)}"
      )

    sentences =
      if cross == [] do
        sentences
      else
        sentences ++
          [
            "Transfers between route groups (#{names_text(Enum.uniq(cross))}). The older format " <>
              "shows a new full fare for these journeys."
          ]
      end

    if facts.periods == [] do
      sentences
    else
      sentences ++ ["Prices that change by time of day."]
    end
  end

  defp sold_to?(rider_id, facts) do
    Enum.any?(facts.fares, fn fare ->
      not is_nil(Map.get(fare.prices, rider_id))
    end)
  end

  # A fare the older format has no row for. A pass is one: R11 writes no
  # `fare_attributes` row for a fare that is sold rather than charged for a ride.
  # So is a fare sold blanket-wide over a leg group that prices its own rides by
  # zone, because the zone rules outrank it and no ride is ever charged it (R3) —
  # the sample's Day pass and 31-day pass are read this way. A blanket fare over a
  # group that prices nothing by zone is that group's own price and keeps its row.
  defp sold_without_a_ride?(fare, facts) do
    fare.kind == "pass" or outranked_blanket_fare?(fare, facts)
  end

  defp outranked_blanket_fare?(fare, facts) do
    rules = rules_of(fare, facts)
    accepted = rules |> Enum.map(&leg_group_id/1) |> MapSet.new()

    rules != [] and
      Enum.all?(rules, fn rule ->
        is_nil(rule.from_area_id) and is_nil(rule.to_area_id)
      end) and
      Enum.any?(facts.rules, fn rule ->
        not is_nil(rule.from_area_id) and not is_nil(rule.to_area_id) and
          (MapSet.member?(accepted, leg_group_id(rule)) or
             MapSet.member?(accepted, "all_routes"))
      end)
  end

  # R3's leg group: the rule's own network, or the one string standing for a rule
  # that names none.
  defp leg_group_id(rule), do: rule.network_id || "all_routes"

  defp short_name(name) do
    name |> String.split("(") |> List.first() |> String.trim() |> String.downcase()
  end

  # -- The facts ------------------------------------------------------------------------

  # Everything the checks read, in one scoped snapshot, so a check never queries a
  # fare table itself and two checks cannot disagree about the version.
  defp facts(organization_id, gtfs_version_id, rows, workspace) do
    %{
      rows: rows,
      currency: workspace.currency,
      matrices: workspace.matrices,
      groups: workspace.groups,
      fares: workspace.fares,
      riders: workspace.riders,
      media: workspace.media,
      transfers: workspace.transfers,
      periods: workspace.time_periods,
      rules: rows.fare_leg_rules,
      rules_by_fare: rules_by_fare(rows),
      products: rows.fare_products,
      attributes: rows.fare_attributes,
      fare_products: rows.fare_products,
      transfer_rules: rows.fare_transfer_rules,
      transfer_fee_products: transfer_fee_products(rows),
      pass_products: pass_products(workspace),
      routes: route_rows(organization_id, gtfs_version_id),
      agencies: agency_ids(organization_id, gtfs_version_id),
      route_agencies: route_agencies(organization_id, gtfs_version_id),
      route_networks: rows.route_networks,
      route_network_ids: rows.route_network_ids,
      network_routes: network_routes(rows),
      route_stops: route_stops(organization_id, gtfs_version_id, rows),
      stop_names: stop_names(organization_id, gtfs_version_id),
      zone_priced_routes:
        workspace.groups
        |> Enum.filter(& &1.zone_priced?)
        |> Enum.flat_map(& &1.route_ids)
        |> MapSet.new(),
      unzoned_stop_count:
        stop_count(organization_id, gtfs_version_id) - map_size(rows.stop_areas),
      leg_groups: leg_groups(rows),
      leg_group_networks: leg_group_networks(rows),
      journeys: journey_rows(organization_id, gtfs_version_id),
      calendar_service_ids: calendar_service_ids(rows)
    }
  end

  # Every leg rule naming one of a fare's own products, which is what "a fare no
  # rule charges" and "a fare's charging groups" are both read from.
  defp rules_by_fare(rows) do
    names = Map.new(rows.fare_products, &{&1.fare_product_id, fare_name(&1)})

    rows.fare_leg_rules
    |> Enum.group_by(&Map.get(names, &1.fare_product_id, &1.fare_product_id))
  end

  defp rules_of(fare, facts) do
    Map.get(facts.rules_by_fare, fare.name, [])
  end

  defp pass_products(workspace) do
    workspace.fares
    |> Enum.filter(&(&1.kind == "pass"))
    |> Enum.flat_map(& &1.product_ids)
    |> MapSet.new()
  end

  defp transfer_fee_products(rows) do
    rows.fare_product_details
    |> Enum.filter(&(is_binary(&1.kind) and &1.kind == "transfer_fee"))
    |> Enum.map(& &1.fare_product_id)
    |> MapSet.new()
  end

  defp route_rows(organization_id, gtfs_version_id) do
    Route
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
    |> Enum.map(fn route ->
      %{route_id: route.route_id, name: route_label(route)}
    end)
    |> Enum.sort_by(& &1.route_id)
  end

  defp route_label(route) do
    Enum.find([route.route_short_name, route.route_long_name], &present?/1) || route.route_id
  end

  defp agency_ids(organization_id, gtfs_version_id) do
    Agency
    |> scoped(organization_id, gtfs_version_id)
    |> select([agency], agency.agency_id)
    |> Repo.all()
    |> Enum.reject(&(&1 == nil or &1 == ""))
    |> Enum.sort()
  end

  defp route_agencies(organization_id, gtfs_version_id) do
    Route
    |> scoped(organization_id, gtfs_version_id)
    |> select([route], {route.route_id, route.agency_id})
    |> Repo.all()
    |> Map.new()
  end

  defp network_routes(rows) do
    rows.route_networks
    |> Map.merge(rows.route_network_ids)
    |> Enum.group_by(fn {_route_id, network_id} -> network_id end, fn {route_id, _} ->
      route_id
    end)
    |> Map.new(fn {network_id, route_ids} ->
      {network_id, route_ids |> Enum.uniq() |> Enum.sort()}
    end)
  end

  # Every stop each route serves, with that stop's fare zone, which is what places
  # a ride in a matrix cell.
  defp route_stops(organization_id, gtfs_version_id, rows) do
    Trip
    |> join(:inner, [trip], stop_time in StopTime,
      on:
        stop_time.trip_id == trip.trip_id and stop_time.organization_id == ^organization_id and
          stop_time.gtfs_version_id == ^gtfs_version_id
    )
    |> join(:inner, [trip, stop_time], stop in Stop,
      on:
        stop.stop_id == stop_time.stop_id and stop.organization_id == ^organization_id and
          stop.gtfs_version_id == ^gtfs_version_id
    )
    |> where(
      [trip],
      trip.organization_id == ^organization_id and trip.gtfs_version_id == ^gtfs_version_id
    )
    |> select([trip, _stop_time, stop], {trip.route_id, stop.stop_id})
    |> Repo.all()
    |> Enum.map(fn {route_id, stop_id} -> {route_id, stop_id, zone_of(rows, stop_id)} end)
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), fn {_route_id, stop_id, zone_id} -> {stop_id, zone_id} end)
  end

  defp stop_names(organization_id, gtfs_version_id) do
    Stop
    |> scoped(organization_id, gtfs_version_id)
    |> select([stop], {stop.stop_id, stop.stop_name})
    |> Repo.all()
    |> Map.new()
  end

  defp stop_count(organization_id, gtfs_version_id) do
    Stop
    |> scoped(organization_id, gtfs_version_id)
    |> select([stop], count())
    |> Repo.one()
  end

  # A stop's fare zone as the interpreter reads it: a managed version's zones are
  # `stops.zone_id`, an unmanaged one's are its `stop_areas` rows.
  defp zone_of(rows, stop_id) do
    case Map.get(rows.stop_areas, stop_id, []) do
      [] -> nil
      [zone_id | _rest] -> presence(zone_id)
    end
  end

  # The network each leg group stands for, read from the rules that carry it, which
  # is how a stored rule naming a pre-conversion leg group is resolved (R12).
  defp leg_group_networks(rows) do
    for rule <- rows.fare_leg_rules,
        not is_nil(rule.leg_group_id),
        not is_nil(rule.network_id),
        into: %{},
        do: {rule.leg_group_id, rule.network_id}
  end

  defp leg_groups(rows) do
    rows.fare_leg_rules
    |> Enum.map(& &1.leg_group_id)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> MapSet.new()
  end

  defp journey_rows(organization_id, gtfs_version_id) do
    FareSavedJourney
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
    |> Enum.sort_by(& &1.name)
  end

  defp calendar_service_ids(rows) do
    rows.calendars
    |> Enum.map(& &1.service_id)
    |> Kernel.++(Enum.map(rows.calendar_dates, & &1.service_id))
    |> MapSet.new()
  end

  # -- Shared answers --------------------------------------------------------------------

  # The fares one leg group charges, by fare name, which is the identity this
  # package's own writers use (R6).
  defp group_fares(leg_group_id, facts) do
    products = Map.new(facts.products, &{&1.fare_product_id, &1})

    facts.rules
    |> Enum.filter(fn rule ->
      rule.leg_group_id == leg_group_id and
        not is_nil(rule.leg_group_id) and
        not MapSet.member?(facts.pass_products, rule.fare_product_id)
    end)
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.flat_map(&List.wrap(Map.get(products, &1)))
    |> Enum.group_by(&fare_name/1)
    |> Enum.map(fn {name, rows} -> %{name: name, rows: rows} end)
    |> Enum.sort_by(& &1.name)
  end

  defp charged?(fare, facts), do: rules_of(fare, facts) != []

  defp charging_groups(fare, facts) do
    rules_of(fare, facts)
    |> Enum.map(& &1.network_id)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp routes_of(groups, facts) do
    groups |> Enum.flat_map(&Map.get(facts.network_routes, &1, [])) |> Enum.uniq()
  end

  defp fare_names_of(product_ids, facts) do
    names = Map.new(facts.products, &{&1.fare_product_id, fare_name(&1)})
    product_ids |> Enum.map(&Map.get(names, &1, &1)) |> Enum.uniq() |> Enum.sort()
  end

  defp fare_name(%FareProduct{fare_product_name: name}) when is_binary(name) and name != "",
    do: name

  defp fare_name(%FareProduct{fare_product_id: id}), do: id

  defp pairs_of(rows) do
    for %FareProduct{rider_category_id: rider, fare_media_id: medium} <- rows,
        not is_nil(rider) and not is_nil(medium),
        do: {rider, medium}
  end

  defp amount_for(rows, rider, medium) do
    Enum.find_value([{rider, medium}, {rider, nil}, {nil, medium}, {nil, nil}], fn pair ->
      Enum.find_value(rows, &row_amount(&1, pair))
    end)
  end

  defp row_amount(row, {row_rider, row_medium}) do
    if row.rider_category_id == row_rider and row.fare_media_id == row_medium, do: row.amount
  end

  defp highest_amount(rows, rider, medium) do
    rows
    |> Enum.map(&amount_for([&1], rider, medium))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> Decimal.new(0) end)
  end

  defp rider_name(facts, rider_id) do
    case Enum.find(facts.riders, &(&1.rider_category_id == rider_id)) do
      nil -> rider_id
      rider -> rider.name
    end
  end

  defp medium_name(facts, medium_id) do
    case Enum.find(facts.media, &(&1.fare_media_id == medium_id)) do
      nil -> medium_id
      medium -> medium.name
    end
  end

  # A leg group's name. A rule names its own network as its leg group (R3), so a
  # group a stored transfer rule still names by an older id resolves through the
  # rules that carry it, and a network the version holds names itself.
  defp group_name(facts, leg_group_id) do
    cond do
      is_nil(leg_group_id) -> "Any route group"
      group = Enum.find(facts.groups, &(&1.network_id == leg_group_id)) -> group.name
      network = Map.get(facts.leg_group_networks, leg_group_id) -> group_name(facts, network)
      true -> leg_group_id
    end
  end

  defp scoped(queryable, organization_id, gtfs_version_id) do
    where(
      queryable,
      [row],
      row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id
    )
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp presence(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp presence(value), do: value

  defp item(code, title, body, action, tab) do
    %{code: code, title: title, body: body, action: action, tab: tab}
  end

  # The prototype's own `plural`: the count and the word that agrees with it, so
  # every title reads as "1 ride has" or "2 rides have".
  defp plural(count, singular, plural) do
    "#{count} #{if count == 1, do: singular, else: plural}"
  end

  defp names_text([]), do: ""
  defp names_text([one]), do: one
  defp names_text([first, second]), do: "#{first} and #{second}"

  defp names_text([first | rest]), do: "#{first}, #{Enum.join(rest, ", ")}"

  defp seconds("24:00:00"), do: 86_400

  defp seconds(time) when is_binary(time) do
    case String.split(time, ":") do
      [hours, minutes, secs] ->
        String.to_integer(hours) * 3_600 + String.to_integer(minutes) * 60 +
          String.to_integer(secs)

      _other ->
        nil
    end
  end

  defp seconds(_other), do: nil
end
