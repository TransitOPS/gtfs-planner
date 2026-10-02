defmodule GtfsPlanner.Gtfs.Fares.ConversionV2Test do
  @moduledoc """
  Merge evidence (EV-14) for `Fares.Conversion.preview/2`, `apply/3` and
  `Fares.undo/3` on a version whose fares were imported as `fare_leg_rules.txt`
  (R12, R13, AC-12, AC-13).

  The version enters rows through the production importer of
  `test/fixtures/gtfs/fares/north_coast_v2`, and every expected value is worked
  out by hand from that feed rather than read back from the code under test
  (CR-2):

  - `areas.txt` names three areas - NPT, TOL and CST - and `stops.txt` gives
    every stop an empty `zone_id`, so a conversion that adopts the areas is the
    only thing that can put a zone on a stop;
  - `networks.txt` names N_LOCAL and N_INTERCITY, and the two leg groups of
    `fare_leg_rules.txt` name one network each, so the imported route groups map
    one-to-one onto networks and the conversion is not refused for them;
  - no two products of the feed share a rule's conditions with a rule of a
    different fare. `local_ride_adult_cash` and `local_ride_reduced_cash` are two
    prices for the fare "Local ride", not a pass, so R12's classification makes
    every one of the thirty products single-ride and `Normalize` keeps every
    imported rule, which is why the equivalence check finds no difference;
  - a zone pair of the fixture is priced by rules naming that pair, so a leg with
    a network but no areas prices nothing under R3's priority and prices the
    network's products under the imported empty semantics. The rule matters and
    is why the three public excerpts below refuse or convert as they do.

  The `:to_timeframe` case edits the feed rather than adding a fixture: one leg
  rule is given a `to_timeframe_group_id` and the feed a `timeframes.txt` naming
  it, which R3's priority has no place for.
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.FaresFixtures
  alias GtfsPlanner.Gtfs.Area
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  setup do
    context_for("north_coast_v2")
  end

  describe "previewing an imported Fares v2 feed" do
    test "reports the rows it would create and no difference", context do
      assert {:ok, plan} = preview(context)

      assert plan.source == :v2
      assert plan.product_differences == 0
      assert plan.price_differences == 0
      assert plan.updates == %{fare_leg_rules: 46, stops: 12}

      # One detail row per `fare_product_id` in the feed, three areas adopted as
      # zones, and nothing to copy: the version already has `route_networks.txt`
      # and declared both networks.
      assert plan.creates == %{
               fare_product_details: 30,
               networks: 0,
               route_networks: 0,
               fare_zones: 3
             }

      assert plan.passes == []
    end

    test "classifies every product single-ride", context do
      assert {:ok, plan} = preview(context)

      imported =
        products(context) |> Enum.map(&{&1.fare_product_id, "single"}) |> Enum.sort()

      assert Enum.sort(Enum.map(plan.details, &{&1.fare_product_id, &1.kind})) == imported
    end

    test "a version that already stores fares is not this conversion's case", context do
      {:ok, plan} = preview(context)
      assert {:ok, _result} = Conversion.apply(context.scope, plan.fingerprint, [])

      assert {:refused, [reason]} =
               Conversion.preview(context.organization.id, context.version.id)

      assert reason.code == :unsupported_source
    end
  end

  describe "converting" do
    setup context do
      {:ok, plan} = preview(context)

      case Conversion.apply(context.scope, plan.fingerprint, []) do
        {:ok, result} -> Map.put(context, :applied, Map.put(result, :plan, plan))
        {:refused, reasons} -> flunk("the North Coast v2 feed was refused: #{inspect(reasons)}")
      end
    end

    test "answers a managed version with a settings row naming this operation", context do
      assert Fares.managed?(context.organization.id, context.version.id)

      assert [%FareVersionSetting{older_format: "derived", conversion_operation_id: operation_id}] =
               settings(context)

      assert operation_id == context.applied.operation_id
    end

    test "adopts the imported areas as fare zones named after them", context do
      assert zone_names(context) == %{
               "CST" => "Coast zone",
               "NPT" => "Newport local",
               "TOL" => "Toledo and valley"
             }
    end

    test "gives every adopted stop the zone of the area it is in", context do
      assert stop_zones(context) == %{
               "CST" => ~w(DEPOE LCTC SEAL WALDPORT YACHATS),
               "NPT" => ~w(AGATE HOSP NTC NYE SBPR),
               "TOL" => ~w(SILETZ TOLEDO)
             }
    end

    test "gives every leg rule the R3 priority and leg group, and no to_timeframe",
         context do
      for rule <- rules(context) do
        assert rule.rule_priority == r3_priority(rule)
        assert rule.leg_group_id == leg_group(rule)
        assert is_nil(rule.to_timeframe_group_id)
      end

      assert priority_of(context, "local_ride_adult_cash", "N_LOCAL", "NPT", "NPT", nil) == 7
      assert priority_of(context, "valley_ride_adult_cash", "N_LOCAL", "NPT", "TOL", nil) == 7
      assert priority_of(context, "intercity_ride_adult_cash", "N_INTERCITY", nil, nil, nil) == 4
      assert priority_of(context, "month_pass_adult_app", nil, nil, nil, nil) == 0
    end

    test "keeps one row per imported rule and one detail row per product", context do
      assert length(rules(context)) == 46
      assert length(details(context)) == 30
      assert length(networks(context)) == 2
      assert length(route_networks(context)) == 14
      assert length(areas(context)) == 3
    end

    test "rewrites legacy transfer endpoints with the normalized route groups", context do
      # R12's North Coast feed names transfer endpoints LG_LOCAL/LG_INTERCITY,
      # while conversion normalizes those groups to their network ids. The
      # transfer policy must follow that identity change or the scoped editor
      # cannot find the imported rule to display or edit it.
      assert transfer_pairs(context) == [
               {"N_INTERCITY", "N_LOCAL"},
               {"N_LOCAL", "N_INTERCITY"},
               {"N_LOCAL", "N_LOCAL"}
             ]

      assert Enum.sort(context.applied.inverse.conversion.transfer_groups) ==
               [{"LG_INTERCITY", "N_INTERCITY"}, {"LG_LOCAL", "N_LOCAL"}]
    end

    test "records one change-log entry naming the settings row", context do
      [entry] =
        Repo.all(
          from(change in ChangeLog,
            where:
              change.organization_id == ^context.organization.id and
                change.gtfs_version_id == ^context.version.id and
                change.entity_type == "fare_version"
          )
        )

      assert entry.id == context.applied.operation_id
      assert entry.action == "created"
      assert entry.changed_fields["summary"] =~ "Converted 46 imported Fares v2 leg rules"
    end

    test "names in its inverse only the rows the write created", context do
      inverse = context.applied.inverse.conversion

      assert inverse.source == :v2
      assert length(inverse.fare_product_details) == 30
      assert inverse.networks == []
      assert inverse.route_networks == []
      assert Enum.sort(inverse.fare_zones) == ~w(CST NPT TOL)
      assert length(inverse.stop_zones) == 12
      assert length(inverse.leg_rules) == 46
      assert inverse.leg_rule_rows == []
      assert inverse.leg_rule_ids == []
    end
  end

  describe "undoing" do
    setup context do
      {:ok, plan} = preview(context)

      {:ok, result} = Conversion.apply(context.scope, plan.fingerprint, [])

      case Fares.undo(context.scope, result.operation_id, result.inverse) do
        {:ok, _undone} -> context
        {:error, reason} -> flunk("undoing the conversion failed: #{inspect(reason)}")
      end
    end

    test "leaves the version unmanaged with the rows the import wrote", context do
      refute Fares.managed?(context.organization.id, context.version.id)
      assert settings(context) == []
      assert zone_names(context) == %{}
      assert stop_zones(context) == %{}
      assert details(context) == []

      for rule <- rules(context) do
        assert is_nil(rule.rule_priority)
        assert is_nil(rule.to_timeframe_group_id)
        assert rule.leg_group_id in ["LG_LOCAL", "LG_INTERCITY", nil]
      end

      assert transfer_pairs(context) == [
               {"LG_INTERCITY", "LG_LOCAL"},
               {"LG_LOCAL", "LG_INTERCITY"},
               {"LG_LOCAL", "LG_LOCAL"}
             ]
    end

    test "exports the same bytes the import read", context do
      entries = export_entries(context)
      golden = golden_entries()

      assert Map.drop(entries, ["rider_categories.txt"]) ==
               Map.drop(golden, ["rider_categories.txt"])

      # `rider_categories.txt` is the one entry the comparison allows to differ.
      # The export writes the `is_default_fare_category` column the recorded
      # bytes predate, and the `min_age` and `max_age` the recorded bytes carry
      # predate the schema corrections; neither is written by the conversion. The
      # riders themselves are still the same rows in the same order.
      assert riders(entries["rider_categories.txt"]) == riders(golden["rider_categories.txt"])
    end
  end

  describe "feeds this conversion cannot represent" do
    test "a stop in two areas is refused and nothing is written" do
      refused = context_for("refused/multi_area_stop")

      assert {:refused, [reason]} = preview(refused)

      assert reason.code == :multi_area_stop
      assert reason.message =~ "two areas"
      assert [example | _rest] = reason.examples
      assert example =~ "NTC"

      assert {:refused, [%{code: :multi_area_stop}]} =
               Conversion.apply(refused.scope, "whatever-was-reviewed", [])

      assert nothing_written?(refused)
    end

    test "a stop whose zone is not the area it is in is refused" do
      refused = context_for("refused/area_zone_mismatch")

      assert {:refused, [reason]} = preview(refused)

      assert reason.code == :area_zone_mismatch
      assert reason.message =~ "only area"
      assert [example | _rest] = reason.examples
      assert example =~ "SEAL"

      assert nothing_written?(refused)
    end

    test "route groups that do not map one-to-one onto networks are refused" do
      refused = context_for("refused/leg_groups")

      assert {:refused, [reason]} = preview(refused)

      assert reason.code == :leg_groups
      assert reason.message =~ "one-to-one"
      assert [example | _rest] = reason.examples
      assert example =~ "N_LOCAL"

      assert nothing_written?(refused)
    end
  end

  describe "a leg rule pricing an arrival timeframe" do
    setup context do
      directory = timed_feed_directory()

      File.write!(
        Path.join(directory, "timeframes.txt"),
        "timeframe_group_id,service_id,start_time,end_time\nweekday_peak,weekday,07:00:00,09:00:00\n"
      )

      File.write!(
        Path.join(directory, "fare_leg_rules.txt"),
        File.read!(fixture_file("fare_leg_rules.txt")) <>
          "LG_LOCAL,N_LOCAL,NPT,CST,,weekday_peak,coast_ride_adult_cash\n"
      )

      on_exit(fn -> File.rm_rf!(directory) end)

      Map.put(context, :timed, context_for(directory, "North Coast v2 timed"))
    end

    test "is refused and nothing is written", context do
      timed = context.timed

      assert {:refused, [reason]} = preview(timed)

      assert reason.code == :to_timeframe
      assert reason.message =~ "arrival timeframe"
      assert [example | _rest] = reason.examples
      assert example =~ "weekday_peak"

      assert {:refused, [%{code: :to_timeframe}]} =
               Conversion.apply(timed.scope, "whatever-was-reviewed", [])

      assert nothing_written?(timed)
    end
  end

  describe "the public excerpts" do
    test "C-TRAN's free system names four networks in one route group" do
      excerpt = context_for("public/ctran", "C-TRAN")

      case preview(excerpt) do
        {:refused, [reason]} ->
          assert reason.code == :leg_groups
          assert Enum.any?(reason.examples, &(&1 =~ "names 3 networks"))
          assert nothing_written?(excerpt)

        {:ok, plan} ->
          assert plan.product_differences == 0
      end
    end

    test "TriMet prices a leg with no areas under the imported rules alone" do
      excerpt = context_for("public/trimet", "TriMet")

      case preview(excerpt) do
        {:refused, [reason]} ->
          assert reason.code == :product_mismatch
          assert reason.message =~ "the fare a rider is offered"
          assert [example | _rest] = reason.examples
          assert example =~ "becomes no fare"
          assert nothing_written?(excerpt)

        {:ok, plan} ->
          assert plan.product_differences == 0
      end
    end

    test "Santa Cruz Metro pins every rule to a zone pair" do
      excerpt = context_for("public/santa_cruz_metro", "Santa Cruz Metro")

      case preview(excerpt) do
        {:refused, [reason]} ->
          assert reason.code == :product_mismatch
          assert Enum.any?(reason.examples, &(&1 =~ "local"))
          assert nothing_written?(excerpt)

        {:ok, plan} ->
          assert plan.product_differences == 0
      end
    end
  end

  # -- The helpers -------------------------------------------------------------

  defp context_for(fixture, name \\ "North Coast v2") do
    organization =
      organization_fixture(%{alias: "fares-v2-#{System.unique_integer([:positive])}"})

    actor = editor_fixture(organization)
    version = gtfs_version_fixture(organization.id, %{name: name})
    import!(organization, version, fixture)

    context = %{
      organization: organization,
      version: version,
      scope: %{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        audit: %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          station_stop_id: nil,
          actor_id: actor.id,
          actor_email: actor.email
        }
      }
    }

    Map.put(context, :imported_counts, written_counts(context))
  end

  defp preview(context),
    do: Conversion.preview(context.organization.id, context.version.id)

  # R3's priority written out again here rather than read from `Normalize`.
  defp r3_priority(rule) do
    4 * present(rule.network_id) + 2 * present(rule.from_area_id) +
      1 * present(rule.to_area_id) + 1 * present(rule.from_timeframe_group_id)
  end

  defp present(nil), do: 0
  defp present(value) when is_binary(value) and value != "", do: 1
  defp present(_value), do: 0

  defp leg_group(rule), do: rule.network_id || "all_routes"

  defp priority_of(context, fare_product_id, network_id, from_area_id, to_area_id, timeframe) do
    rule =
      rules(context)
      |> Enum.find(
        &(&1.fare_product_id == fare_product_id and &1.network_id == network_id and
            &1.from_area_id == from_area_id and &1.to_area_id == to_area_id and
            &1.from_timeframe_group_id == timeframe)
      )

    rule.rule_priority
  end

  defp products(context) do
    context
    |> rows_in(FareProduct)
    |> Enum.uniq_by(& &1.fare_product_id)
    |> Enum.sort_by(&(&1.fare_product_id || ""))
  end

  defp rules(context), do: rows_in(context, FareLegRule)

  defp transfer_pairs(context),
    do:
      rows_in(context, FareTransferRule)
      |> Enum.map(&{&1.from_leg_group_id, &1.to_leg_group_id})
      |> Enum.sort()

  defp details(context), do: rows_in(context, FareProductDetail)
  defp networks(context), do: rows_in(context, Network)
  defp route_networks(context), do: rows_in(context, RouteNetwork)
  defp areas(context), do: rows_in(context, Area)
  defp settings(context), do: rows_in(context, FareVersionSetting)

  defp rows_in(context, schema) do
    Repo.all(
      from(row in schema,
        where:
          row.organization_id == ^context.organization.id and
            row.gtfs_version_id == ^context.version.id
      )
    )
  end

  defp zone_names(context) do
    context
    |> rows_in(FareZone)
    |> Map.new(&{&1.zone_id, &1.name})
  end

  defp stops_in_a_zone(context),
    do: context |> rows_in(Stop) |> Enum.count(&(not is_nil(&1.zone_id)))

  defp stop_zones(context) do
    context
    |> rows_in(Stop)
    |> Enum.reject(&is_nil(&1.zone_id))
    |> Enum.group_by(& &1.zone_id, & &1.stop_id)
    |> Map.new(fn {zone_id, stop_ids} -> {zone_id, Enum.sort(stop_ids)} end)
  end

  # Every table the conversion writes, so a refusal is shown to have written
  # nothing anywhere rather than nothing in one place. The counts are taken from
  # the import itself, so the answer does not rest on what any fixture holds.
  defp nothing_written?(context) do
    written_counts(context) == context.imported_counts
  end

  defp written_counts(context) do
    %{
      areas: length(rows_in(context, Area)),
      fare_leg_rules: length(rules(context)),
      fare_product_details: length(details(context)),
      fare_version_settings: length(settings(context)),
      fare_zones: length(rows_in(context, FareZone)),
      networks: length(networks(context)),
      route_networks: length(route_networks(context)),
      stops_in_a_zone: stops_in_a_zone(context)
    }
  end

  defp fixture_file(name),
    do: Path.join([FaresFixtures.fixtures_path(), "north_coast_v2", name])

  # The timed feed is the imported one with two files written, so the other files
  # stay the recorded bytes of `north_coast_v2`.
  defp timed_feed_directory do
    source = Path.join(FaresFixtures.fixtures_path(), "north_coast_v2")

    directory =
      Path.join(System.tmp_dir!(), "fares_v2_timed_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    Enum.each(File.ls!(source), &File.cp!(Path.join(source, &1), Path.join(directory, &1)))

    directory
  end

  defp export_entries(context) do
    {:ok, zip} = Export.export_to_zip(context.organization.id, context.version.id, :full)
    {:ok, entries} = :zip.unzip(zip, [:memory])

    Map.new(entries, fn {entry, content} -> {to_string(entry), to_string(content)} end)
  end

  # The riders of a `rider_categories.txt`, by the two columns both the export and
  # the recorded bytes carry, in the order they are written.
  defp riders(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, ",") do
        [id, name | _rest] -> {id, name}
        other -> Enum.join(other, ",")
      end
    end)
  end

  defp golden_entries do
    directory = Path.join(FaresFixtures.fixtures_path(), "golden/north_coast_v2")

    Map.new(File.ls!(directory), &{&1, File.read!(Path.join(directory, &1))})
  end
end
