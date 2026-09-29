defmodule GtfsPlanner.Gtfs.Runs.CrewSettingsTest do
  @moduledoc """
  Merge evidence (EV-2) for CL-1: the crew rules read their researched defaults
  without writing a row, validate every range, save under the version and blocking
  locks, and leave the Block rules and the piece limit exactly as spec 07 stored
  them — in both directions — so FH-1 stays rejected.

  Every case goes through the `Gtfs` facade, which is the path the Runs page calls,
  and the two column-ownership cases round-trip through spec 07's own
  `update_settings/3` and `update_relief_settings/4` rather than writing
  `blocking_settings` by hand. The crew columns are only ever reached through
  `Runs` and `BlockingSetting`, which is the ownership rule the criteria state.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  The focused gate command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_runs08 mix test test/gtfs_planner/gtfs/runs/crew_settings_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Versions

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  @crew_defaults %{
    report_pull_out_minutes: 15,
    report_relief_minutes: 5,
    sign_off_minutes: 5,
    paid_break_max_minutes: 30,
    max_spread_minutes: 720
  }

  # Every field at a value that must be accepted, so one rejection case can
  # override a single field and the remaining error fields are not incidental.
  @valid %{
    report_pull_out_minutes: 10,
    report_relief_minutes: 4,
    sign_off_minutes: 6,
    paid_break_max_minutes: 45,
    max_spread_minutes: 600
  }

  # The eight Block rules fields `update_settings/3` owns, at values that are not
  # their defaults, so a crew save that reset them would be visible.
  @block_rules %{
    min_layover_minutes: 8,
    max_block_minutes: 600,
    pull_out_buffer_minutes: 5,
    interlining: "same_stop",
    default_garage_id: nil,
    deadhead_speed_kmh: 40,
    deadhead_circuity: 1.4,
    max_piece_minutes: 330
  }

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    # One calendar service, so the version has a day type: the piece limit is
    # saved against a day, and a version with no day type has nowhere to save it.
    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    %{organization: organization, version: version}
  end

  describe "get_crew_settings/2" do
    test "a version with no row reads the researched defaults and writes nothing", context do
      %{organization: organization, version: version} = context

      assert Runs.get_crew_settings(organization.id, version.id) == @crew_defaults

      # The read answered from the defaults without creating a row, so opening the
      # page cannot leave a settings row behind as a side effect of looking at it.
      assert Repo.aggregate(BlockingSetting, :count) == 0
    end

    test "the reader is scoped, so another organization's version reads the defaults", context do
      %{organization: organization, version: version} = context

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      assert {:ok, _} = Gtfs.update_crew_settings(organization.id, version.id, @valid)

      assert Runs.get_crew_settings(other_organization.id, other_version.id) == @crew_defaults
    end
  end

  describe "update_crew_settings/3" do
    test "stores the values and answers with them", context do
      %{organization: organization, version: version} = context

      assert {:ok, saved} = Gtfs.update_crew_settings(organization.id, version.id, @valid)
      assert saved == @valid

      assert Runs.get_crew_settings(organization.id, version.id) == @valid

      # One row, replaced rather than duplicated.
      assert Repo.aggregate(BlockingSetting, :count) == 1
    end

    test "a second save replaces the crew values and keeps one row", context do
      %{organization: organization, version: version} = context

      assert {:ok, _} = Gtfs.update_crew_settings(organization.id, version.id, @valid)

      updated = Map.put(@valid, :max_spread_minutes, 900)
      assert {:ok, ^updated} = Gtfs.update_crew_settings(organization.id, version.id, updated)

      assert Runs.get_crew_settings(organization.id, version.id) == updated
      assert Repo.aggregate(BlockingSetting, :count) == 1
    end

    test "each field accepts both bounds of its range", context do
      %{organization: organization, version: version} = context

      for {lower, upper} <- [
            {%{
               report_pull_out_minutes: 0,
               report_relief_minutes: 0,
               sign_off_minutes: 0,
               paid_break_max_minutes: 0,
               max_spread_minutes: 240
             },
             %{
               report_pull_out_minutes: 30,
               report_relief_minutes: 15,
               sign_off_minutes: 15,
               paid_break_max_minutes: 90,
               max_spread_minutes: 1080
             }}
          ] do
        assert {:ok, ^lower} = Gtfs.update_crew_settings(organization.id, version.id, lower)
        assert Runs.get_crew_settings(organization.id, version.id) == lower

        assert {:ok, ^upper} = Gtfs.update_crew_settings(organization.id, version.id, upper)
        assert Runs.get_crew_settings(organization.id, version.id) == upper
      end
    end

    test "each field rejects one past its range on that field and stores nothing", context do
      %{organization: organization, version: version} = context

      out_of_range = [
        {:report_pull_out_minutes, 31, "must be a whole number between 0 and 30"},
        {:report_relief_minutes, 16, "must be a whole number between 0 and 15"},
        {:sign_off_minutes, 16, "must be a whole number between 0 and 15"},
        {:paid_break_max_minutes, 91, "must be a whole number between 0 and 90"},
        {:max_spread_minutes, 1081, "must be a whole number between 240 and 1080"},
        {:max_spread_minutes, 239, "must be a whole number between 240 and 1080"}
      ]

      for {field, value, message} <- out_of_range do
        attrs = Map.put(@valid, field, value)

        assert {:error, changeset} = Gtfs.update_crew_settings(organization.id, version.id, attrs)
        assert %{^field => [^message]} = errors_on(changeset)

        # Nothing was written: a refused value leaves no row at all on a version
        # that had none, so a read still answers the defaults.
        assert Repo.aggregate(BlockingSetting, :count) == 0
        assert Runs.get_crew_settings(organization.id, version.id) == @crew_defaults
      end
    end

    test "a refused save after a good one leaves the stored values untouched", context do
      %{organization: organization, version: version} = context

      assert {:ok, _} = Gtfs.update_crew_settings(organization.id, version.id, @valid)

      assert {:error, changeset} =
               Gtfs.update_crew_settings(
                 organization.id,
                 version.id,
                 Map.put(@valid, :sign_off_minutes, 16)
               )

      assert %{sign_off_minutes: ["must be a whole number between 0 and 15"]} =
               errors_on(changeset)

      assert Runs.get_crew_settings(organization.id, version.id) == @valid
    end

    test "a blank value is rejected rather than stored as the default", context do
      %{organization: organization, version: version} = context

      assert {:error, changeset} =
               Gtfs.update_crew_settings(
                 organization.id,
                 version.id,
                 Map.put(@valid, :report_pull_out_minutes, "")
               )

      # A crew rule has no unset state, so a cleared input is a mistake to fix
      # rather than a value to fall back to: `empty_values: []` leaves the blank to
      # `cast/4` as an "is invalid" field error instead of turning it into `nil`,
      # which is what would let the default through.
      assert %{report_pull_out_minutes: ["is invalid"]} = errors_on(changeset)
      assert Repo.aggregate(BlockingSetting, :count) == 0
    end

    test "the scoping fields are not cast from submitted parameters", context do
      %{organization: organization, version: version} = context
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      assert {:ok, _} =
               Gtfs.update_crew_settings(
                 organization.id,
                 version.id,
                 Map.merge(@valid, %{
                   organization_id: other_organization.id,
                   gtfs_version_id: other_version.id
                 })
               )

      assert Runs.get_crew_settings(organization.id, version.id) == @valid
      assert Runs.get_crew_settings(other_organization.id, other_version.id) == @crew_defaults
    end
  end

  describe "column ownership" do
    test "a Block rules save after a crew save leaves every crew value unchanged", context do
      %{organization: organization, version: version} = context

      assert {:ok, _} = Gtfs.update_crew_settings(organization.id, version.id, @valid)

      assert {:ok, %BlockingSetting{}} =
               Gtfs.update_blocking_settings(organization.id, version.id, @block_rules)

      # The mutation that must not occur: the Block rules writer replaces only its
      # own eight columns, so the crew rules are exactly as the crew save left them.
      assert Runs.get_crew_settings(organization.id, version.id) == @valid

      assert [setting] = Repo.all(BlockingSetting)
      assert setting.report_pull_out_minutes == @valid.report_pull_out_minutes
      assert setting.max_spread_minutes == @valid.max_spread_minutes
      assert setting.min_layover_minutes == 8
      assert setting.max_piece_minutes == 330
    end

    test "a crew save after the Block rules and relief saves keeps the layover and the piece limit",
         context do
      %{organization: organization, version: version} = context

      assert {:ok, %BlockingSetting{}} =
               Gtfs.update_blocking_settings(organization.id, version.id, %{
                 @block_rules
                 | max_piece_minutes: nil
               })

      assert {:ok, :ok} =
               Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                 max_piece_minutes: 330,
                 marked: []
               })

      assert {:ok, _} = Gtfs.update_crew_settings(organization.id, version.id, @valid)

      # And the other way round: the crew upsert replaced only the five crew
      # columns, so the eight Block rules and the piece limit are untouched.
      assert Runs.get_crew_settings(organization.id, version.id) == @valid

      assert [setting] = Repo.all(BlockingSetting)
      assert setting.min_layover_minutes == 8
      assert setting.max_piece_minutes == 330
      assert setting.pull_out_buffer_minutes == 5
      assert setting.interlining == :same_stop
      assert setting.deadhead_speed_kmh == 40
      assert Decimal.equal?(setting.deadhead_circuity, Decimal.new("1.4"))
      assert setting.max_block_minutes == 600

      # One row throughout: neither writer created a second settings row.
      assert Repo.aggregate(BlockingSetting, :count) == 1
    end
  end

  describe "scoping" do
    test "an unpublished version and another organization's version are not found", context do
      %{organization: organization, version: version} = context

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()

      for {organization_id, gtfs_version_id} <- [
            {organization.id, staging.id},
            {other_organization.id, version.id}
          ] do
        assert {:error, :not_found} =
                 Gtfs.update_crew_settings(organization_id, gtfs_version_id, @valid)
      end

      # A refused scope writes nothing, so the version's own row is not created by
      # another organization's attempt.
      assert Repo.aggregate(BlockingSetting, :count) == 0
    end
  end

  describe "change_crew_settings/2" do
    test "renders the stored values and carries a rejected field's error", context do
      %{organization: organization, version: version} = context

      assert {:ok, _} = Gtfs.update_crew_settings(organization.id, version.id, @valid)
      crew = Runs.get_crew_settings(organization.id, version.id)

      changeset = Runs.change_crew_settings(crew, %{})

      assert changeset.valid?

      # The form renders the five crew fields; the rest of the struct is the
      # Block rules row this changeset never owns, exactly as `change_settings/2`
      # renders the eight the Block rules drawer owns.
      assert crew_of(Ecto.Changeset.apply_changes(changeset)) == crew

      # A form submits every field, so a stored value shows rather than the default.
      assert Ecto.Changeset.get_field(changeset, :max_spread_minutes) == @valid.max_spread_minutes

      rejected = Runs.change_crew_settings(crew, Map.put(@valid, :max_spread_minutes, 1081))

      refute rejected.valid?

      assert %{max_spread_minutes: ["must be a whole number between 240 and 1080"]} =
               errors_on(rejected)
    end

    test "a partial crew map is filled from the defaults", _context do
      changeset = Runs.change_crew_settings(%{max_spread_minutes: 480}, %{})

      assert changeset.valid?

      assert crew_of(Ecto.Changeset.apply_changes(changeset)) ==
               Map.put(@crew_defaults, :max_spread_minutes, 480)
    end
  end

  defp crew_of(setting) do
    Map.take(setting, BlockingSetting.crew_fields())
  end
end
