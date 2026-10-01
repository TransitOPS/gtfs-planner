defmodule GtfsPlanner.Gtfs.Rosters.RosterSettingsTest do
  @moduledoc """
  The roster rules read their researched defaults without writing a row, validate
  every range, refuse a base-week day type that is not current for the weekday it
  was chosen for, save under the version and blocking locks, and leave the crew
  rules and the Block rules exactly as the Runs and Blocks pages stored them, in
  both directions.

  Every case goes through the `Gtfs` facade, which is the path the Rosters page
  calls, and the two column-ownership cases round-trip through the Runs page's own
  `update_crew_settings/3` and the Blocks page's `update_settings/3` rather than
  writing `blocking_settings` by hand. The roster columns are only ever reached
  through `Rosters` and `BlockingSetting`, which is the column-ownership rule.

  The day-type world is `RunsFixtures.runs_version_fixture/1`: a published version
  whose one calendar service runs Monday to Friday over 2026, so its single day
  type has dates on ISO weekdays 1 to 5 and none on Saturday or Sunday. That is
  what makes both halves of the day-type check observable — a key that is not a
  day type at all, and a real day type with no date on the chosen weekday.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/roster_settings_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Rosters
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Versions

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  @roster_defaults %{
    min_rest_minutes: 600,
    weekly_hours_warn_above: 48,
    roster_day_types: %{}
  }

  # Every field at a value that must be accepted, so one rejection case can
  # override a single field and the remaining error fields are not incidental.
  # The weekday "1" is Monday, which the fixture's weekday day type does run on.
  @valid %{min_rest_minutes: 540, weekly_hours_warn_above: 50}

  # The five crew fields `update_crew_settings/3` owns, at values that are not
  # their defaults, so a roster save that reset them would be visible.
  @crew_rules %{
    report_pull_out_minutes: 10,
    report_relief_minutes: 4,
    sign_off_minutes: 6,
    paid_break_max_minutes: 45,
    max_spread_minutes: 600
  }

  # The eight Block rules fields `update_settings/3` owns, at values that are not
  # their defaults either. `default_garage_id` stays `nil` because this world has
  # no garage to name.
  @block_rules %{
    min_layover_minutes: 8,
    max_block_minutes: 600,
    pull_out_buffer_minutes: 5,
    interlining: "same_stop",
    default_garage_id: nil,
    deadhead_speed_kmh: 40,
    deadhead_circuity: 1.4,
    max_piece_minutes: nil
  }

  setup do
    runs_version_fixture()
  end

  describe "get_roster_settings/2" do
    test "a version with no row reads the researched defaults and writes nothing" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert Rosters.get_roster_settings(organization.id, version.id) == @roster_defaults

      # The read answered from the defaults without creating a row, so opening the
      # page cannot leave a settings row behind as a side effect of looking at it.
      assert no_settings_row(version)
    end

    test "the reader is scoped, so another organization's version reads the defaults", %{
      organization: organization,
      version: version,
      day_type_key: day_type_key
    } do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      assert {:ok, _} =
               Gtfs.update_roster_settings(
                 organization.id,
                 version.id,
                 Map.put(@valid, :roster_day_types, %{"1" => day_type_key})
               )

      assert Rosters.get_roster_settings(other_organization.id, other_version.id) ==
               @roster_defaults
    end
  end

  describe "update_roster_settings/3" do
    test "stores the values and answers with them", context do
      %{organization: organization, version: version, day_type_key: day_type_key} = context
      attrs = Map.put(@valid, :roster_day_types, %{"1" => day_type_key})

      assert {:ok, saved} = Gtfs.update_roster_settings(organization.id, version.id, attrs)
      assert saved == attrs

      # Re-read from the table rather than from the answer the save returned.
      assert Rosters.get_roster_settings(organization.id, version.id) == attrs
    end

    test "a second save replaces the roster values and keeps one row", context do
      %{organization: organization, version: version, day_type_key: day_type_key} = context
      attrs = Map.put(@valid, :roster_day_types, %{"1" => day_type_key})

      assert {:ok, _} = Gtfs.update_roster_settings(organization.id, version.id, attrs)

      second = %{attrs | min_rest_minutes: 700, roster_day_types: %{"2" => day_type_key}}
      assert {:ok, ^second} = Gtfs.update_roster_settings(organization.id, version.id, second)

      assert Rosters.get_roster_settings(organization.id, version.id) == second
      assert Repo.aggregate(BlockingSetting, :count) == 1
    end

    test "each field accepts both bounds of its range", context do
      %{organization: organization, version: version, day_type_key: day_type_key} = context

      for attrs <- [
            %{min_rest_minutes: 480, weekly_hours_warn_above: 40},
            %{min_rest_minutes: 720, weekly_hours_warn_above: 60}
          ] do
        attrs = Map.put(attrs, :roster_day_types, %{"1" => day_type_key})

        assert {:ok, ^attrs} = Gtfs.update_roster_settings(organization.id, version.id, attrs)
        assert Rosters.get_roster_settings(organization.id, version.id) == attrs
      end
    end

    test "each field rejects one past its range and stores nothing" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      out_of_range = [
        {:min_rest_minutes, 479, "must be a whole number between 480 and 720"},
        {:min_rest_minutes, 721, "must be a whole number between 480 and 720"},
        {:weekly_hours_warn_above, 39, "must be a whole number between 40 and 60"},
        {:weekly_hours_warn_above, 61, "must be a whole number between 40 and 60"}
      ]

      for {field, value, message} <- out_of_range do
        assert {:error, changeset} =
                 Gtfs.update_roster_settings(
                   organization.id,
                   version.id,
                   Map.put(@valid, field, value)
                 )

        assert %{^field => [^message]} = errors_on(changeset)

        # Nothing was written: a refused value leaves no row at all on a version
        # that had none, so a read still answers the defaults.
        assert no_settings_row(version)
        assert Rosters.get_roster_settings(organization.id, version.id) == @roster_defaults
      end
    end

    test "a blank value is rejected rather than stored as the default" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert {:error, changeset} =
               Gtfs.update_roster_settings(
                 organization.id,
                 version.id,
                 Map.put(@valid, :min_rest_minutes, "")
               )

      # A roster rule has no unset state, so a cleared input is a mistake to fix
      # rather than a value to fall back to: `empty_values: []` leaves the blank to
      # `cast/4` as an "is invalid" field error instead of turning it into `nil`,
      # which is what would let the default through.
      assert %{min_rest_minutes: ["is invalid"]} = errors_on(changeset)
      assert no_settings_row(version)
    end

    test "a day type that is not current for the weekday is refused", context do
      %{organization: organization, version: version, day_type_key: day_type_key} = context

      # A key the version's calendars do not derive, and the real weekday day type
      # named for a Saturday it has no date on. Both must be refused with the same
      # sentence naming the weekday the choice was for.
      for {weekday, key, message} <- [
            {"1", "not-a-day-type-key", "Choose a day type that runs on Monday."},
            {"6", day_type_key, "Choose a day type that runs on Saturday."}
          ] do
        attrs = Map.put(@valid, :roster_day_types, %{weekday => key})

        assert {:error, changeset} =
                 Gtfs.update_roster_settings(organization.id, version.id, attrs)

        assert %{roster_day_types: [^message]} = errors_on(changeset)

        assert Repo.aggregate(BlockingSetting, :count) == 1
        assert Rosters.get_roster_settings(organization.id, version.id) == @roster_defaults
      end
    end

    test "a malformed weekday and a blank key are each refused once", context do
      %{organization: organization, version: version, day_type_key: day_type_key} = context

      # `roster_changeset/2` already refuses both of these on shape, so the writer
      # must not answer the same entry a second time with a day-type error.
      for choices <- [%{"8" => day_type_key}, %{"1" => "  "}, %{"1" => ""}] do
        attrs = Map.put(@valid, :roster_day_types, choices)

        assert {:error, changeset} =
                 Gtfs.update_roster_settings(organization.id, version.id, attrs)

        assert [message] = errors_on(changeset).roster_day_types
        refute message =~ "Choose a day type that runs on"
      end
    end

    test "a refused save after a good one leaves the stored values untouched", context do
      %{organization: organization, version: version, day_type_key: day_type_key} = context
      attrs = Map.put(@valid, :roster_day_types, %{"1" => day_type_key})

      assert {:ok, _} = Gtfs.update_roster_settings(organization.id, version.id, attrs)

      assert {:error, changeset} =
               Gtfs.update_roster_settings(
                 organization.id,
                 version.id,
                 Map.put(attrs, :roster_day_types, %{"1" => "not-a-day-type-key"})
               )

      assert %{roster_day_types: ["Choose a day type that runs on Monday."]} =
               errors_on(changeset)

      assert Rosters.get_roster_settings(organization.id, version.id) == attrs
    end

    test "the scoping fields are not cast from submitted parameters", context do
      %{organization: organization, version: version, day_type_key: day_type_key} = context
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      attrs =
        @valid
        |> Map.put(:roster_day_types, %{"1" => day_type_key})
        |> Map.merge(%{
          organization_id: other_organization.id,
          gtfs_version_id: other_version.id
        })

      assert {:ok, _} = Gtfs.update_roster_settings(organization.id, version.id, attrs)

      assert Rosters.get_roster_settings(organization.id, version.id) ==
               Map.take(attrs, [:min_rest_minutes, :weekly_hours_warn_above, :roster_day_types])

      assert Rosters.get_roster_settings(other_organization.id, other_version.id) ==
               @roster_defaults
    end
  end

  describe "column ownership" do
    test "a crew save after a roster save leaves every roster value unchanged", context do
      %{organization: organization, version: version, day_type_key: day_type_key, audit: audit} =
        context

      roster = Map.put(@valid, :roster_day_types, %{"1" => day_type_key})

      assert {:ok, _} = Gtfs.update_roster_settings(organization.id, version.id, roster)
      assert {:ok, _} = Gtfs.update_crew_settings(audit, @crew_rules)

      # The mutation that must not occur: the crew upsert replaced only its own
      # five columns, so the roster rules are exactly as the roster save left them.
      assert Rosters.get_roster_settings(organization.id, version.id) == roster

      assert [setting] = Repo.all(BlockingSetting)
      assert setting.min_rest_minutes == roster.min_rest_minutes
      assert setting.weekly_hours_warn_above == roster.weekly_hours_warn_above
      assert setting.roster_day_types == roster.roster_day_types
      assert setting.report_pull_out_minutes == @crew_rules.report_pull_out_minutes
      assert setting.max_spread_minutes == @crew_rules.max_spread_minutes
    end

    test "a roster save after the crew and Block rules saves keeps both", context do
      %{organization: organization, version: version, day_type_key: day_type_key, audit: audit} =
        context

      assert {:ok, _} = Gtfs.update_crew_settings(audit, @crew_rules)

      assert {:ok, %BlockingSetting{}} = Gtfs.update_blocking_settings(audit, @block_rules)

      roster = Map.put(@valid, :roster_day_types, %{"1" => day_type_key})
      assert {:ok, _} = Gtfs.update_roster_settings(organization.id, version.id, roster)

      assert Runs.get_crew_settings(organization.id, version.id) == @crew_rules

      settings = Blocking.get_settings(organization.id, version.id)
      assert settings.min_layover_minutes == 8
      assert settings.max_block_minutes == 600
      assert settings.pull_out_buffer_minutes == 5
      assert settings.interlining == :same_stop
      assert settings.deadhead_speed_kmh == 40
      assert settings.deadhead_circuity == 1.4

      assert [setting] = Repo.all(BlockingSetting)
      assert setting.report_pull_out_minutes == @crew_rules.report_pull_out_minutes
      assert setting.sign_off_minutes == @crew_rules.sign_off_minutes
      assert setting.paid_break_max_minutes == @crew_rules.paid_break_max_minutes
      assert setting.report_relief_minutes == @crew_rules.report_relief_minutes
      assert setting.min_layover_minutes == 8

      # One row throughout: neither writer created a second settings row.
      assert Repo.aggregate(BlockingSetting, :count) == 1
    end
  end

  describe "scoping" do
    test "an unpublished version and another organization's version are not found", context do
      %{organization: organization, version: version, day_type_key: day_type_key} = context

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})
      other_organization = organization_fixture()
      attrs = Map.put(@valid, :roster_day_types, %{"1" => day_type_key})

      for {organization_id, gtfs_version_id} <- [
            {organization.id, staging.id},
            {other_organization.id, version.id}
          ] do
        assert {:error, :not_found} =
                 Gtfs.update_roster_settings(organization_id, gtfs_version_id, attrs)
      end

      # A refused scope writes nothing, so the version's own row is not created by
      # another organization's attempt.
      assert Repo.aggregate(BlockingSetting, :count) == 1
      assert Rosters.get_roster_settings(organization.id, version.id) == @roster_defaults
    end
  end

  describe "change_roster_settings/2" do
    test "renders the stored values and carries a rejected field's error", context do
      %{organization: organization, version: version, day_type_key: day_type_key} = context
      roster = Map.put(@valid, :roster_day_types, %{"1" => day_type_key})

      assert {:ok, _} = Gtfs.update_roster_settings(organization.id, version.id, roster)
      stored = Rosters.get_roster_settings(organization.id, version.id)

      changeset = Rosters.change_roster_settings(stored, %{})

      assert changeset.valid?

      # The form renders the three roster fields; the rest of the struct is the
      # settings row this changeset never owns, exactly as `change_settings/2`
      # renders the eight the Block rules drawer owns.
      assert roster_of(Ecto.Changeset.apply_changes(changeset)) == roster

      rejected = Rosters.change_roster_settings(stored, Map.put(roster, :min_rest_minutes, 479))

      refute rejected.valid?

      assert %{min_rest_minutes: ["must be a whole number between 480 and 720"]} =
               errors_on(rejected)
    end

    test "a partial roster map is filled from the defaults", _context do
      changeset = Rosters.change_roster_settings(%{min_rest_minutes: 480}, %{})

      assert changeset.valid?

      assert roster_of(Ecto.Changeset.apply_changes(changeset)) ==
               Map.put(@roster_defaults, :min_rest_minutes, 480)
    end
  end

  defp roster_of(setting) do
    Map.take(setting, BlockingSetting.roster_fields())
  end

  # Whether a version holds no `blocking_settings` row at all. Scoped to the
  # version, not counted over the table: this file's `setup` builds a whole
  # `runs_version_fixture/0` world, and that world writes the Block and crew
  # rules of its *own* version through their own writers. A whole-table count
  # would read that unrelated row as a leaked write.
  defp no_settings_row(version) do
    Repo.aggregate(from(b in BlockingSetting, where: b.gtfs_version_id == ^version.id), :count) ==
      0
  end
end
