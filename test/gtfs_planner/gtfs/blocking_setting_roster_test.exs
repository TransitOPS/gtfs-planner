defmodule GtfsPlanner.Gtfs.BlockingSettingRosterTest do
  @moduledoc """
  The three roster rules accept their researched boundaries, refuse a value
  outside them, and keep the Block rules and the crew rules untouched, so a
  roster-settings save can neither rewrite another owner's columns nor read
  submitted `organization_id`/`gtfs_version_id`.

  These are pure changeset cases: `roster_changeset/2` is called directly, so
  no row is written and no database is touched. The column-isolation claim at
  the storage level — that the upsert replaces only `roster_fields/0` — belongs
  to `Rosters.update_roster_settings/3`, which does not exist yet; what is
  established here is the ownership boundary the changeset itself enforces.

  Run with:
  `mix test test/gtfs_planner/gtfs/blocking_setting_roster_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.BlockingSetting

  # Every field at a value that must be accepted, and deliberately not its
  # column default, so a rejection case can override one field and every
  # accepted case observes a real change.
  @valid %{
    "min_rest_minutes" => 660,
    "weekly_hours_warn_above" => 52,
    "roster_day_types" => %{"1" => "weekday"}
  }

  @organization_id "0f5f6f6c-2f36-4a0d-9a3a-2c1b1c0b7f01"
  @gtfs_version_id "9a3a2c1b-0b7f-4a0d-8f2f-6f6c2f364a0d"

  defp changeset(attrs) do
    attrs = Map.merge(@valid, attrs)

    BlockingSetting.roster_changeset(
      %BlockingSetting{organization_id: @organization_id, gtfs_version_id: @gtfs_version_id},
      attrs
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  describe "roster_changeset/2 ranges" do
    test "a setting row carries the researched defaults" do
      setting = %BlockingSetting{}

      assert setting.min_rest_minutes == 600
      assert setting.weekly_hours_warn_above == 48
      assert setting.roster_day_types == %{}
    end

    test "accepts both boundaries of the 480 to 720 minute rest range" do
      assert changeset(%{"min_rest_minutes" => 480}).valid?
      assert changeset(%{"min_rest_minutes" => 720}).valid?
    end

    test "accepts both boundaries of the 40 to 60 hour warning range" do
      assert changeset(%{"weekly_hours_warn_above" => 40}).valid?
      assert changeset(%{"weekly_hours_warn_above" => 60}).valid?
    end

    test "refuses 479 and 721 minutes of rest on the rest field" do
      too_short = changeset(%{"min_rest_minutes" => 479})
      refute too_short.valid?

      assert %{min_rest_minutes: ["must be a whole number between 480 and 720"]} =
               errors_on(too_short)

      too_long = changeset(%{"min_rest_minutes" => 721})
      refute too_long.valid?

      assert %{min_rest_minutes: ["must be a whole number between 480 and 720"]} =
               errors_on(too_long)
    end

    test "refuses 39 and 60+1 weekly hours on the warning field" do
      too_low = changeset(%{"weekly_hours_warn_above" => 39})
      refute too_low.valid?

      assert %{weekly_hours_warn_above: ["must be a whole number between 40 and 60"]} =
               errors_on(too_low)

      too_high = changeset(%{"weekly_hours_warn_above" => 61})
      refute too_high.valid?

      assert %{weekly_hours_warn_above: ["must be a whole number between 40 and 60"]} =
               errors_on(too_high)
    end

    test "refuses a blank rest as a mistake to fix rather than accepting the default" do
      result = changeset(%{"min_rest_minutes" => ""})

      refute result.valid?
      assert %{min_rest_minutes: ["is invalid"]} = errors_on(result)
      refute Map.has_key?(result.changes, :min_rest_minutes)
    end

    test "refuses a blank weekly warning as a mistake to fix rather than the default" do
      result = changeset(%{"weekly_hours_warn_above" => ""})

      refute result.valid?
      assert %{weekly_hours_warn_above: ["is invalid"]} = errors_on(result)
      refute Map.has_key?(result.changes, :weekly_hours_warn_above)
    end
  end

  describe "roster_changeset/2 roster_day_types" do
    test "accepts a weekday number mapped to a day type key" do
      result = changeset(%{"roster_day_types" => %{"1" => "key", "7" => "other"}})

      assert result.valid?
      assert result.changes.roster_day_types == %{"1" => "key", "7" => "other"}
    end

    test "accepts an empty map, so a version with no chosen base week stores" do
      result = changeset(%{"roster_day_types" => %{}})

      assert result.valid?
      # An empty map is the column's own default, so it is not a change; the
      # field still reads as the empty choice the base week resolves against.
      assert Ecto.Changeset.get_field(result, :roster_day_types) == %{}
    end

    test "refuses a weekday number outside one to seven" do
      result = changeset(%{"roster_day_types" => %{"8" => "key"}})

      refute result.valid?
      assert %{roster_day_types: ["must use weekday numbers 1 to 7"]} = errors_on(result)
    end

    test "refuses a weekday name instead of a number" do
      result = changeset(%{"roster_day_types" => %{"mon" => "key"}})

      refute result.valid?
      assert %{roster_day_types: ["must use weekday numbers 1 to 7"]} = errors_on(result)
    end

    test "refuses a day type key that is not a non-blank string" do
      blank = changeset(%{"roster_day_types" => %{"1" => ""}})

      refute blank.valid?

      assert %{roster_day_types: ["must choose a day type for every weekday"]} =
               errors_on(blank)

      missing = changeset(%{"roster_day_types" => %{"1" => nil}})

      refute missing.valid?

      assert %{roster_day_types: ["must choose a day type for every weekday"]} =
               errors_on(missing)
    end
  end

  describe "roster_changeset/2 column ownership" do
    test "ignores a submitted organization, version, Block rule and crew rule" do
      result =
        BlockingSetting.roster_changeset(
          %BlockingSetting{
            organization_id: @organization_id,
            gtfs_version_id: @gtfs_version_id
          },
          Map.merge(@valid, %{
            "organization_id" => "11111111-2222-3333-4444-555555555555",
            "gtfs_version_id" => "66666666-7777-8888-9999-aaaaaaaaaaaa",
            "min_layover_minutes" => 9,
            "report_pull_out_minutes" => 22
          })
        )

      assert result.valid?

      # The only changes are the three roster columns: a submitted identity and a
      # column another owner writes are both dropped, so this changeset cannot
      # move a setting to another version or rewrite a Block or crew rule.
      assert result.changes == %{
               min_rest_minutes: 660,
               weekly_hours_warn_above: 52,
               roster_day_types: %{"1" => "weekday"}
             }
    end

    test "roster_fields/0 is the three roster columns and owns no other list's column" do
      assert BlockingSetting.roster_fields() == [
               :min_rest_minutes,
               :weekly_hours_warn_above,
               :roster_day_types
             ]

      roster = BlockingSetting.roster_fields()

      assert roster -- BlockingSetting.settings_fields() == roster
      assert roster -- BlockingSetting.crew_fields() == roster
    end

    test "the other two lists keep the columns they owned before the roster rules" do
      assert BlockingSetting.settings_fields() == [
               :min_layover_minutes,
               :max_block_minutes,
               :pull_out_buffer_minutes,
               :interlining,
               :default_garage_id,
               :deadhead_speed_kmh,
               :deadhead_circuity,
               :max_piece_minutes
             ]

      assert BlockingSetting.crew_fields() == [
               :report_pull_out_minutes,
               :report_relief_minutes,
               :sign_off_minutes,
               :paid_break_max_minutes,
               :max_spread_minutes
             ]
    end
  end
end
