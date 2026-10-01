defmodule GtfsPlanner.Gtfs.Fares.TimePeriodsTest do
  @moduledoc """
  Merge evidence (EV-21) for `Fares.save_time_period/2`,
  `Fares.delete_time_period/3` and the inverse `Fares.undo/3` applies (AC-22,
  AC-26, R10, R15, FH-21).

  Every expected value is worked by hand from R10 and the prototype's North
  Coast sample, never read back from the code under test (CR-2):

  - a "Weekday peak" period with `06:00–09:00` and `15:00–18:00` is group
    `weekday_peak` (`fare_slug/1`, the slug rule `save_route_group/2` follows),
    service id `fare_weekday_peak`, weekday mask `31` (Monday `1` … Friday `5`),
    and two `timeframes` rows carrying that service id;
  - `until_end_of_day?: true` writes the last range's `end_time` as
    `"24:00:00"`, which GTFS reads as the end of the service day rather than
    `00:00:00` of the next one (R10);
  - `06:00` is `6 * 3_600 = 21_600`, `09:00` is `32_400`, `15:00` is `54_000` and
    `18:00` is `64_800`;
  - the fixture's `calendar.txt` declares one service id, `weekday`, so a period
    named "Weekday peak" starts at `fare_weekday_peak` and a `calendar` row
    already holding `fare_weekday_peak` pushes it to `fare_weekday_peak_2` (R10).

  The version enters rows through the production importer and the production v2
  conversion, and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/3` with `Fares.Normalize.run!/2`
  before the commit, which is the path every writer of this package takes
  (INV-1). Every read here filters by `organization_id` and `gtfs_version_id`
  together (INV-5).
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.FareTimePeriod
  alias GtfsPlanner.Gtfs.Timeframe
  alias GtfsPlanner.Repo

  # The fixture's one `calendar.txt` service id, which no period may collide
  # with: `save_time_period/2` prefixes its own ids with `fare_`, so this one is
  # never in the way.
  @fixture_service_id "weekday"

  # R10's weekday bitmask for Monday through Friday, and for Monday through
  # Sunday, which is every day and is therefore the mask a "all day" period
  # carries rather than a blank one.
  @weekdays 31
  @all_weekdays 127

  # 24:00:00 as seconds within the day, which the drawer may also send as the
  # text `"24:00:00"`; both reach the same range.
  @end_of_day 86_400

  # The `coast_ride` fare is priced for four rider types on cash, so a rule
  # naming the saved period is four `fare_leg_rules` rows, not one.
  @time_rule_rows 4

  setup do
    organization =
      organization_fixture(%{alias: "fares-time-periods-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      user_fixture(%{
        email: "fares-time-periods-#{System.unique_integer([:positive])}@example.com"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast fares editor"})
    import!(organization, version, "north_coast_v2")

    context = %{
      organization: organization,
      version: version,
      actor: actor,
      scope: scope(organization, version, actor)
    }

    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(context.scope, plan.fingerprint, [])

    context
  end

  describe "saving a new time period" do
    test "writes the period, both ranges and the fare-only service id", context do
      assert {:ok, _result} = Fares.save_time_period(context.scope, weekday_peak_form())

      assert [period] = period_rows(context)
      assert period.timeframe_group_id == "weekday_peak"
      assert period.name == "Weekday peak"
      assert period.weekdays == @weekdays
      assert period.until_end_of_day == false
      assert period.service_id == "fare_weekday_peak"

      # Two ranges, `06:00:00–09:00:00` and `15:00:00–18:00:00`, both under the
      # period's own service id, which is the id the exported calendar row is
      # written for.
      assert timeframe_rows(context) == [
               {"06:00:00", "09:00:00", "fare_weekday_peak"},
               {"15:00:00", "18:00:00", "fare_weekday_peak"}
             ]

      # The workspace read side draws the card from these two tables together.
      {:ok, workspace} = Fares.load_workspace(context.organization.id, context.version.id)

      assert [card] = workspace.time_periods
      assert card.name == "Weekday peak"

      assert card.ranges == [
               %{start_time: "06:00:00", end_time: "09:00:00"},
               %{start_time: "15:00:00", end_time: "18:00:00"}
             ]
    end

    test "records one change-log entry with the before and after rows", context do
      assert {:ok, saved} = Fares.save_time_period(context.scope, weekday_peak_form())

      assert [entry] = period_entries(context, saved.operation_id)
      assert entry.action == "created"
      assert entry.changed_fields["summary"] == "Created the time period \"Weekday peak\""
      assert entry.changed_fields["before"] == nil
      assert entry.changed_fields["after"]["timeframe_group_id"] == "weekday_peak"
      assert entry.changed_fields["after"]["service_id"] == "fare_weekday_peak"

      assert entry.changed_fields["after"]["ranges"] == [
               %{"start_time" => "06:00:00", "end_time" => "09:00:00"},
               %{"start_time" => "15:00:00", "end_time" => "18:00:00"}
             ]
    end

    test "until the end of the service day writes 24:00:00 for the last range", context do
      form =
        weekday_peak_form()
        |> Map.put(:ranges, [
          %{start_seconds: 21_600, end_seconds: 32_400},
          %{start_seconds: 54_000, end_seconds: @end_of_day}
        ])
        |> Map.put(:until_end_of_day?, true)

      assert {:ok, _result} = Fares.save_time_period(context.scope, form)

      assert [%{until_end_of_day: true}] = period_rows(context)

      # Only the last range runs to the end of the day; the first keeps the end
      # the drawer gave it (R10).
      assert timeframe_rows(context) == [
               {"06:00:00", "09:00:00", "fare_weekday_peak"},
               {"15:00:00", "24:00:00", "fare_weekday_peak"}
             ]
    end

    test "a calendar service id already in use pushes the period's own to _2", context do
      # The collision R10 names: an imported `calendar` row already holding
      # `fare_weekday_peak`. The fixture's own service id is `weekday`, which no
      # `fare_`-prefixed id reaches.
      assert calendar_service_ids(context) == [@fixture_service_id]

      insert_calendar!(context, "fare_weekday_peak")

      assert {:ok, _result} = Fares.save_time_period(context.scope, weekday_peak_form())

      assert [%{service_id: "fare_weekday_peak_2"}] = period_rows(context)

      # The ranges carry the id the period actually holds, not the one it was
      # refused.
      assert timeframe_rows(context) == [
               {"06:00:00", "09:00:00", "fare_weekday_peak_2"},
               {"15:00:00", "18:00:00", "fare_weekday_peak_2"}
             ]
    end

    test "a calendar_dates service id is a collision too", context do
      insert_calendar_date!(context, "fare_weekday_peak")

      assert {:ok, _result} = Fares.save_time_period(context.scope, weekday_peak_form())

      assert [%{service_id: "fare_weekday_peak_2"}] = period_rows(context)
    end

    test "saving the same period twice keeps one service id and one set of ranges", context do
      assert {:ok, _first} = Fares.save_time_period(context.scope, weekday_peak_form([]))

      # The second save edits the period it just wrote, the way the drawer does.
      assert {:ok, _second} =
               Fares.save_time_period(
                 context.scope,
                 weekday_peak_form(timeframe_group_id: "weekday_peak")
               )

      # The period's own id is not a collision with itself, so the second save
      # keeps `fare_weekday_peak` rather than suffixing away from the first, and
      # the ranges are not duplicated.
      assert [%{service_id: "fare_weekday_peak"}] = period_rows(context)
      assert length(timeframe_rows(context)) == 2
    end

    test "a name no slug can be made from is refused, and nothing is written", context do
      assert {:error, changeset} =
               Fares.save_time_period(context.scope, weekday_peak_form(name: "***"))

      assert %{name: ["must have a letter or a number"]} = errors_on(changeset)
      assert period_rows(context) == []
      assert timeframe_rows(context) == []
    end

    test "a blank name is refused, and nothing is written", context do
      assert {:error, changeset} =
               Fares.save_time_period(context.scope, weekday_peak_form(name: "   "))

      assert %{name: ["can't be blank"]} = errors_on(changeset)
      assert period_rows(context) == []
      assert timeframe_rows(context) == []
    end

    test "two periods with one slug are refused as duplicates", context do
      assert {:ok, _first} = Fares.save_time_period(context.scope, weekday_peak_form())

      assert {:error, :duplicate_time_period} =
               Fares.save_time_period(context.scope, weekday_peak_form(name: "weekday PEAK"))

      assert [%{name: "Weekday peak"}] = period_rows(context)
    end
  end

  describe "ranges the drawer cannot store" do
    test "overlapping ranges are refused, and nothing is written", context do
      form =
        weekday_peak_form()
        |> Map.put(:ranges, [
          %{start_seconds: 21_600, end_seconds: 32_400},
          %{start_seconds: 28_800, end_seconds: 54_000}
        ])

      assert {:error, changeset} = Fares.save_time_period(context.scope, form)

      assert %{ranges: ["can't overlap"]} = errors_on(changeset)
      assert period_rows(context) == []
      assert timeframe_rows(context) == []
    end

    test "overlap is refused whichever order the drawer sends the ranges in", context do
      form =
        weekday_peak_form()
        |> Map.put(:ranges, [
          %{start_seconds: 28_800, end_seconds: 54_000},
          %{start_seconds: 21_600, end_seconds: 32_400}
        ])

      assert {:error, changeset} = Fares.save_time_period(context.scope, form)
      assert %{ranges: ["can't overlap"]} = errors_on(changeset)
      assert timeframe_rows(context) == []
    end

    test "a range that ends before it starts is refused", context do
      form =
        weekday_peak_form()
        |> Map.put(:ranges, [%{start_seconds: 32_400, end_seconds: 21_600}])

      assert {:error, changeset} = Fares.save_time_period(context.scope, form)
      assert %{ranges: ["must start before it ends"]} = errors_on(changeset)
      assert period_rows(context) == []
    end

    test "no ranges at all is refused", context do
      form = weekday_peak_form() |> Map.put(:ranges, [])

      assert {:error, changeset} = Fares.save_time_period(context.scope, form)
      assert %{ranges: ["can't be blank"]} = errors_on(changeset)
      assert period_rows(context) == []
    end

    test "two ranges that meet end to end are stored, not refused", context do
      form =
        weekday_peak_form()
        |> Map.put(:ranges, [
          %{start_seconds: 21_600, end_seconds: 32_400},
          %{start_seconds: 32_400, end_seconds: 54_000}
        ])

      assert {:ok, _result} = Fares.save_time_period(context.scope, form)

      assert timeframe_rows(context) == [
               {"06:00:00", "09:00:00", "fare_weekday_peak"},
               {"09:00:00", "15:00:00", "fare_weekday_peak"}
             ]
    end

    test "a weekday mask the period's own changeset refuses writes nothing", context do
      for weekdays <- [0, 128] do
        assert {:error, changeset} =
                 Fares.save_time_period(context.scope, weekday_peak_form(weekdays: weekdays))

        assert %{weekdays: [_message]} = errors_on(changeset)
      end

      assert period_rows(context) == []
      assert timeframe_rows(context) == []
    end

    test "a blank weekday mask is valid and means every day", context do
      assert {:ok, _result} =
               Fares.save_time_period(context.scope, weekday_peak_form(weekdays: nil))

      assert [%{weekdays: nil}] = period_rows(context)
    end

    test "every day is the full mask, 127", context do
      assert {:ok, _result} =
               Fares.save_time_period(context.scope, weekday_peak_form(weekdays: @all_weekdays))

      assert [%{weekdays: @all_weekdays}] = period_rows(context)
    end
  end

  describe "editing a saved period" do
    setup context do
      {:ok, saved} = Fares.save_time_period(context.scope, weekday_peak_form())
      {:ok, context} = with_time_rule(context)

      {:ok, context: context, saved: saved}
    end

    test "replaces the ranges whole, keeping the group and the service id", context do
      assert {:ok, _result} =
               Fares.save_time_period(
                 context.scope,
                 weekday_peak_form(
                   timeframe_group_id: "weekday_peak",
                   ranges: [%{start_seconds: 32_400, end_seconds: @end_of_day}]
                 )
               )

      assert [%{service_id: "fare_weekday_peak", weekdays: 31}] = period_rows(context)

      assert timeframe_rows(context) == [
               {"09:00:00", "24:00:00", "fare_weekday_peak"}
             ]
    end

    test "a renamed period keeps its id and the service id it already holds", context do
      assert {:ok, _result} =
               Fares.save_time_period(
                 context.scope,
                 weekday_peak_form(
                   timeframe_group_id: "weekday_peak",
                   name: "Weekday evening",
                   ranges: weekday_peak_ranges()
                 )
               )

      # The group id is what the rules name, so it never moves; the name is the
      # operator's to edit. R10 makes the service id `fare_<slug>` of the
      # period's name, so a rename re-derives it and the export writes this
      # period's calendar row under the id it holds then.
      assert [%{timeframe_group_id: "weekday_peak", name: "Weekday evening"}] =
               period_rows(context)

      assert [%{service_id: "fare_weekday_evening"}] = period_rows(context)

      # The ranges follow the period's own id, so the calendar row the export
      # appends and the timeframes it streams name one service.
      assert timeframe_rows(context) == [
               {"06:00:00", "09:00:00", "fare_weekday_evening"},
               {"15:00:00", "18:00:00", "fare_weekday_evening"}
             ]
    end

    test "a period this version does not hold is not found", context do
      assert {:error, :not_found} =
               Fares.save_time_period(
                 context.scope,
                 weekday_peak_form(timeframe_group_id: "evening_peak")
               )

      assert [%{name: "Weekday peak"}] = period_rows(context)
      assert length(timeframe_rows(context)) == 2
    end

    test "an unmanaged version is refused", context do
      assert {:error, :unmanaged} =
               Fares.save_time_period(unmanaged_scope(context), weekday_peak_form())
    end
  end

  describe "deleting a time period" do
    setup context do
      {:ok, saved} = Fares.save_time_period(context.scope, weekday_peak_form())
      {:ok, context} = with_time_rule(context)

      {:ok, context: context, saved: saved}
    end

    test "refuses while a rule names it, and deletes nothing", context do
      assert {:error, :rules_reference_time_period} =
               Fares.delete_time_period(context.scope, "weekday_peak", %{
                 name: "Weekday peak"
               })

      assert [%{name: "Weekday peak"}] = period_rows(context)
      assert length(timeframe_rows(context)) == 2
      assert time_rule_count(context) == @time_rule_rows
    end

    test "deletes the period, its ranges and the rules that named it", context do
      assert {:ok, deleted} =
               Fares.delete_time_period(context.scope, "weekday_peak", %{
                 name: "Weekday peak",
                 remove_rules: true
               })

      assert period_rows(context) == []
      assert timeframe_rows(context) == []
      assert time_rule_count(context) == 0

      assert [entry] = period_entries(context, deleted.operation_id)
      assert entry.action == "deleted"
      assert entry.changed_fields["summary"] == "Deleted the time period \"Weekday peak\""
      assert entry.changed_fields["before"]["timeframe_group_id"] == "weekday_peak"

      assert entry.changed_fields["before"]["ranges"] == [
               %{"start_time" => "06:00:00", "end_time" => "09:00:00"},
               %{"start_time" => "15:00:00", "end_time" => "18:00:00"}
             ]

      assert entry.changed_fields["after"] == []
    end

    test "a period no rule names deletes without the remove_rules choice", context do
      # A second period, which nothing names, so the refusal above is about the
      # rule rather than about the delete itself.
      assert {:ok, _saved} =
               Fares.save_time_period(
                 context.scope,
                 weekday_peak_form(name: "Evening peak", ranges: weekday_peak_ranges())
               )

      assert {:ok, _deleted} =
               Fares.delete_time_period(context.scope, "evening_peak", %{name: "Evening peak"})

      assert [%{timeframe_group_id: "weekday_peak"}] = period_rows(context)

      assert timeframe_rows(context) == [
               {"06:00:00", "09:00:00", "fare_weekday_peak"},
               {"15:00:00", "18:00:00", "fare_weekday_peak"}
             ]

      assert time_rule_count(context) == @time_rule_rows
    end

    test "a stale name fence deletes nothing", context do
      assert {:error, {:stale, stale}} =
               Fares.delete_time_period(context.scope, "weekday_peak", %{
                 name: "Evening",
                 remove_rules: true
               })

      assert [%{field: :name, reviewed: "Evening", stored: "Weekday peak"}] = stale
      assert [%{name: "Weekday peak"}] = period_rows(context)
    end

    test "a period this version does not hold is not found", context do
      assert {:error, :not_found} =
               Fares.delete_time_period(context.scope, "evening_peak", %{name: "Evening"})
    end

    test "an unmanaged version is refused", context do
      assert {:error, :unmanaged} =
               Fares.delete_time_period(unmanaged_scope(context), "weekday_peak", %{})
    end
  end

  describe "undoing a time period change" do
    setup context do
      {:ok, saved} = Fares.save_time_period(context.scope, weekday_peak_form())
      {:ok, context} = with_time_rule(context)

      {:ok, context: context, saved: saved}
    end

    test "restores a deleted period, its ranges and the rules it settled", context do
      assert {:ok, deleted} =
               Fares.delete_time_period(context.scope, "weekday_peak", %{
                 name: "Weekday peak",
                 remove_rules: true
               })

      assert {:ok, _undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      assert [%{name: "Weekday peak", service_id: "fare_weekday_peak"}] = period_rows(context)

      assert timeframe_rows(context) == [
               {"06:00:00", "09:00:00", "fare_weekday_peak"},
               {"15:00:00", "18:00:00", "fare_weekday_peak"}
             ]

      assert time_rule_count(context) == @time_rule_rows

      # A second reversal of the same entry is stale rather than applied twice.
      assert {:error, :stale} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)
    end

    test "restores the ranges a save replaced", context do
      assert {:ok, saved} =
               Fares.save_time_period(
                 context.scope,
                 weekday_peak_form(
                   timeframe_group_id: "weekday_peak",
                   ranges: [%{start_seconds: 32_400, end_seconds: @end_of_day}]
                 )
               )

      assert timeframe_rows(context) == [{"09:00:00", "24:00:00", "fare_weekday_peak"}]

      assert {:ok, _undone} = Fares.undo(context.scope, saved.operation_id, saved.inverse)

      assert timeframe_rows(context) == [
               {"06:00:00", "09:00:00", "fare_weekday_peak"},
               {"15:00:00", "18:00:00", "fare_weekday_peak"}
             ]
    end

    test "deletes a period a save created, and restores one a save changed", context do
      assert {:ok, saved} =
               Fares.save_time_period(
                 context.scope,
                 weekday_peak_form(
                   timeframe_group_id: "weekday_peak",
                   name: "Weekday evening",
                   ranges: weekday_peak_ranges()
                 )
               )

      assert [%{name: "Weekday evening"}] = period_rows(context)

      assert {:ok, _undone} = Fares.undo(context.scope, saved.operation_id, saved.inverse)

      assert [%{name: "Weekday peak"}] = period_rows(context)
    end

    test "a later edit of the same period makes the reversal stale", context do
      assert {:ok, _saved} =
               Fares.save_time_period(
                 context.scope,
                 weekday_peak_form(
                   timeframe_group_id: "weekday_peak",
                   ranges: [%{start_seconds: 32_400, end_seconds: @end_of_day}]
                 )
               )

      assert {:error, :stale} =
               Fares.undo(context.scope, context.saved.operation_id, context.saved.inverse)

      # Nothing the later save left was touched by the refused reversal.
      assert timeframe_rows(context) == [{"09:00:00", "24:00:00", "fare_weekday_peak"}]
    end

    test "an operation id this version does not hold is stale", context do
      assert {:error, :stale} =
               Fares.undo(context.scope, Ecto.UUID.generate(), context.saved.inverse)

      assert [%{name: "Weekday peak"}] = period_rows(context)
    end
  end

  # -- Helpers ------------------------------------------------------------------

  # The time periods drawer's form for R10's example, as seconds within the day.
  defp weekday_peak_ranges do
    [
      %{start_seconds: 21_600, end_seconds: 32_400},
      %{start_seconds: 54_000, end_seconds: 64_800}
    ]
  end

  defp weekday_peak_form(overrides \\ []) do
    Map.merge(
      %{
        name: "Weekday peak",
        weekdays: @weekdays,
        ranges: weekday_peak_ranges(),
        until_end_of_day?: false
      },
      Map.new(overrides)
    )
  end

  # A fare rule that names the saved period, written through `save_rule/3` the
  # way the rule drawer would: the period exists first, so this is the production
  # path a rule naming a time period takes (R3, INV-5).
  defp with_time_rule(context) do
    assert {:ok, _saved} =
             Fares.save_rule(
               context.scope,
               %{
                 network_id: "N_LOCAL",
                 from_area_id: "CST",
                 to_area_id: "TOL",
                 from_timeframe_group_id: "weekday_peak",
                 fare_product_id: "coast_ride_adult_cash"
               },
               :replace
             )

    {:ok, context}
  end

  defp scope(organization, version, actor) do
    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp scope_for(context, gtfs_version_id) do
    %{
      context.scope
      | gtfs_version_id: gtfs_version_id,
        audit: %{context.scope.audit | gtfs_version_id: gtfs_version_id}
    }
  end

  # A second version of the same organization, imported but never converted, so a
  # refusal can be asked of a scope that names an unmanaged version.
  defp unmanaged_scope(context) do
    version = gtfs_version_fixture(context.organization.id, %{name: "Unmanaged fares"})
    import!(context.organization, version, "north_coast_v2")
    scope_for(context, version.id)
  end

  defp period_rows(context) do
    FareTimePeriod |> scoped(context) |> order_by([row], row.timeframe_group_id) |> Repo.all()
  end

  defp timeframe_rows(context) do
    Timeframe
    |> scoped(context)
    |> order_by([row], row.start_time)
    |> Repo.all()
    |> Enum.map(&{&1.start_time, &1.end_time, &1.service_id})
  end

  # The rows naming the saved period. `save_rule/3` writes one row per product of
  # the chosen fare, so the four rider types of `coast_ride` are four rows of
  # one rule, and a delete settles all four (R3).
  defp time_rule_count(context) do
    FareLegRule
    |> scoped(context)
    |> where([rule], rule.from_timeframe_group_id == "weekday_peak")
    |> Repo.aggregate(:count)
  end

  defp calendar_service_ids(context) do
    Calendar |> scoped(context) |> select([row], row.service_id) |> Repo.all() |> Enum.sort()
  end

  # The `calendar.txt` row R10 collides against: the period's own `fare_` id
  # already held by a service the version runs, so the writer must suffix.
  defp insert_calendar!(context, service_id) do
    {:ok, row} =
      %Calendar{}
      |> struct(%{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id
      })
      |> Calendar.changeset(%{
        service_id: service_id,
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-09-01],
        end_date: ~D[2026-09-30]
      })
      |> Repo.insert()

    row
  end

  # The same collision stated through `calendar_dates.txt`, which names service
  # ids too and is the second table R10's uniqueness is checked against.
  defp insert_calendar_date!(context, service_id) do
    {:ok, row} =
      %CalendarDate{}
      |> struct(%{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id
      })
      |> CalendarDate.changeset(%{
        service_id: service_id,
        date: ~D[2026-09-07],
        exception_type: 2
      })
      |> Repo.insert()

    row
  end

  # The change-log entry this operation recorded, addressed the way every writer
  # of this module addresses one: by its operation id (R15, AC-26).
  defp period_entries(context, operation_id) do
    ChangeLog
    |> scoped(context)
    |> where([entry], entry.entity_type == "fare_version")
    |> where([entry], fragment("?->>?", entry.changed_fields, "operation_id") == ^operation_id)
    |> Repo.all()
  end

  defp scoped(queryable, context) do
    where(
      queryable,
      [row],
      row.organization_id == ^context.organization.id and
        row.gtfs_version_id == ^context.version.id
    )
  end
end
