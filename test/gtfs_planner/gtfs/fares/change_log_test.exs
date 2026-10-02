defmodule GtfsPlanner.Gtfs.Fares.ChangeLogTest do
  @moduledoc """
  Merge evidence (EV-6) for the `fare_version` change-log type.

  A `Fares` writer records one entry per operation under the version's settings
  row, carrying the shared operation id, the summary the editor shows and the
  rows the operation read and wrote (R15, AC-26). These cases pin that record
  through `Gtfs.record_change_in_transaction/5` — the same entrypoint the writers
  call inside `Fares.VersionLock.transact/2` — and the path it takes from Recent
  changes to the Fares page.

  The expected values are literals: the four `changed_fields` keys R15 names, the
  literal prices a saved price edit writes, and the literal path
  `/gtfs/:version/settings/fares`.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.RecentChanges
  alias GtfsPlanner.Gtfs.RecentChanges.Describe
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Home.ChangeLinks

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    actor = user_fixture()

    setting =
      %FareVersionSetting{}
      |> struct!(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        managed_at: DateTime.utc_now()
      })
      |> FareVersionSetting.changeset(%{})
      |> Repo.insert!()

    context = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{
      organization: organization,
      gtfs_version: gtfs_version,
      setting: setting,
      context: context
    }
  end

  test "an operation records its id, summary and the rows before and after", context do
    operation_id = Ecto.UUID.generate()

    before = [
      %{"fare_product_id" => "adult_cash", "rider_category_id" => "adult", "amount" => "2.50"},
      %{"fare_product_id" => "adult_cash", "rider_category_id" => "youth", "amount" => "1.50"}
    ]

    after_rows = [
      %{"fare_product_id" => "adult_cash", "rider_category_id" => "adult", "amount" => "3.00"},
      %{"fare_product_id" => "adult_cash", "rider_category_id" => "youth", "amount" => "2.00"}
    ]

    assert {:ok, log} =
             Gtfs.record_change_in_transaction(
               context.context,
               :fare_version,
               context.setting,
               "updated",
               %{
                 operation_id: operation_id,
                 summary: "Changed 3 prices",
                 before: before,
                 after: after_rows
               }
             )

    assert log.entity_type == "fare_version"
    assert log.entity_id == context.setting.id
    assert log.entity_external_id == "fares"
    assert log.action == "updated"
    assert log.snapshot == nil
    assert log.organization_id == context.organization.id
    assert log.gtfs_version_id == context.gtfs_version.id

    assert log.changed_fields == %{
             "operation_id" => operation_id,
             "summary" => "Changed 3 prices",
             "before" => before,
             "after" => after_rows
           }

    # The stored entry is what a later reader sees, not what the writer passed.
    assert {:ok, stored} = Repo.reload(log)
    assert stored.changed_fields == log.changed_fields

    assert [row] =
             Gtfs.list_change_logs_for_entity(
               context.organization.id,
               context.gtfs_version.id,
               "fare_version",
               context.setting.id
             )

    assert row.id == stored.id
  end

  test "two entries of one operation are one Recent changes group linked to Fares", context do
    operation_id = Ecto.UUID.generate()

    for summary <- ["Changed 3 prices", "Changed 3 prices"] do
      assert {:ok, _log} =
               Gtfs.record_change_in_transaction(
                 context.context,
                 :fare_version,
                 context.setting,
                 "updated",
                 %{
                   operation_id: operation_id,
                   summary: summary,
                   before: [%{"amount" => "2.50"}],
                   after: [%{"amount" => "3.00"}]
                 }
               )
    end

    zone = Gtfs.resolve_display_zone(context.organization.id, context.gtfs_version.id)

    assert [group] =
             RecentChanges.recent(
               context.organization.id,
               context.gtfs_version.id,
               :everyone,
               zone
             )

    assert group.destination == :fares
    assert length(group.operations) == 1
    assert length(hd(group.operations)) == 2

    assert [item] =
             Describe.describe(
               context.organization.id,
               context.gtfs_version.id,
               [group],
               zone
             )

    assert item.kind == :fares
    assert item.title == "Fares"
    assert item.detail == "Changed 3 prices"

    assert ChangeLinks.path(context.gtfs_version.id, item) ==
             "/gtfs/#{context.gtfs_version.id}/settings/fares"
  end
end
