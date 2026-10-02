defmodule GtfsPlanner.Gtfs.Fares.SchemaCorrectionsTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.RiderCategory

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/*_fare_schema_corrections.exs",
                    __DIR__
                  )
                  |> Path.expand(__DIR__)
                  |> Path.wildcard()
                  |> List.first()

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{organization_id: organization.id, gtfs_version_id: gtfs_version.id}
  end

  describe "the migration" do
    test "changes definitions only and rewrites no stored row" do
      source = File.read!(@migration_path)

      refute source =~ ~r/\bexecute\b/
      refute source =~ ~r/\bupdate\b/
      refute source =~ ~r/\bdelete\b/

      assert source =~ "alter table(:rider_categories)"
      assert source =~ "add :is_default_fare_category"
      assert source =~ "modify :fare_product_name"
      assert source =~ "drop index(:fare_products"
      assert source =~ "drop index(:fare_leg_rules"
      assert source =~ "create unique_index(:fare_products"
      assert source =~ "create unique_index(:fare_leg_rules"
    end

    test "widened keys hold the added key columns" do
      assert product_key_columns() == [
               "organization_id",
               "gtfs_version_id",
               "fare_product_id",
               "rider_category_id",
               "fare_media_id"
             ]

      assert leg_rule_key_columns() == [
               "organization_id",
               "gtfs_version_id",
               "network_id",
               "from_area_id",
               "to_area_id",
               "from_timeframe_group_id",
               "to_timeframe_group_id",
               "fare_product_id"
             ]
    end
  end

  describe "FareAttribute.changeset/2" do
    test "a price of zero is valid", context do
      changeset = fare_attribute_changeset(fare_scope(context), price: Decimal.new("0"))

      assert changeset.valid?
      assert {:ok, fare} = Repo.insert(changeset)
      assert Decimal.equal?(fare.price, 0)
    end

    test "a negative price is still refused", context do
      refute fare_attribute_changeset(fare_scope(context), price: Decimal.new("-0.01")).valid?
    end
  end

  describe "FareProduct.changeset/2" do
    test "a negative amount and a missing name are valid", context do
      changeset =
        fare_product_changeset(fare_scope(context), %{
          fare_product_id: "p_adult_cash",
          fare_media_id: "cash",
          amount: Decimal.new("-0.50"),
          currency: "USD"
        })

      assert changeset.valid?
      assert {:ok, product} = Repo.insert(changeset)
      assert product.fare_product_name == nil
      assert Decimal.equal?(product.amount, Decimal.new("-0.50"))
    end

    test "two products differing only by rider category both insert", context do
      adult = insert_product!(fare_scope(context), "p_cash", "adult")
      reduced = insert_product!(fare_scope(context), "p_cash", "reduced")

      assert adult.id != reduced.id
      assert Repo.aggregate(FareProduct, :count) == 2
    end

    test "two products sharing the widened key still conflict", context do
      insert_product!(fare_scope(context), "p_cash", "adult")

      duplicate =
        fare_product_changeset(fare_scope(context), %{
          fare_product_id: "p_cash",
          fare_media_id: "cash",
          rider_category_id: "adult",
          amount: "0"
        })

      assert {:error, changeset} = Repo.insert(duplicate)
      # Ecto reports a composite unique violation on the key's first field.
      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "FareLegRule.changeset/2" do
    test "two rules differing only by from_timeframe_group_id both insert", context do
      morning = insert_leg_rule!(fare_scope(context), "T_AM")
      evening = insert_leg_rule!(fare_scope(context), "T_PM")

      assert morning.id != evening.id
      assert Repo.aggregate(FareLegRule, :count) == 2
    end

    test "two rules sharing the widened key still conflict", context do
      insert_leg_rule!(fare_scope(context), "T_AM")

      duplicate =
        fare_leg_rule_changeset(fare_scope(context), %{
          leg_group_id: "LG_LOCAL",
          network_id: "local",
          from_area_id: "NPT",
          to_area_id: "TOL",
          from_timeframe_group_id: "T_AM",
          to_timeframe_group_id: "T_AM",
          fare_product_id: "p_cash"
        })

      assert {:error, changeset} = Repo.insert(duplicate)
      # Ecto reports a composite unique violation on the key's first field.
      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "RiderCategory.changeset/2" do
    test "is_default_fare_category outside 0 or 1 is invalid", context do
      changeset = rider_category_changeset(fare_scope(context), is_default_fare_category: 2)

      refute changeset.valid?
      assert %{is_default_fare_category: ["is invalid"]} = errors_on(changeset)
    end

    test "0 and 1 are valid and stored", context do
      for value <- [0, 1] do
        changeset = rider_category_changeset(fare_scope(context), is_default_fare_category: value)
        assert changeset.valid?
        assert {:ok, category} = Repo.insert(changeset)
        assert category.is_default_fare_category == value
      end
    end

    test "an absent default is stored as null", context do
      changeset = rider_category_changeset(fare_scope(context), %{})
      assert changeset.valid?
      assert {:ok, category} = Repo.insert(changeset)
      assert category.is_default_fare_category == nil
    end
  end

  defp fare_scope(context), do: Map.take(context, [:organization_id, :gtfs_version_id])

  defp fare_attribute_changeset(context, overrides) do
    FareAttribute.changeset(
      %FareAttribute{},
      Map.merge(attribute_attrs(context), Map.new(overrides))
    )
  end

  defp attribute_attrs(context) do
    %{
      fare_id: "f_#{System.unique_integer()}",
      price: Decimal.new("1.50"),
      currency_type: "USD",
      payment_method: 0,
      organization_id: context.organization_id,
      gtfs_version_id: context.gtfs_version_id
    }
  end

  defp fare_product_changeset(context, overrides) do
    FareProduct.changeset(
      %FareProduct{},
      Map.merge(
        %{
          fare_product_id: "p_#{System.unique_integer()}",
          amount: Decimal.new("1.50"),
          currency: "USD",
          organization_id: context.organization_id,
          gtfs_version_id: context.gtfs_version_id
        },
        Map.new(overrides)
      )
    )
  end

  defp insert_product!(context, fare_product_id, rider_category_id) do
    {:ok, product} =
      Repo.insert(
        fare_product_changeset(context, %{
          fare_product_id: fare_product_id,
          fare_media_id: "cash",
          rider_category_id: rider_category_id,
          amount: Decimal.new("1.50")
        })
      )

    product
  end

  defp fare_leg_rule_changeset(context, attrs) do
    FareLegRule.changeset(
      %FareLegRule{},
      Map.merge(
        %{
          organization_id: context.organization_id,
          gtfs_version_id: context.gtfs_version_id
        },
        attrs
      )
    )
  end

  defp insert_leg_rule!(context, from_timeframe_group_id) do
    {:ok, rule} =
      Repo.insert(
        fare_leg_rule_changeset(context, %{
          leg_group_id: "LG_LOCAL",
          network_id: "local",
          from_area_id: "NPT",
          to_area_id: "TOL",
          from_timeframe_group_id: from_timeframe_group_id,
          to_timeframe_group_id: from_timeframe_group_id,
          fare_product_id: "p_cash"
        })
      )

    rule
  end

  defp rider_category_changeset(context, overrides) do
    RiderCategory.changeset(
      %RiderCategory{},
      Map.merge(
        %{
          rider_category_id: "rc_#{System.unique_integer()}",
          rider_category_name: "Adult",
          organization_id: context.organization_id,
          gtfs_version_id: context.gtfs_version_id
        },
        Map.new(overrides)
      )
    )
  end

  defp product_key_columns do
    key_columns("fare_products_org_version_product_rider_category_media_index")
  end

  defp leg_rule_key_columns do
    key_columns("fare_leg_rules_org_version_areas_timeframes_product_id_index")
  end

  defp key_columns(index) do
    %{rows: [[definition]]} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [index])

    assert definition =~ "CREATE UNIQUE INDEX #{index}"

    [columns] = Regex.run(~r/\(([^)]+)\)/, definition, capture: :all_but_first)
    String.split(columns, ", ")
  end
end
