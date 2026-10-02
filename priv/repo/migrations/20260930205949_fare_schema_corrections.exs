defmodule GtfsPlanner.Repo.Migrations.FareSchemaCorrections do
  use Ecto.Migration

  @fare_products_index "fare_products_org_version_product_rider_category_media_index"
  @fare_leg_rules_index "fare_leg_rules_org_version_areas_timeframes_product_id_index"

  @old_fare_products_index "fare_products_org_version_product_id_media_id_index"
  @old_fare_leg_rules_index "fare_leg_rules_org_version_network_areas_product_index"

  @fare_products_key [
    :organization_id,
    :gtfs_version_id,
    :fare_product_id,
    :rider_category_id,
    :fare_media_id
  ]

  @fare_leg_rules_key [
    :organization_id,
    :gtfs_version_id,
    :network_id,
    :from_area_id,
    :to_area_id,
    :from_timeframe_group_id,
    :to_timeframe_group_id,
    :fare_product_id
  ]

  @old_fare_products_key [:organization_id, :gtfs_version_id, :fare_product_id, :fare_media_id]

  @old_fare_leg_rules_key [
    :organization_id,
    :gtfs_version_id,
    :network_id,
    :from_area_id,
    :to_area_id,
    :fare_product_id
  ]

  # Widening a unique key and adding a nullable column touches no stored row, so
  # imported fares that break the corrected rules stay stored.
  def up do
    alter table(:rider_categories) do
      add :is_default_fare_category, :smallint
    end

    alter table(:fare_products) do
      modify :fare_product_name, :string, null: true
    end

    drop index(:fare_products, @old_fare_products_key, name: @old_fare_products_index)

    create unique_index(:fare_products, @fare_products_key, name: @fare_products_index)

    drop index(:fare_leg_rules, @old_fare_leg_rules_key, name: @old_fare_leg_rules_index)

    create unique_index(:fare_leg_rules, @fare_leg_rules_key, name: @fare_leg_rules_index)
  end

  def down do
    drop index(:fare_products, @fare_products_key, name: @fare_products_index)

    create unique_index(
             :fare_products,
             @old_fare_products_key,
             name: @old_fare_products_index
           )

    drop index(:fare_leg_rules, @fare_leg_rules_key, name: @fare_leg_rules_index)

    create unique_index(
             :fare_leg_rules,
             @old_fare_leg_rules_key,
             name: @old_fare_leg_rules_index
           )

    alter table(:rider_categories) do
      remove :is_default_fare_category
    end

    alter table(:fare_products) do
      modify :fare_product_name, :string, null: false
    end
  end
end
