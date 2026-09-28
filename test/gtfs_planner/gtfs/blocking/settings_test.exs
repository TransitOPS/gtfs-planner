defmodule GtfsPlanner.Gtfs.Blocking.SettingsTest do
  # EV-1: the minimum-layover storage contract observed through the real `Gtfs`
  # facade and the scoped `Blocking` context. Rows are created inside the SQL
  # Sandbox transaction and rolled back.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner/gtfs/blocking/settings_test.exs`.
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Versions

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "get_settings/2" do
    test "an unset version reads the default and stores no row" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert Blocking.get_settings(organization.id, version.id) == %{min_layover_minutes: 5}
      assert Repo.aggregate(BlockingSetting, :count) == 0
    end
  end

  describe "update_settings/3" do
    test "a saved value is read back and a repeated save replaces the same row" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert {:ok, %BlockingSetting{min_layover_minutes: 12}} =
               Blocking.update_settings(organization.id, version.id, %{min_layover_minutes: 12})

      assert Blocking.get_settings(organization.id, version.id) == %{min_layover_minutes: 12}

      assert {:ok, %BlockingSetting{min_layover_minutes: 20}} =
               Blocking.update_settings(organization.id, version.id, %{min_layover_minutes: 20})

      assert Blocking.get_settings(organization.id, version.id) == %{min_layover_minutes: 20}
      assert Repo.aggregate(BlockingSetting, :count) == 1
    end

    test "an out-of-range, non-numeric or blank value is rejected with a field error and stores nothing" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert_rejected(organization.id, version.id, 121)
      assert_rejected(organization.id, version.id, -1)
      assert_rejected(organization.id, version.id, "abc")
      assert_rejected(organization.id, version.id, "")

      assert Repo.aggregate(BlockingSetting, :count) == 0
    end

    test "the database refuses an out-of-range value written outside the changeset" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      # The struct insert declares no check_constraint, so Ecto surfaces the
      # PostgreSQL check violation as Ecto.ConstraintError naming the constraint.
      assert_raise Ecto.ConstraintError, ~r/min_layover_range/, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%BlockingSetting{
            organization_id: organization.id,
            gtfs_version_id: version.id,
            min_layover_minutes: 121
          })
        end)
      end
    end

    test "a staging version and another organization's version are not found" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})
      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      assert Blocking.update_settings(organization.id, staging.id, %{min_layover_minutes: 12}) ==
               {:error, :not_found}

      assert Blocking.update_settings(organization.id, foreign_version.id, %{
               min_layover_minutes: 12
             }) == {:error, :not_found}

      assert Repo.aggregate(BlockingSetting, :count) == 0
    end

    test "two versions of one organization keep separate values" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_version = gtfs_version_fixture(organization.id)

      assert {:ok, %BlockingSetting{}} =
               Blocking.update_settings(organization.id, version.id, %{min_layover_minutes: 12})

      assert {:ok, %BlockingSetting{}} =
               Blocking.update_settings(organization.id, other_version.id, %{
                 min_layover_minutes: 30
               })

      assert Blocking.get_settings(organization.id, version.id) == %{min_layover_minutes: 12}

      assert Blocking.get_settings(organization.id, other_version.id) == %{
               min_layover_minutes: 30
             }

      assert Repo.aggregate(BlockingSetting, :count) == 2
    end

    test "submitted organization and version IDs are ignored" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      assert {:ok, stored} =
               Blocking.update_settings(organization.id, version.id, %{
                 min_layover_minutes: 12,
                 organization_id: other_organization.id,
                 gtfs_version_id: foreign_version.id
               })

      assert stored.organization_id == organization.id
      assert stored.gtfs_version_id == version.id
      assert Blocking.get_settings(organization.id, version.id) == %{min_layover_minutes: 12}

      assert Blocking.get_settings(other_organization.id, foreign_version.id) == %{
               min_layover_minutes: 5
             }
    end
  end

  describe "change_settings/2" do
    test "renders the current value and reports an out-of-range change" do
      changeset = Blocking.change_settings(%{min_layover_minutes: 12}, %{})

      assert Ecto.Changeset.get_field(changeset, :min_layover_minutes) == 12

      changeset =
        Blocking.change_settings(%{min_layover_minutes: 12}, %{min_layover_minutes: 121})

      refute changeset.valid?

      assert %{min_layover_minutes: ["must be a whole number between 0 and 120"]} =
               errors_on(changeset)
    end
  end

  describe "Gtfs facade" do
    test "the facade reaches the same setting read and write" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert Gtfs.get_blocking_settings(organization.id, version.id) == %{min_layover_minutes: 5}

      assert {:ok, %BlockingSetting{min_layover_minutes: 12}} =
               Gtfs.update_blocking_settings(organization.id, version.id, %{
                 min_layover_minutes: 12
               })

      assert Gtfs.get_blocking_settings(organization.id, version.id) == %{min_layover_minutes: 12}
    end
  end

  defp assert_rejected(organization_id, gtfs_version_id, value) do
    assert {:error, changeset} =
             Blocking.update_settings(organization_id, gtfs_version_id, %{
               min_layover_minutes: value
             })

    assert %{min_layover_minutes: [_message]} = errors_on(changeset)
  end
end
