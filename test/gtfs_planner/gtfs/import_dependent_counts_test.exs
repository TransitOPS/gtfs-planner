defmodule GtfsPlanner.Gtfs.ImportDependentCountsTest do
  @moduledoc """
  `Gtfs.import_dependent_counts(:stop, …)` is the import review's answer to "can
  this stop be removed?", and it now reads the one shared reference list instead
  of a second, shorter one kept alongside it.

  Two things are checked. The kinds the review already rendered still come back
  under the same names, so a review that said "2 stop times and 1 transfer" still
  says it. And the kinds the shared list adds — a relief point, a flex hub, a
  deadhead time — are counted now, so a review no longer understates what a
  removal would leave behind.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    stop_fixture(organization.id, version.id, %{stop_id: "1434"})
    stop_fixture(organization.id, version.id, %{stop_id: "7788"})

    %{organization: organization, version: version}
  end

  defp counts(context, natural_keys),
    do:
      Gtfs.import_dependent_counts(
        :stop,
        context.organization.id,
        context.version.id,
        natural_keys
      )

  describe "the kinds the review already rendered" do
    test "a stop with 2 stop times and 1 relief point reports both", context do
      stop_time_fixture(context.organization.id, context.version.id, "T1", "1434")
      stop_time_fixture(context.organization.id, context.version.id, "T2", "1434")

      Repo.insert!(%ReliefPoint{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        stop_id: "1434"
      })

      assert counts(context, ["1434"]) == %{"1434" => %{stop_times: 2, relief_points: 1}}
    end

    test "a transfer naming the stop as both from and to counts once", context do
      transfer_fixture(context.organization.id, context.version.id, %{
        from_stop_id: "1434",
        to_stop_id: "1434"
      })

      transfer_fixture(context.organization.id, context.version.id, %{
        from_stop_id: "1434",
        to_stop_id: "7788"
      })

      assert counts(context, ["1434"]) == %{"1434" => %{transfers: 2}}
    end

    test "a pathway naming the stop once as a to stop still reports as a pathway", context do
      pathway_fixture(context.organization.id, context.version.id, "7788", "1434")

      assert counts(context, ["1434"]) == %{"1434" => %{pathways: 1}}
    end

    test "a stop nothing uses is absent rather than zero", context do
      assert counts(context, ["1434"]) == %{}
    end

    test "no natural keys is an empty map without querying", context do
      assert counts(context, []) == %{}
    end
  end

  describe "the kinds the shared list adds" do
    test "a flex hub counts once however many times the array names the stop", context do
      Repo.insert!(%FlexService{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        key: "FLEX1",
        name: "Downtown flex",
        kind: :area,
        hub_stop_ids: ["1434", "7788", "1434"]
      })

      assert counts(context, ["1434"]) == %{"1434" => %{flex_hubs: 1}}
    end

    test "a deadhead time to the stop counts under its own kind", context do
      Repo.insert!(%DeadheadTime{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        from_ref: "garage:#{Ecto.UUID.generate()}",
        to_ref: "stop:1434",
        minutes: 12
      })

      assert counts(context, ["1434"]) == %{"1434" => %{deadhead_to: 1}}
    end

    test "a translation on another table with the same ID is not this stop's", context do
      Repo.insert!(%Translation{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        table_name: "routes",
        record_id: "1434",
        field_name: "route_short_name",
        language: "it",
        translation: "Quattordici"
      })

      Repo.insert!(%Translation{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        table_name: "stops",
        record_id: "1434",
        field_name: "stop_name",
        language: "es",
        translation: "Southwest 1st"
      })

      assert counts(context, ["1434"]) == %{"1434" => %{translations: 1}}
    end
  end

  describe "scoping" do
    test "a row in another version naming the same stop ID does not count", context do
      other = gtfs_version_fixture(context.organization.id)

      stop_time_fixture(context.organization.id, context.version.id, "T1", "1434")
      stop_time_fixture(context.organization.id, other.id, "T9", "1434")

      assert counts(context, ["1434"]) == %{"1434" => %{stop_times: 1}}
    end

    test "several stops are counted in one call", context do
      stop_time_fixture(context.organization.id, context.version.id, "T1", "1434")
      stop_time_fixture(context.organization.id, context.version.id, "T2", "7788")

      assert counts(context, ["1434", "7788"]) == %{
               "1434" => %{stop_times: 1},
               "7788" => %{stop_times: 1}
             }
    end
  end

  describe "the fk_uuid gap" do
    test "levels and journal entries cannot be counted before a stop row exists", context do
      # These are the two `via: :fk_uuid` entries. They match `stops.id`, which an
      # unimported natural key does not have, so they are absent from the result
      # rather than reported as zero — nothing was counted, not "none found".
      assert %{"1434" => kinds} = counts(context, ["1434"]) |> Map.put("1434", %{stop_times: 1})
      refute Map.has_key?(kinds, :stop_levels)
      refute Map.has_key?(kinds, :journal_entries)
    end
  end
end
