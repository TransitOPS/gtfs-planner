defmodule GtfsPlanner.Repo.Migrations.CreateBookingRules do
  use Ecto.Migration

  def up do
    create table(:booking_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :booking_rule_id, :string, null: false
      add :booking_type, :integer, null: false
      add :prior_notice_duration_min, :integer
      add :prior_notice_duration_max, :integer
      add :prior_notice_last_day, :integer
      add :prior_notice_last_time, :string
      add :prior_notice_start_day, :integer
      add :prior_notice_start_time, :string
      add :prior_notice_service_id, :string
      add :message, :text
      add :pickup_message, :text
      add :drop_off_message, :text
      add :phone_number, :string
      add :info_url, :string
      add :booking_url, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:booking_rules, [:organization_id, :gtfs_version_id, :booking_rule_id],
             name: :booking_rules_organization_id_gtfs_version_id_booking_rule_id_index
           )

    create index(:booking_rules, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:booking_rules)
  end
end