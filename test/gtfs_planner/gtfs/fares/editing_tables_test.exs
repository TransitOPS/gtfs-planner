defmodule GtfsPlanner.Gtfs.Fares.EditingTablesTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.FareSavedJourney
  alias GtfsPlanner.Gtfs.FareTimePeriod
  alias GtfsPlanner.Gtfs.FareVersionSetting

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id,
      organization: organization,
      gtfs_version: gtfs_version
    }
  end

  describe "the fare_version_settings table" do
    test "holds one row per version and refuses a second one", context do
      first = insert_settings!(context)

      duplicate =
        %FareVersionSetting{}
        |> struct!(Map.merge(scope(context), %{managed_at: DateTime.utc_now()}))
        |> FareVersionSetting.changeset(%{})

      assert duplicate.valid?
      assert {:error, changeset} = Repo.insert(duplicate)
      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)

      assert Repo.aggregate(FareVersionSetting, :count) == 1
      assert Fares.settings(context.organization_id, context.gtfs_version_id).id == first.id
    end

    test "defaults to the derived older format", context do
      setting = insert_settings!(context)

      assert setting.older_format == "derived"
      assert setting.conversion_operation_id == nil
      assert DateTime.diff(setting.managed_at, DateTime.utc_now(), :second) |> abs() <= 5
    end

    test "an unknown older format is refused by the database check", context do
      insert_settings!(context)

      assert_raise Postgrex.Error, ~r/older_format_must_be_known/, fn ->
        insert_raw(FareVersionSetting, context, %{
          managed_at: DateTime.utc_now(),
          older_format: "other"
        })
      end

      assert Repo.aggregate(FareVersionSetting, :count) == 1
    end

    test "both older formats are accepted" do
      for older_format <- ["derived", "imported"] do
        organization = organization_fixture()
        version = gtfs_version_fixture(organization.id)

        setting =
          insert_settings!(%{organization_id: organization.id, gtfs_version_id: version.id})

        {:ok, updated} =
          setting
          |> FareVersionSetting.changeset(%{older_format: older_format})
          |> Repo.update()

        assert updated.older_format == older_format
      end
    end
  end

  describe "the fare_product_details table" do
    test "stores the kind, order and accepted networks of one product", context do
      {:ok, detail} =
        %FareProductDetail{}
        |> struct!(scope(context))
        |> FareProductDetail.changeset(%{
          fare_product_id: "day_pass",
          kind: "pass",
          position: 2,
          accepted_network_ids: ["local", "all_routes"]
        })
        |> Repo.insert()

      assert detail.kind == "pass"
      assert detail.position == 2
      assert detail.accepted_network_ids == ["local", "all_routes"]
    end

    test "defaults to the first position and no accepted networks", context do
      {:ok, detail} =
        %FareProductDetail{}
        |> struct!(scope(context))
        |> FareProductDetail.changeset(%{fare_product_id: "adult_ride"})
        |> Repo.insert()

      assert detail.position == 0
      assert detail.accepted_network_ids == []
    end

    test "refuses a second row for the same product", context do
      insert_product_detail!(context, "adult_ride")

      duplicate =
        %FareProductDetail{}
        |> struct!(scope(context))
        |> FareProductDetail.changeset(%{fare_product_id: "adult_ride"})

      assert {:error, changeset} = Repo.insert(duplicate)
      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
      assert Repo.aggregate(FareProductDetail, :count) == 1
    end

    test "the same product id in another version is a different row", context do
      insert_product_detail!(context, "adult_ride")
      other_version = gtfs_version_fixture(context.organization_id)

      {:ok, detail} =
        %FareProductDetail{}
        |> struct!(%{context | gtfs_version_id: other_version.id})
        |> FareProductDetail.changeset(%{fare_product_id: "adult_ride"})
        |> Repo.insert()

      assert detail.gtfs_version_id == other_version.id
      assert Repo.aggregate(FareProductDetail, :count) == 2
    end

    test "an unknown kind is refused by the database check", context do
      assert_raise Postgrex.Error, ~r/kind_must_be_known/, fn ->
        insert_raw(FareProductDetail, context, %{
          fare_product_id: "adult_ride",
          kind: "upgrade"
        })
      end

      assert Repo.aggregate(FareProductDetail, :count) == 0
    end
  end

  describe "the fare_time_periods table" do
    test "stores the name, weekday mask and fare-only service id", context do
      {:ok, period} =
        %FareTimePeriod{}
        |> struct!(scope(context))
        |> FareTimePeriod.changeset(%{
          timeframe_group_id: "weekday_peak",
          name: "Weekday peak",
          weekdays: 31,
          service_id: "fare_weekday_peak"
        })
        |> Repo.insert()

      assert period.weekdays == 31
      assert period.until_end_of_day == false
    end

    test "a weekday mask of zero or more than 127 is refused by the database check", context do
      for weekdays <- [0, 128] do
        assert_raise Postgrex.Error, ~r/weekdays_must_cover_a_day/, fn ->
          insert_raw(FareTimePeriod, context, %{
            timeframe_group_id: "period_#{weekdays}",
            name: "Peak",
            weekdays: weekdays,
            service_id: "fare_peak_#{weekdays}"
          })
        end
      end

      assert Repo.aggregate(FareTimePeriod, :count) == 0
    end

    test "refuses a second row for the same timeframe group", context do
      {:ok, period} =
        %FareTimePeriod{}
        |> struct!(scope(context))
        |> FareTimePeriod.changeset(%{
          timeframe_group_id: "weekday_peak",
          name: "Weekday peak",
          service_id: "fare_weekday_peak"
        })
        |> Repo.insert()

      duplicate =
        %FareTimePeriod{}
        |> struct!(scope(context))
        |> FareTimePeriod.changeset(%{
          timeframe_group_id: "weekday_peak",
          name: "Evening",
          service_id: "fare_evening"
        })

      assert {:error, changeset} = Repo.insert(duplicate)
      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
      assert Repo.aggregate(FareTimePeriod, :count) == 1
      assert period.name == "Weekday peak"
    end
  end

  describe "the fare_saved_journeys table" do
    test "stores the journey the operator saved", context do
      {:ok, journey} =
        %FareSavedJourney{}
        |> struct!(scope(context))
        |> FareSavedJourney.changeset(%{
          name: "Morning commute",
          rider_category_id: "adult",
          fare_media_id: "cash",
          legs: [%{route_id: "R1", from_stop_id: "S1", to_stop_id: "S2"}],
          service_date: ~D[2026-09-30],
          expected_amount: Decimal.new("2.50")
        })
        |> Repo.insert()

      assert journey.service_date == ~D[2026-09-30]
      assert Decimal.equal?(journey.expected_amount, Decimal.new("2.50"))
      assert [%{route_id: "R1"}] = journey.legs
    end

    test "a journey without a rider, legs, date or amount is refused", context do
      changeset =
        %FareSavedJourney{}
        |> struct!(scope(context))
        |> FareSavedJourney.changeset(%{name: "  "})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :rider_category_id)
      assert Map.has_key?(errors, :legs)
      assert Map.has_key?(errors, :service_date)
      assert Map.has_key?(errors, :expected_amount)
    end
  end

  describe "Fares.managed?/2 and Fares.settings/2" do
    test "a version with a settings row is managed and reads its row back", context do
      refute Fares.managed?(context.organization_id, context.gtfs_version_id)
      assert Fares.settings(context.organization_id, context.gtfs_version_id) == nil

      setting = insert_settings!(context)

      assert Fares.managed?(context.organization_id, context.gtfs_version_id)
      assert Fares.settings(context.organization_id, context.gtfs_version_id).id == setting.id
    end

    test "another organization's version with a settings row is not this pair's", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      insert_settings!(%{
        organization_id: other_organization.id,
        gtfs_version_id: other_version.id
      })

      assert Fares.managed?(other_organization.id, other_version.id)

      refute Fares.managed?(context.organization_id, other_version.id)
      refute Fares.managed?(other_organization.id, context.gtfs_version_id)
      assert Fares.settings(context.organization_id, other_version.id) == nil
      assert Fares.settings(other_organization.id, context.gtfs_version_id) == nil
    end

    test "a second version of the same organization is independent", context do
      insert_settings!(context)
      other_version = gtfs_version_fixture(context.organization_id)

      refute Fares.managed?(context.organization_id, other_version.id)
      assert Fares.settings(context.organization_id, other_version.id) == nil
    end
  end

  describe "organization deletion" do
    test "removes the rows of all four tables", context do
      insert_settings!(context)
      insert_product_detail!(context, "day_pass")
      insert_time_period!(context, "weekday_peak")
      insert_saved_journey!(context)

      assert {:ok, _organization} =
               GtfsPlanner.Organizations.delete_organization(context.organization)

      assert Repo.aggregate(FareVersionSetting, :count) == 0
      assert Repo.aggregate(FareProductDetail, :count) == 0
      assert Repo.aggregate(FareTimePeriod, :count) == 0
      assert Repo.aggregate(FareSavedJourney, :count) == 0
    end
  end

  describe "the table definitions" do
    test "each table is indexed by organization and version", context do
      insert_settings!(context)
      insert_product_detail!(context, "day_pass")
      insert_time_period!(context, "weekday_peak")
      insert_saved_journey!(context)

      for table <- [
            "fare_version_settings",
            "fare_product_details",
            "fare_time_periods",
            "fare_saved_journeys"
          ] do
        assert index_exists?(table, "organization_id", "gtfs_version_id"),
               "#{table} has no (organization_id, gtfs_version_id) index"
      end
    end

    test "the checks carry the values the editors write" do
      assert constraint_exists?("older_format_must_be_known")
      assert constraint_exists?("kind_must_be_known")
      assert constraint_exists?("weekdays_must_cover_a_day")

      assert constraint_definition("older_format_must_be_known") =~
               "derived"

      assert constraint_definition("kind_must_be_known") =~ "transfer_fee"

      assert constraint_definition("weekdays_must_cover_a_day") =~ "127"
    end
  end

  defp scope(context) do
    %{
      organization_id: context.organization_id,
      gtfs_version_id: context.gtfs_version_id
    }
  end

  defp insert_settings!(context) do
    {:ok, setting} =
      %FareVersionSetting{}
      |> struct!(scope(context))
      |> Ecto.Changeset.change(%{managed_at: DateTime.utc_now()})
      |> Repo.insert()

    setting
  end

  defp insert_product_detail!(context, fare_product_id) do
    {:ok, detail} =
      %FareProductDetail{}
      |> struct!(scope(context))
      |> FareProductDetail.changeset(%{fare_product_id: fare_product_id, kind: "single"})
      |> Repo.insert()

    detail
  end

  defp insert_time_period!(context, timeframe_group_id) do
    {:ok, period} =
      %FareTimePeriod{}
      |> struct!(scope(context))
      |> FareTimePeriod.changeset(%{
        timeframe_group_id: timeframe_group_id,
        name: "Weekday peak",
        weekdays: 31,
        service_id: "fare_#{timeframe_group_id}"
      })
      |> Repo.insert()

    period
  end

  defp insert_saved_journey!(context) do
    {:ok, journey} =
      %FareSavedJourney{}
      |> struct!(scope(context))
      |> FareSavedJourney.changeset(%{
        name: "Morning commute",
        rider_category_id: "adult",
        legs: [%{route_id: "R1", from_stop_id: "S1", to_stop_id: "S2"}],
        service_date: ~D[2026-09-30],
        expected_amount: Decimal.new("2.50")
      })
      |> Repo.insert()

    journey
  end

  # Writes past the changesets, so a check the editor path shares is proven to be
  # a database check rather than a validation that only the changeset has.
  defp insert_raw(schema, context, attrs) do
    now = DateTime.utc_now()

    row =
      Map.merge(
        Map.merge(scope(context), %{id: Ecto.UUID.generate()}),
        Map.merge(%{inserted_at: now, updated_at: now}, Map.new(attrs))
      )

    Repo.insert_all(schema, [row], returning: true)
  end

  defp index_exists?(table, first, second) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT 1 FROM pg_indexes
        WHERE tablename = $1
          AND indexdef LIKE '%(' || $2 || ', ' || $3 || ')%'
        """,
        [table, first, second]
      )

    rows != []
  end

  defp constraint_exists?(name) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM pg_constraint WHERE conname = $1", [name])

    rows != []
  end

  defp constraint_definition(name) do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
        [name]
      )

    definition
  end
end
