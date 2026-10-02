defmodule GtfsPlanner.Gtfs.Fares.ConversionV1Test do
  @moduledoc """
  Merge evidence (EV-10) for `Fares.Conversion.preview/2`, `apply/3` and
  `Fares.undo/3` on a version whose fares were imported as `fare_attributes.txt`
  and `fare_rules.txt` (R12, R13, AC-11, AC-13).

  The version enters rows through the production importer of
  `test/fixtures/gtfs/fares/north_coast_v1`, the same feed the interpreter's own
  evidence reads, and every expected value is worked out by hand from that feed
  rather than read back from the code under test (CR-2):

  - five `fare_attributes` rows and eleven `fare_rules` rows, of which
    `VALCOAST,,TOL,CST,NPT` is the one `contains_id` row;
  - only `INTERCITY,10,,,` names a route, so route 10 is priced on its own and the
    other thirteen routes share one route group named `Routes 1-7, 11-40`;
  - the nine `fare_rules` rows that name no route are written into both groups and
    the one that does is written on route 10's own, giving nineteen leg rules;
  - `transfers` is 2 with a 5400-second `transfer_duration` on the four fares
    priced in the thirteen-route group and 0 on `INTERCITY`, so that group takes a
    free same-group transfer rule and route 10's group takes none.

  The refused case edits the feed rather than adding a fixture: route 3 is given
  its own fare that is cheaper than its zone fare and whose `fare_rules` row names
  the route with no zones. The older format prices a route by the cheapest row
  that matches it, so it charges $1.25 there; the derived rows rank that row below
  the zone pair it would outrank and charge $1.50. R12 refuses any price the
  conversion changes, so nothing is written.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.FaresFixtures
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo

  setup do
    organization =
      organization_fixture(%{alias: "fares-v1-#{System.unique_integer([:positive])}"})

    actor = editor_fixture(organization)
    version = gtfs_version_fixture(organization.id, %{name: "North Coast v1"})
    import!(organization, version, "north_coast_v1")

    %{
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
  end

  describe "previewing an imported older-format feed" do
    test "reports the rows it would create and nothing it could not reproduce", context do
      assert {:ok, plan} = preview(context)

      assert plan.source == :v1
      assert plan.price_differences == 0
      assert plan.updates == %{}

      # Thirteen routes share one group and route 10 is priced on its own, so the
      # conversion creates two networks and one `route_networks` row per route.
      assert plan.creates == %{
               rider_categories: 1,
               fare_media: 1,
               networks: 2,
               route_networks: 14,
               fare_products: 5,
               fare_product_details: 5,
               fare_leg_rules: 19,
               fare_transfer_rules: 1
             }

      # The two sentences R12 records rather than refuses: the transfer clock and
      # whole-journey matching (AC-11).
      assert length(plan.known_differences) == 2
      assert Enum.any?(plan.known_differences, &(&1 =~ "route groups"))
      assert Enum.any?(plan.known_differences, &(&1 =~ "whole journey"))

      # The one `contains_id` row, kept in the exported older format (AC-11).
      assert [%{fare_id: "VALCOAST", contains_id: "NPT", reason: reason}] = plan.kept_older_only
      assert reason =~ "stays in the exported older-format files"

      # A group is named from its routes' short names, with a run of consecutive
      # numbers written as one range.
      assert ["Routes 1-7, 11-40", "Route 10"] = Enum.map(plan.networks, & &1.name)
      assert Enum.sort(Enum.map(plan.route_networks, & &1.route_id)) == Enum.sort(route_ids())

      # One adult default category and one cash medium, since every stored fare is
      # paid on board.
      assert [%{id: "adult", name: "Adult", default?: true}] = plan.riders
      assert [%{id: "cash", type: 0}] = plan.media

      # A preview writes nothing.
      refute Fares.managed?(context.organization.id, context.version.id)

      assert stored_attributes(context) == [
               "COAST",
               "INTERCITY",
               "LOCAL",
               "VALCOAST",
               "VALLEY"
             ]
    end
  end

  describe "converting an imported older-format feed" do
    test "makes the version managed and keeps every stored v1 row", context do
      {:ok, plan} = preview(context)
      attributes_before = stored_attributes(context)

      assert {:ok, %{operation_id: operation_id, inverse: inverse}} =
               Conversion.apply(context.scope, plan.fingerprint, [])

      assert Fares.managed?(context.organization.id, context.version.id)

      # Every stored `fare_attributes` and `fare_rules` row is left exactly as it
      # was (INV-3).
      assert stored_attributes(context) == attributes_before
      assert length(stored_rules(context)) == 11

      products =
        Repo.all(
          from(product in FareProduct,
            where:
              product.organization_id == ^context.organization.id and
                product.gtfs_version_id == ^context.version.id
          )
        )
        |> Enum.sort_by(& &1.fare_product_id)

      # One product per `fare_attributes` row, named by its `fare_id` and sold on
      # the cash medium.
      assert Enum.map(products, & &1.fare_product_id) == Enum.map(plan.products, & &1.product_id)

      assert Enum.map(products, & &1.fare_product_name) == [
               "COAST",
               "INTERCITY",
               "LOCAL",
               "VALCOAST",
               "VALLEY"
             ]

      assert Enum.all?(products, &(&1.fare_media_id == "cash"))
      assert Enum.all?(products, &(&1.rider_category_id == "adult"))
      assert Enum.all?(products, &(&1.currency == "USD"))

      assert Enum.find(products, &(&1.fare_product_id == "LOCAL")).amount == Decimal.new("1.50")

      # The inverse names only what this write created, so undoing it deletes only
      # that (R13).
      assert %{conversion: inverse_rows} = inverse
      assert length(inverse_rows.fare_products) == 5
      assert length(inverse_rows.fare_leg_rules) == 19
      assert is_binary(operation_id)
    end

    test "records one change-log entry naming the settings row", context do
      {:ok, plan} = preview(context)

      assert {:ok, %{operation_id: operation_id}} =
               Conversion.apply(context.scope, plan.fingerprint, [])

      [entry] =
        Repo.all(
          from(log in ChangeLog,
            where:
              log.organization_id == ^context.organization.id and
                log.gtfs_version_id == ^context.version.id and log.entity_type == "fare_version"
          )
        )

      assert entry.id == operation_id
      assert entry.action == "created"
      assert entry.changed_fields["summary"] =~ "Converted 5 older-format fares"
    end

    test "undoing returns the version to its imported export", context do
      {:ok, plan} = preview(context)

      assert {:ok, %{operation_id: operation_id, inverse: inverse}} =
               Conversion.apply(context.scope, plan.fingerprint, [])

      assert {:ok, _result} = Fares.undo(context.scope, operation_id, inverse)

      refute Fares.managed?(context.organization.id, context.version.id)

      # The exported older-format files are the recorded pre-change bytes (AC-3).
      assert export_entries(context) == golden_entries()
    end
  end

  describe "a feed the conversion would reprice" do
    setup context do
      directory = edited_feed_directory()

      File.write!(
        Path.join(directory, "fare_attributes.txt"),
        File.read!(fixture_file("fare_attributes.txt")) <>
          "LOCAL3,1.25,USD,0,2,NCT,5400\n"
      )

      File.write!(
        Path.join(directory, "fare_rules.txt"),
        File.read!(fixture_file("fare_rules.txt")) <> "LOCAL3,3,,,\n"
      )

      organization =
        organization_fixture(%{alias: "fares-v1-edited-#{System.unique_integer([:positive])}"})

      actor = editor_fixture(organization)
      version = gtfs_version_fixture(organization.id, %{name: "North Coast v1 edited"})
      import!(organization, version, directory)

      on_exit(fn -> File.rm_rf!(directory) end)

      Map.put(context, :edited, %{
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
      })
    end

    test "refuses with a price mismatch naming the route and zones, and writes nothing",
         context do
      edited = context.edited

      assert {:refused, [reason]} = Conversion.preview(edited.organization.id, edited.version.id)

      assert reason.code == :price_mismatch
      assert reason.message =~ "would change a price"
      assert [example | _rest] = reason.examples
      assert example =~ "Route 3"

      # An apply against the reviewed fingerprint refuses on the same terms, and
      # the version is still unmanaged with no derived rows.
      assert {:refused, [%{code: :price_mismatch}]} =
               Conversion.apply(edited.scope, "whatever-was-reviewed", [])

      refute Fares.managed?(edited.organization.id, edited.version.id)
      assert derived_products(edited) == 0
    end
  end

  describe "a stale review" do
    test "refuses and writes nothing", context do
      {:ok, plan} = preview(context)

      # A fingerprint from a different stored row set, as a fare edited after the
      # review would produce.
      <<first, rest::binary>> = plan.fingerprint
      stale = <<if(first == ?0, do: ?1, else: ?0)>> <> rest

      assert {:refused, [reason]} = Conversion.apply(context.scope, stale, [])

      assert reason.code == :stale
      assert reason.examples == []
      refute Fares.managed?(context.organization.id, context.version.id)
      assert derived_products(context) == 0
    end
  end

  describe "a version with nothing to convert" do
    test "reports no source and creates nothing", context do
      for row <- fare_attributes(context), do: Repo.delete!(row)
      for row <- stored_rules(context), do: Repo.delete!(row)

      assert {:ok, plan} =
               Conversion.preview(context.organization.id, context.version.id)

      assert plan.source == :none
      assert plan.creates == %{}
      assert plan.price_differences == 0
    end
  end

  defp preview(context),
    do: Conversion.preview(context.organization.id, context.version.id)

  defp route_ids do
    [
      "1",
      "2",
      "3",
      "4",
      "5",
      "6",
      "7",
      "10",
      "11",
      "12",
      "20",
      "21",
      "30",
      "40"
    ]
  end

  defp fare_attributes(context) do
    Repo.all(
      from(row in FareAttribute,
        where:
          row.organization_id == ^context.organization.id and
            row.gtfs_version_id == ^context.version.id,
        order_by: [asc: row.fare_id, asc: row.id]
      )
    )
  end

  # Five rows, ordered by `fare_id`, so `VALCOAST` and `VALLEY` each appear once
  # here even though `VALCOAST` has two `fare_rules` rows.
  defp stored_attributes(context),
    do: fare_attributes(context) |> Enum.map(& &1.fare_id)

  defp stored_rules(context) do
    Repo.all(
      from(rule in FareRule,
        where:
          rule.organization_id == ^context.organization.id and
            rule.gtfs_version_id == ^context.version.id
      )
    )
  end

  defp derived_products(context) do
    Repo.aggregate(
      from(product in FareProduct,
        where:
          product.organization_id == ^context.organization.id and
            product.gtfs_version_id == ^context.version.id
      ),
      :count
    )
  end

  defp fixture_file(name),
    do: Path.join([FaresFixtures.fixtures_path(), "north_coast_v1", name])

  # The edited feed is the imported one with two fare files rewritten, so the
  # other files stay the recorded bytes of `north_coast_v1`.
  defp edited_feed_directory do
    source = Path.join(FaresFixtures.fixtures_path(), "north_coast_v1")

    directory =
      Path.join(System.tmp_dir!(), "fares_v1_edited_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    Enum.each(File.ls!(source), &File.cp!(Path.join(source, &1), Path.join(directory, &1)))

    directory
  end

  defp export_entries(context) do
    {:ok, zip} = Export.export_to_zip(context.organization.id, context.version.id, :full)
    {:ok, entries} = :zip.unzip(zip, [:memory])

    Map.new(entries, fn {entry, content} -> {to_string(entry), to_string(content)} end)
  end

  defp golden_entries do
    directory = Path.join(FaresFixtures.fixtures_path(), "golden/north_coast_v1")

    Map.new(File.ls!(directory), &{&1, File.read!(Path.join(directory, &1))})
  end
end
