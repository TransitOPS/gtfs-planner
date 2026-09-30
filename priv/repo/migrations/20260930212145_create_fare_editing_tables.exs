defmodule GtfsPlanner.Repo.Migrations.CreateFareEditingTables do
  use Ecto.Migration

  @settings_index "fare_version_settings_organization_id_gtfs_version_id_index"
  @product_detail_index "fare_product_details_org_version_product_id_index"
  @time_period_index "fare_time_periods_org_version_timeframe_group_index"

  # Storage the GTFS files have no place for: the managed marker of a version,
  # the operator facts kept beside a stored v2 product, a fare-only time period
  # and a saved journey. Only new tables are created, so no stored row changes.
  def change do
    create table(:fare_version_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id, :binary_id, null: false
      add :managed_at, :utc_datetime_usec, null: false
      add :older_format, :string, null: false, default: "derived"
      add :conversion_operation_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:fare_version_settings, :older_format_must_be_known,
             check: "older_format IN ('derived','imported')"
           )

    create unique_index(:fare_version_settings, [:organization_id, :gtfs_version_id],
             name: @settings_index
           )

    create table(:fare_product_details, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id, :binary_id, null: false
      add :fare_product_id, :string, null: false
      add :kind, :string
      add :position, :integer, null: false, default: 0
      add :accepted_network_ids, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:fare_product_details, :kind_must_be_known,
             check: "kind IS NULL OR kind IN ('single','pass','transfer_fee')"
           )

    create unique_index(
             :fare_product_details,
             [:organization_id, :gtfs_version_id, :fare_product_id],
             name: @product_detail_index
           )

    create table(:fare_time_periods, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id, :binary_id, null: false
      add :timeframe_group_id, :string
      add :name, :string, null: false
      add :weekdays, :smallint
      add :until_end_of_day, :boolean, null: false, default: false
      add :service_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:fare_time_periods, :weekdays_must_cover_a_day,
             check: "weekdays IS NULL OR (weekdays >= 1 AND weekdays <= 127)"
           )

    create unique_index(
             :fare_time_periods,
             [:organization_id, :gtfs_version_id, :timeframe_group_id],
             name: @time_period_index
           )

    create table(:fare_saved_journeys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id, :binary_id, null: false
      add :name, :string, null: false
      add :rider_category_id, :string, null: false
      add :fare_media_id, :string
      add :legs, :map, null: false
      add :service_date, :date, null: false
      add :expected_amount, :decimal, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:fare_saved_journeys, [:organization_id, :gtfs_version_id])
  end
end
