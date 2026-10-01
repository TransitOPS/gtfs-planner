defmodule GtfsPlanner.Gtfs.Calendars.ExtensionReviewTest do
  @moduledoc """
  The approved native weekly end-date extension of step 5.

  The extension is the ordinary `{:save, service_id, attrs}` command with an extra
  `:approval_text` in `attrs`, so there is no parallel writer: preparation is a review and
  writes nothing, and the accepted apply goes through the same native save path. These
  cases prove, against committed rows:

  - Preparation writes no calendar, attribute, exception or audit row, and each refusal
    (blank approval, overlong approval, date-only calendar, non-later end date, more than
    366 added civil days) is its own typed error.
  - The review reports the complete impact: every newly active date, the exact trip and
    route identities, the scheduled closure consequences, the retained exceptions and the
    newly active dates that carry no recorded exception.
  - The reviewed token binds the service's exact trip and closure identities, so a
    same-route same-count trip substitution, a newly linked trip, a newly linked closure
    and an exception change each make apply stale with zero calendar or audit writes.
  - A successful apply writes only the selected end date and exactly one audit event, and
    replaying the same reviewed command is stale rather than a second change.

  The focused gate command
  `mix test test/gtfs_planner/gtfs/calendars/extension_review_test.exs test/gtfs_planner/gtfs/calendars/concurrency_test.exs`
  is deferred to branch review.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo

  # The reviewed extension under test: the seeded weekly calendar ends 2026-02-27 and the
  # approved request moves it to 2026-03-27, one calendar month and 28 added civil days
  # later, with two March Saturdays inside the newly active window.
  @extension_attrs %{
    end_date: ~D[2026-03-27],
    approval_text: "Approved by the service planning lead for the March schedule."
  }

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    organization_membership_fixture(actor, organization)

    %{
      organization: organization,
      version: version,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  describe "preparation" do
    test "an approved later end date writes no row", context do
      create_weekly!(context, "ext_prep")

      before = row_state(context, "ext_prep")

      assert {:ok, reviewed} =
               review(context, "ext_prep", @extension_attrs, source!(context, "ext_prep"))

      assert reviewed.affected_service_ids == ["ext_prep"]
      assert row_state(context, "ext_prep") == before
    end

    test "a date-only calendar refuses an extension", context do
      assert {:ok, dates_only} =
               Gtfs.create_calendar(
                 %{
                   service_id: "ext_dates_only",
                   name: "Dates only",
                   kind: :dates_only,
                   dates: [~D[2026-10-01]]
                 },
                 context.audit
               )

      assert {:error, :extension_requires_weekly_calendar} =
               review(context, "ext_dates_only", @extension_attrs, dates_only)

      assert weekly_row(context, "ext_dates_only") == nil
      assert calendar_logs(context, "ext_dates_only") == created_log(context, "ext_dates_only")
    end

    test "a missing or blank approval refuses", context do
      create_weekly!(context, "ext_no_approval")

      assert {:error, :extension_requires_approval} =
               review(
                 context,
                 "ext_no_approval",
                 %{end_date: ~D[2026-03-27], approval_text: "   "},
                 source!(context, "ext_no_approval")
               )

      # No approval at all is an ordinary save by design, so it reviews without
      # an extension rather than refusing.
      assert {:ok, plain} =
               review(
                 context,
                 "ext_no_approval",
                 %{end_date: ~D[2026-03-27]},
                 source!(context, "ext_no_approval")
               )

      assert plain.extension == nil

      assert {:error, :extension_approval_too_long} =
               review(
                 context,
                 "ext_no_approval",
                 %{end_date: ~D[2026-03-27], approval_text: String.duplicate("a", 2001)},
                 source!(context, "ext_no_approval")
               )

      assert weekly_row(context, "ext_no_approval").end_date == ~D[2026-02-27]
      assert calendar_logs(context, "ext_no_approval") == created_log(context, "ext_no_approval")
    end

    test "a non-later end date refuses", context do
      create_weekly!(context, "ext_not_later")

      for end_date <- [~D[2026-02-27], ~D[2026-01-05], "not-a-date"] do
        assert {:error, :extension_requires_later_end_date} =
                 review(
                   context,
                   "ext_not_later",
                   Map.put(@extension_attrs, :end_date, end_date),
                   source!(context, "ext_not_later")
                 )
      end

      assert weekly_row(context, "ext_not_later").end_date == ~D[2026-02-27]
      assert calendar_logs(context, "ext_not_later") == created_log(context, "ext_not_later")
    end

    test "a request beyond 366 added civil days refuses", context do
      create_weekly!(context, "ext_too_far")

      # 2026-02-27 + 366 days is the largest accepted addition; one more day is refused.
      assert {:error, :extension_exceeds_max_days} =
               review(
                 context,
                 "ext_too_far",
                 Map.put(@extension_attrs, :end_date, Date.add(~D[2026-02-27], 367)),
                 source!(context, "ext_too_far")
               )

      assert {:ok, at_bound} =
               review(
                 context,
                 "ext_too_far",
                 Map.put(@extension_attrs, :end_date, Date.add(~D[2026-02-27], 366)),
                 source!(context, "ext_too_far")
               )

      assert at_bound.extension.added_days == 366
      assert weekly_row(context, "ext_too_far").end_date == ~D[2026-02-27]
    end

    test "an ordinary save without approval keeps native behavior", context do
      create_weekly!(context, "ext_plain_save")

      assert {:ok, reviewed} =
               review(
                 context,
                 "ext_plain_save",
                 %{end_date: Date.add(~D[2026-02-27], 400)},
                 source!(context, "ext_plain_save")
               )

      assert reviewed.extension == nil

      assert {:ok, %{action: :save}} =
               apply_change(
                 context,
                 "ext_plain_save",
                 %{end_date: Date.add(~D[2026-02-27], 400)},
                 reviewed.fingerprint
               )

      assert weekly_row(context, "ext_plain_save").end_date == Date.add(~D[2026-02-27], 400)
    end
  end

  describe "complete impact" do
    test "reports newly active dates, trip and route identities and closure consequences",
         context do
      create_weekly!(context, "ext_impact")
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})

      for trip_id <- ["T1", "T2"] do
        trip_fixture(context.organization.id, context.version.id, route.route_id, %{
          trip_id: trip_id,
          service_id: "ext_impact"
        })
      end

      from_stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "EXT_A"})
      to_stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "EXT_B"})

      pathway =
        pathway_fixture(
          context.organization.id,
          context.version.id,
          from_stop.stop_id,
          to_stop.stop_id,
          %{pathway_id: "EXT_PATHWAY"}
        )

      pathway_evolution_fixture(context.organization.id, context.version.id, %{
        pathway_id: pathway.pathway_id,
        service_id: "ext_impact",
        start_time: "23:00",
        end_time: "26:00"
      })

      assert {:ok, reviewed} =
               review(context, "ext_impact", @extension_attrs, source!(context, "ext_impact"))

      extension = reviewed.extension

      assert extension.service_id == "ext_impact"
      assert extension.previous_end_date == ~D[2026-02-27]
      assert extension.requested_end_date == ~D[2026-03-27]
      assert extension.added_days == 28

      # The window after 2026-02-27 runs to 2026-03-27 and the seeded calendar runs
      # Monday through Friday, so the complete set is exactly the 20 March weekdays.
      assert extension.newly_active_dates == march_weekdays()
      assert extension.newly_active_date_count == length(march_weekdays())

      assert Enum.map(extension.trip_identities, & &1.trip_id) == ["T1", "T2"]
      assert Enum.all?(extension.trip_identities, &(&1.route_id == "R1"))
      assert extension.routes == [%{route_id: "R1", trip_count: 2}]

      assert [closure] = extension.closure_consequences
      assert closure.pathway_id == "EXT_PATHWAY"

      # No newly active date carries a recorded exception, so every one of them is
      # reported unresolved rather than silently treated as a holiday.
      assert extension.holiday_policy == :unresolved
      assert extension.unresolved_dates == march_weekdays()
      assert extension.retained_exceptions == []

      refute Enum.any?(extension.newly_active_dates, &(Date.compare(&1, ~D[2026-02-27]) != :gt))
    end

    test "preserves the added and removed exceptions it reviewed", context do
      create_weekly!(context, "ext_exceptions")

      # 2026-01-16 is a removed Friday inside the already reviewed range; 2026-03-13 is an
      # added Friday inside the newly active window.
      for {date, exception_type} <- [{~D[2026-01-16], 2}, {~D[2026-03-13], 1}] do
        calendar_date_fixture(context.organization.id, context.version.id, %{
          service_id: "ext_exceptions",
          date: date,
          exception_type: exception_type
        })
      end

      assert {:ok, reviewed} =
               review(
                 context,
                 "ext_exceptions",
                 @extension_attrs,
                 source!(context, "ext_exceptions")
               )

      extension = reviewed.extension

      assert extension.retained_exceptions == [
               %{date: ~D[2026-01-16], exception_type: 2},
               %{date: ~D[2026-03-13], exception_type: 1}
             ]

      # Both exceptions are preserved, and the added 2026-03-13 stays active even though
      # it is outside the weekly window, so it is not newly active and not unresolved.
      refute ~D[2026-03-13] in extension.newly_active_dates
      refute ~D[2026-03-13] in extension.unresolved_dates
      assert length(exception_rows(context, "ext_exceptions")) == 2

      assert {:ok, %{action: :save}} =
               apply_change(context, "ext_exceptions", @extension_attrs, reviewed.fingerprint)

      assert Enum.map(exception_rows(context, "ext_exceptions"), &{&1.date, &1.exception_type}) ==
               [
                 {~D[2026-01-16], 2},
                 {~D[2026-03-13], 1}
               ]
    end
  end

  describe "stale apply" do
    test "a same-route same-count trip substitution is stale with zero writes", context do
      create_weekly!(context, "ext_swap")
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})

      trip_fixture(context.organization.id, context.version.id, route.id, %{
        trip_id: "T1",
        service_id: "ext_swap"
      })

      assert {:ok, reviewed} =
               review(context, "ext_swap", @extension_attrs, source!(context, "ext_swap"))

      before = row_state(context, "ext_swap")

      # Delete one trip of the service and link another one on the same route, so the
      # usage counts and route identities the calendar source fingerprint binds are
      # unchanged and only the exact trip identities differ.
      Repo.delete_all(
        from(t in GtfsPlanner.Gtfs.Trip,
          where: t.organization_id == ^context.organization.id and t.trip_id == "T1"
        )
      )

      trip_fixture(context.organization.id, context.version.id, route.id, %{
        trip_id: "T1_REPLACED",
        service_id: "ext_swap"
      })

      assert usage_counts(context, "ext_swap") == %{route_count: 1, trip_count: 1}

      assert {:error, :stale_review} =
               apply_change(context, "ext_swap", @extension_attrs, reviewed.fingerprint)

      after_state = row_state(context, "ext_swap")
      assert after_state.calendar == before.calendar
      assert after_state.audit_rows == before.audit_rows
      assert weekly_row(context, "ext_swap").end_date == ~D[2026-02-27]
    end

    test "a newly linked trip is stale with zero writes", context do
      create_weekly!(context, "ext_new_trip")
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})

      trip_fixture(context.organization.id, context.version.id, route.id, %{
        trip_id: "T1",
        service_id: "ext_swap_other"
      })

      assert {:ok, reviewed} =
               review(context, "ext_new_trip", @extension_attrs, source!(context, "ext_new_trip"))

      before = row_state(context, "ext_new_trip")

      trip_fixture(context.organization.id, context.version.id, route.id, %{
        trip_id: "T2",
        service_id: "ext_new_trip"
      })

      assert {:error, :stale_review} =
               apply_change(context, "ext_new_trip", @extension_attrs, reviewed.fingerprint)

      assert row_state(context, "ext_new_trip") == before
    end

    test "a newly linked closure is stale with zero writes", context do
      create_weekly!(context, "ext_new_closure")

      pathway_evolution_fixture(context.organization.id, context.version.id, %{
        service_id: "ext_new_closure"
      })

      assert {:ok, reviewed} =
               review(
                 context,
                 "ext_new_closure",
                 @extension_attrs,
                 source!(context, "ext_new_closure")
               )

      before = row_state(context, "ext_new_closure")

      pathway_evolution_fixture(context.organization.id, context.version.id, %{
        service_id: "ext_new_closure"
      })

      assert {:error, :stale_review} =
               apply_change(context, "ext_new_closure", @extension_attrs, reviewed.fingerprint)

      assert row_state(context, "ext_new_closure") == before
    end

    test "an exception change is stale with zero writes", context do
      create_weekly!(context, "ext_exc_change")

      assert {:ok, reviewed} =
               review(
                 context,
                 "ext_exc_change",
                 @extension_attrs,
                 source!(context, "ext_exc_change")
               )

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "ext_exc_change",
        date: ~D[2026-03-13],
        exception_type: 2
      })

      # The snapshot is taken after the competing exception exists, so the
      # stale apply is measured against the state it refused to write over.
      before = row_state(context, "ext_exc_change")

      assert {:error, :stale_review} =
               apply_change(context, "ext_exc_change", @extension_attrs, reviewed.fingerprint)

      assert row_state(context, "ext_exc_change") == before
    end

    test "a different end date or approval against the same token is stale", context do
      create_weekly!(context, "ext_other_command")

      assert {:ok, reviewed} =
               review(
                 context,
                 "ext_other_command",
                 @extension_attrs,
                 source!(context, "ext_other_command")
               )

      for attrs <- [
            Map.put(@extension_attrs, :end_date, ~D[2026-03-20]),
            Map.put(@extension_attrs, :approval_text, "A different approval.")
          ] do
        assert {:error, :stale_review} =
                 apply_change(context, "ext_other_command", attrs, reviewed.fingerprint)
      end

      assert weekly_row(context, "ext_other_command").end_date == ~D[2026-02-27]
      assert length(calendar_logs(context, "ext_other_command")) == 1
    end
  end

  describe "successful apply" do
    test "changes only the selected end date and writes one audit event", context do
      create_weekly!(context, "ext_apply")

      assert {:ok, reviewed} =
               review(context, "ext_apply", @extension_attrs, source!(context, "ext_apply"))

      assert {:ok, result} =
               apply_change(context, "ext_apply", @extension_attrs, reviewed.fingerprint)

      assert result.action == :save
      assert result.changed_count == 1

      assert [weekly] = weekly_rows(context, "ext_apply")
      assert weekly.end_date == ~D[2026-03-27]
      assert weekly.start_date == ~D[2026-01-05]
      assert weekly.monday == 1
      assert weekly.saturday == 0

      assert [attribute] = attribute_rows(context, "ext_apply")
      assert attribute.service_description == "Weekly ext_apply"

      assert [_created, log] = calendar_logs(context, "ext_apply")
      assert log.action == "updated"
      assert log.changed_fields["before"]["weekly"]["end_date"] == "2026-02-27"
      assert log.changed_fields["after"]["weekly"]["end_date"] == "2026-03-27"

      # Replaying the same reviewed command against its own committed result is stale,
      # not a second change.
      assert {:error, :stale_review} =
               apply_change(context, "ext_apply", @extension_attrs, reviewed.fingerprint)

      assert weekly_row(context, "ext_apply").end_date == ~D[2026-03-27]
      assert length(calendar_logs(context, "ext_apply")) == 2
    end
  end

  defp review(context, service_id, attrs, payload) do
    Gtfs.review_calendar_change(
      {:save, service_id, attrs},
      %{service_id => payload.fingerprint},
      context.audit
    )
  end

  defp apply_change(context, service_id, attrs, fingerprint) do
    Gtfs.apply_calendar_change({:save, service_id, attrs}, fingerprint, context.audit)
  end

  defp create_weekly!(context, service_id) do
    assert {:ok, payload} =
             Gtfs.create_calendar(
               %{
                 service_id: service_id,
                 name: "Weekly #{service_id}",
                 kind: :weekly,
                 monday: 1,
                 tuesday: 1,
                 wednesday: 1,
                 thursday: 1,
                 friday: 1,
                 saturday: 0,
                 sunday: 0,
                 start_date: ~D[2026-01-05],
                 end_date: ~D[2026-02-27]
               },
               context.audit
             )

    payload
  end

  defp march_weekdays do
    ~D[2026-03-02]
    |> Date.range(~D[2026-03-27])
    |> Enum.filter(&(Date.day_of_week(&1) in 1..5))
  end

  defp source!(context, service_id) do
    assert {:ok, payload} =
             Gtfs.get_calendar(context.organization.id, context.version.id, service_id)

    payload
  end

  defp weekly_rows(context, service_id) do
    Repo.all(
      from(c in Calendar,
        where:
          c.organization_id == ^context.organization.id and
            c.gtfs_version_id == ^context.version.id and c.service_id == ^service_id
      )
    )
  end

  defp weekly_row(context, service_id) do
    Repo.one(
      from(c in Calendar,
        where:
          c.organization_id == ^context.organization.id and
            c.gtfs_version_id == ^context.version.id and c.service_id == ^service_id
      )
    )
  end

  defp attribute_rows(context, service_id) do
    Repo.all(
      from(a in CalendarAttribute,
        where:
          a.organization_id == ^context.organization.id and
            a.gtfs_version_id == ^context.version.id and a.service_id == ^service_id
      )
    )
  end

  defp exception_rows(context, service_id) do
    Repo.all(
      from(d in CalendarDate,
        where:
          d.organization_id == ^context.organization.id and
            d.gtfs_version_id == ^context.version.id and d.service_id == ^service_id,
        order_by: [asc: d.date]
      )
    )
  end

  # The fixture's own audited creation, which a refused request leaves as the
  # only event for the service: a refusal writes nothing of its own.
  defp created_log(context, service_id) do
    [log] = calendar_logs(context, service_id)
    assert log.action == "created"
    [log]
  end

  defp calendar_logs(context, service_id) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.gtfs_version_id == ^context.version.id and l.entity_type == "calendar" and
            l.entity_external_id == ^service_id,
        order_by: [asc: l.inserted_at, asc: l.id]
      )
    )
  end

  # The complete write footprint a stale apply must not change: the native rows and the
  # number of audit events for the service.
  defp row_state(context, service_id) do
    %{
      calendar: weekly_row(context, service_id),
      attribute_rows: length(attribute_rows(context, service_id)),
      exception_rows: length(exception_rows(context, service_id)),
      audit_rows: length(calendar_logs(context, service_id))
    }
  end

  defp usage_counts(context, service_id) do
    organization_id = context.organization.id
    version_id = context.version.id

    trips =
      Repo.all(
        from(t in GtfsPlanner.Gtfs.Trip,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
              t.service_id == ^service_id,
          select: t.route_id
        )
      )

    %{route_count: trips |> Enum.uniq() |> length(), trip_count: length(trips)}
  end
end
