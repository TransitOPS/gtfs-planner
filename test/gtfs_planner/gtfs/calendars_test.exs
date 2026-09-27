defmodule GtfsPlanner.Gtfs.CalendarsTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "unified scoped reads" do
    test "the facade and configured Repo adapter return one identity per union source", context do
      route_a = route_fixture(context.organization.id, context.version.id, %{route_id: "r_a"})
      route_b = route_fixture(context.organization.id, context.version.id, %{route_id: "r_b"})

      create_weekly!(context, %{service_id: "svc_weekly", name: "Weekday"})

      create_weekly!(context, %{
        service_id: "svc_spring",
        name: "Spring Extra",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 0,
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-01-10]
      })

      create_dates_only!(context, %{
        service_id: "svc_holiday",
        name: "Holiday Shuttle",
        dates: [~D[2026-07-04]]
      })

      calendar_attribute_fixture(context.organization.id, context.version.id, %{
        service_id: "svc_meta",
        service_description: "Metadata Only"
      })

      trip_fixture(context.organization.id, context.version.id, route_a.route_id, %{
        service_id: "svc_weekly"
      })

      trip_fixture(context.organization.id, context.version.id, route_b.route_id, %{
        service_id: "svc_weekly"
      })

      trip_fixture(context.organization.id, context.version.id, route_b.route_id, %{
        service_id: "svc_weekly"
      })

      assert {:ok, summaries} =
               Gtfs.load_calendar_catalog(context.organization.id, context.version.id,
                 today: ~D[2026-01-15]
               )

      assert Enum.map(summaries, & &1.service_id) == [
               "svc_holiday",
               "svc_meta",
               "svc_spring",
               "svc_weekly"
             ]

      summary = Enum.find(summaries, &(&1.service_id == "svc_weekly"))
      assert summary.kind == :weekly
      assert %Calendar{} = summary.calendar
      assert %CalendarAttribute{} = summary.attributes
      assert summary.name == "Weekday"
      assert summary.trip_count == 3
      assert summary.first_active_date == ~D[2026-01-05]
      assert summary.last_active_date == ~D[2026-02-27]
      assert summary.warnings == []
      assert is_binary(summary.fingerprint)
      assert byte_size(summary.fingerprint) == 64

      spring = Enum.find(summaries, &(&1.service_id == "svc_spring"))
      assert spring.first_active_date == ~D[2026-01-10]
      assert spring.last_active_date == ~D[2026-01-10]
      assert spring.trip_count == 0

      holiday = Enum.find(summaries, &(&1.service_id == "svc_holiday"))
      assert holiday.kind == :dates_only
      assert holiday.calendar == nil
      assert holiday.first_active_date == ~D[2026-07-04]
      assert holiday.last_active_date == ~D[2026-07-04]

      meta = Enum.find(summaries, &(&1.service_id == "svc_meta"))
      assert meta.kind == :dates_only
      assert meta.calendar == nil
      assert meta.attributes.service_description == "Metadata Only"
      assert meta.trip_count == 0
      assert meta.first_active_date == nil
      assert meta.last_active_date == nil
      assert [%{reason: :no_service}] = meta.warnings

      assert {:ok, usage} =
               Gtfs.calendar_usage(context.organization.id, context.version.id, "svc_weekly")

      assert usage.service_id == "svc_weekly"
      assert usage.trip_count == 3
      assert usage.route_ids == ["r_a", "r_b"]

      assert usage.routes == [
               %{route_id: "r_a", trip_count: 1},
               %{route_id: "r_b", trip_count: 2}
             ]

      assert {:ok, payload} =
               Gtfs.fetch_calendar(context.organization.id, context.version.id, "svc_weekly")

      assert payload.fingerprint == summary.fingerprint
      assert payload.exceptions == []
      assert payload.calendar.service_id == "svc_weekly"

      assert {:ok, again} =
               Gtfs.load_calendar_catalog(context.organization.id, context.version.id,
                 today: ~D[2026-01-15]
               )

      assert Enum.map(again, & &1.fingerprint) == Enum.map(summaries, & &1.fingerprint)

      assert Repo.aggregate(
               from(c in Calendar, where: c.gtfs_version_id == ^context.version.id),
               :count
             ) == 2

      assert Repo.aggregate(
               from(a in CalendarAttribute, where: a.gtfs_version_id == ^context.version.id),
               :count
             ) == 4

      assert Repo.aggregate(
               from(l in ChangeLog, where: l.gtfs_version_id == ^context.version.id),
               :count
             ) == 3
    end

    test "reads insert no metadata for an imported native-only service", context do
      calendar_fixture(context.organization.id, context.version.id, %{service_id: "imported"})

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "imported",
        date: ~D[2026-01-10],
        exception_type: 2
      })

      assert {:ok, [summary]} =
               Gtfs.list_calendars(context.organization.id, context.version.id, [])

      assert summary.attributes == nil
      assert summary.name == nil
      assert summary.first_active_date == ~D[2026-01-01]

      refute Repo.exists?(
               from(a in CalendarAttribute,
                 where: a.gtfs_version_id == ^context.version.id
               )
             )

      refute Repo.exists?(from(l in ChangeLog, where: l.gtfs_version_id == ^context.version.id))
    end

    test "invalid, foreign and unpublished scopes return not_found without foreign data",
         context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      calendar_fixture(other_organization.id, other_version.id, %{service_id: "foreign"})

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      assert {:error, :not_found} =
               Gtfs.list_calendars(context.organization.id, other_version.id, [])

      assert {:error, :not_found} =
               Gtfs.get_calendar(context.organization.id, other_version.id, "foreign")

      assert {:error, :not_found} =
               Gtfs.get_calendar(context.organization.id, context.version.id, "missing")

      assert {:error, :not_found} =
               Gtfs.get_calendar(context.organization.id, context.version.id, "")

      assert {:error, :not_found} = Gtfs.get_calendar("not-a-uuid", context.version.id, "svc")
      assert {:error, :not_found} = Gtfs.list_calendars("not-a-uuid", context.version.id, [])
      assert {:error, :not_found} = Gtfs.list_calendars(context.organization.id, "nope", [])
      assert {:error, :not_found} = Gtfs.fetch_calendar(context.organization.id, "nope", "svc")

      assert {:error, :not_found} =
               Gtfs.calendar_usage(context.organization.id, context.version.id, "missing")

      assert {:error, :not_found} =
               Gtfs.feed_service_gaps(context.organization.id, "nope", ~D[2026-01-01])

      assert {:error, :not_found} = Gtfs.list_calendars(context.organization.id, staging.id, [])

      assert {:error, :not_found} =
               Gtfs.load_calendar_catalog(context.organization.id, staging.id, [])
    end
  end

  describe "agency-local dates" do
    test "a resolved agency zone localizes a fixed UTC instant to the right civil date",
         context do
      agency_fixture(context.organization.id, context.version.id, %{
        agency_timezone: "America/Los_Angeles"
      })

      resolution = DisplayClock.resolve_zone(context.organization.id, context.version.id)
      refute resolution.fallback?
      assert resolution.timezone == "America/Los_Angeles"

      assert DisplayClock.local_date(~U[2026-11-26 02:30:00Z], resolution) == ~D[2026-11-25]
      assert DisplayClock.local_date(~U[2026-11-26 09:30:00Z], resolution) == ~D[2026-11-26]
    end

    test "missing, invalid and conflicting zones disclose a UTC fallback", context do
      resolution = DisplayClock.resolve_zone(context.organization.id, context.version.id)
      assert resolution == %{timezone: "UTC", fallback?: true, fallback_reason: :missing}
      assert DisplayClock.local_date(~U[2026-11-26 02:30:00Z], resolution) == ~D[2026-11-26]

      agency_fixture(context.organization.id, context.version.id, %{
        agency_timezone: "Not/AZone"
      })

      assert %{timezone: "UTC", fallback?: true, fallback_reason: :invalid} =
               DisplayClock.resolve_zone(context.organization.id, context.version.id)

      agency_fixture(context.organization.id, context.version.id, %{
        agency_timezone: "America/New_York"
      })

      assert %{timezone: "UTC", fallback?: true, fallback_reason: :conflicting} =
               DisplayClock.resolve_zone(context.organization.id, context.version.id)
    end

    test "today resolves the scope's agency-calendar date", context do
      agency_fixture(context.organization.id, context.version.id, %{
        agency_timezone: "Pacific/Auckland"
      })

      assert %{date: %Date{}, timezone: "Pacific/Auckland", fallback?: false} =
               DisplayClock.today(context.organization.id, context.version.id)
    end

    test "list warnings follow the supplied agency-local today", context do
      create_weekly!(context, %{
        service_id: "svc_soon",
        name: "Ends Soon",
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-01-19]
      })

      assert {:ok, [summary]} =
               Gtfs.list_calendars(context.organization.id, context.version.id,
                 today: ~D[2026-01-10]
               )

      assert [%{reason: :ends_soon, days_remaining: 9, last_date: ~D[2026-01-19]}] =
               Enum.filter(summary.warnings, &match?(%{reason: :ends_soon}, &1))

      assert {:ok, [ended]} =
               Gtfs.list_calendars(context.organization.id, context.version.id,
                 today: ~D[2026-01-20]
               )

      assert Enum.any?(ended.warnings, &match?(%{reason: :ended}, &1))
    end
  end

  describe "feed service gaps" do
    test "a full weekday and weekend pair has no gaps", context do
      create_weekly!(context, %{
        service_id: "wk",
        name: "Weekday",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-01-11]
      })

      create_weekly!(context, %{
        service_id: "we",
        name: "Weekend",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 1,
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-01-11]
      })

      assert {:ok, []} =
               Gtfs.feed_service_gaps(context.organization.id, context.version.id, ~D[2026-01-05])
    end

    test "the gap is the maximal missing civil-date run inside the effective span", context do
      create_weekly!(context, %{
        service_id: "wk3",
        name: "Weekday",
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-01-23]
      })

      assert {:ok, gaps} =
               Gtfs.feed_service_gaps(context.organization.id, context.version.id, ~D[2026-01-05])

      assert gaps == [
               %{first_date: ~D[2026-01-10], last_date: ~D[2026-01-11]},
               %{first_date: ~D[2026-01-17], last_date: ~D[2026-01-18]}
             ]
    end

    test "a single-span service has no gaps and an empty feed has none either", context do
      create_weekly!(context, %{
        service_id: "wk1",
        name: "One Week",
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-01-09]
      })

      calendar_attribute_fixture(context.organization.id, context.version.id, %{
        service_id: "svc_meta",
        service_description: "Unused"
      })

      assert {:ok, []} =
               Gtfs.feed_service_gaps(context.organization.id, context.version.id, ~D[2026-01-05])

      empty_organization = organization_fixture()
      empty_version = gtfs_version_fixture(empty_organization.id)

      assert {:ok, []} =
               Gtfs.feed_service_gaps(empty_organization.id, empty_version.id, ~D[2026-01-05])
    end

    test "an outside addition extends the span by its own date only", context do
      create_weekly!(context, %{
        service_id: "wk2",
        name: "Two Weeks",
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-01-16]
      })

      create_dates_only!(context, %{
        service_id: "svc_extra",
        name: "Extra Day",
        dates: [~D[2026-01-24]]
      })

      assert {:ok, gaps} =
               Gtfs.feed_service_gaps(context.organization.id, context.version.id, ~D[2026-01-05])

      # The addition moves the span end to 2026-01-24, so the uncovered weekend
      # and the uncovered week after the weekly range are both gaps.
      assert gaps == [
               %{first_date: ~D[2026-01-10], last_date: ~D[2026-01-11]},
               %{first_date: ~D[2026-01-17], last_date: ~D[2026-01-23]}
             ]
    end
  end

  describe "create" do
    test "a weekly create writes the weekly row, anchor and one created audit", context do
      assert {:ok, result} =
               Gtfs.create_calendar(
                 %{
                   service_id: "wk1",
                   name: "  School Weekday  ",
                   kind: :weekly,
                   monday: 1,
                   tuesday: 1,
                   wednesday: 1,
                   thursday: 1,
                   friday: 1,
                   saturday: 0,
                   sunday: 0,
                   start_date: "2026-01-05",
                   end_date: "2026-02-27",
                   service_schedule_name: "School",
                   service_schedule_type: "Weekday",
                   service_schedule_typicality: 6,
                   rating_start_date: "2026-01-05",
                   rating_end_date: "2026-06-30",
                   rating_description: "Spring rating"
                 },
                 context.audit
               )

      assert result.service_id == "wk1"
      assert result.calendar.organization_id == context.organization.id
      assert result.calendar.gtfs_version_id == context.version.id
      assert result.calendar.monday == 1
      assert result.calendar.saturday == 0
      assert result.calendar.start_date == ~D[2026-01-05]
      assert result.attributes.service_description == "School Weekday"
      assert result.attributes.service_schedule_typicality == 6
      assert result.attributes.rating_end_date == ~D[2026-06-30]
      assert result.exceptions == []

      assert [log] = logs_for(context.version, "wk1")
      assert log.action == "created"
      assert log.entity_type == "calendar"
      assert log.entity_external_id == "wk1"
      assert log.entity_id == result.attributes.id
      assert log.station_stop_id == nil
      assert log.actor_id == context.actor.id
      assert log.actor_email == context.actor.email
      assert log.changed_fields["before"] == nil
      assert log.changed_fields["after"]["kind"] == "weekly"
      assert log.changed_fields["after"]["name"] == "School Weekday"
      assert log.changed_fields["after"]["weekly"]["start_date"] == "2026-01-05"
      assert log.changed_fields["after"]["weekly"]["monday"] == 1
      assert log.changed_fields["after"]["dates"] == []
    end

    test "a dates-only create adds exceptions and no synthetic weekly row", context do
      assert {:ok, result} =
               Gtfs.create_calendar(
                 %{
                   service_id: "dt1",
                   name: "Holiday Shuttle",
                   kind: :dates_only,
                   dates: ["2026-07-05", ~D[2026-07-04], "2026-07-04"]
                 },
                 context.audit
               )

      assert result.service_id == "dt1"
      assert result.calendar == nil
      assert Enum.map(result.exceptions, & &1.date) == [~D[2026-07-04], ~D[2026-07-05]]
      assert Enum.all?(result.exceptions, &(&1.exception_type == 1))

      refute Repo.exists?(from(c in Calendar, where: c.gtfs_version_id == ^context.version.id))

      assert Repo.exists?(
               from(a in CalendarAttribute,
                 where: a.gtfs_version_id == ^context.version.id and a.service_id == "dt1"
               )
             )

      assert [log] = logs_for(context.version, "dt1")
      assert log.changed_fields["after"]["kind"] == "dates_only"
      assert log.changed_fields["after"]["weekly"] == nil

      assert log.changed_fields["after"]["dates"] == [
               %{"date" => "2026-07-04", "exception_type" => 1},
               %{"date" => "2026-07-05", "exception_type" => 1}
             ]
    end

    test "the union identity check covers weekly, exception-only and metadata-only services",
         context do
      create_weekly!(context, %{service_id: "taken_weekly", name: "Taken Weekly"})
      create_dates_only!(context, %{service_id: "taken_dates", name: "Taken Dates"})

      calendar_attribute_fixture(context.organization.id, context.version.id, %{
        service_id: "taken_meta",
        service_description: "Taken Metadata"
      })

      for service_id <- ["taken_weekly", "taken_dates", "taken_meta"] do
        assert {:error, %Ecto.Changeset{errors: errors}} =
                 Gtfs.create_calendar(
                   %{
                     service_id: service_id,
                     name: "New #{service_id}",
                     kind: :dates_only,
                     dates: [~D[2026-03-01]]
                   },
                   context.audit
                 )

        assert Keyword.has_key?(errors, :service_id)
      end
    end

    test "interactive validation requires a trimmed unique name, a weekday and ordered dates",
         context do
      create_weekly!(context, %{service_id: "existing", name: "Existing"})

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.create_calendar(
                 %{service_id: "blank", name: "   ", kind: :dates_only, dates: [~D[2026-03-01]]},
                 context.audit
               )

      assert Keyword.has_key?(errors, :service_description)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.create_calendar(
                 %{
                   service_id: "dup_name",
                   name: " existing\n",
                   kind: :dates_only,
                   dates: [~D[2026-03-01]]
                 },
                 context.audit
               )

      assert Keyword.has_key?(errors, :service_description)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.create_calendar(
                 %{
                   service_id: "no_days",
                   name: "No Days",
                   kind: :weekly,
                   monday: 0,
                   tuesday: 0,
                   wednesday: 0,
                   thursday: 0,
                   friday: 0,
                   saturday: 0,
                   sunday: 0,
                   start_date: ~D[2026-01-05],
                   end_date: ~D[2026-01-09]
                 },
                 context.audit
               )

      assert Keyword.has_key?(errors, :service_days)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.create_calendar(
                 %{
                   service_id: "reversed",
                   name: "Reversed",
                   kind: :weekly,
                   monday: 1,
                   tuesday: 0,
                   wednesday: 0,
                   thursday: 0,
                   friday: 0,
                   saturday: 0,
                   sunday: 0,
                   start_date: ~D[2026-02-01],
                   end_date: ~D[2026-01-01]
                 },
                 context.audit
               )

      assert Keyword.has_key?(errors, :end_date)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.create_calendar(
                 %{
                   service_id: "bad_kind",
                   name: "Bad Kind",
                   kind: :monthly,
                   dates: [~D[2026-03-01]]
                 },
                 context.audit
               )

      assert Keyword.has_key?(errors, :kind)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.create_calendar(
                 %{service_id: "no_dates", name: "No Dates", kind: :dates_only, dates: []},
                 context.audit
               )

      assert Keyword.has_key?(errors, :dates)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.create_calendar(
                 %{
                   service_id: "bad_date",
                   name: "Bad Date",
                   kind: :dates_only,
                   dates: ["2026-13-01"]
                 },
                 context.audit
               )

      assert Keyword.has_key?(errors, :dates)

      assert {:error, :invalid_input} = Gtfs.create_calendar(%{}, context.audit)
      assert {:error, :invalid_input} = Gtfs.create_calendar("nope", context.audit)

      refute Repo.exists?(
               from(a in CalendarAttribute,
                 where:
                   a.gtfs_version_id == ^context.version.id and
                     a.service_id in [
                       "blank",
                       "dup_name",
                       "no_days",
                       "reversed",
                       "bad_kind",
                       "no_dates",
                       "bad_date"
                     ]
               )
             )
    end
  end

  describe "duplicate" do
    @tag :duplication
    test "duplicating a weekly calendar copies its rows and metadata without trips", context do
      source = create_weekly!(context, %{service_id: "src_wk", name: "Weekday"})

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "src_wk",
        date: ~D[2026-01-10],
        exception_type: 1
      })

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "src_wk",
        date: ~D[2026-01-07],
        exception_type: 2
      })

      route = route_fixture(context.organization.id, context.version.id)

      trip_fixture(context.organization.id, context.version.id, route.route_id, %{
        service_id: "src_wk"
      })

      before_source = table_state(context, "src_wk")
      before_logs = logs_for(context.version, "src_wk")

      assert {:ok, copy} = Gtfs.duplicate_calendar("src_wk", %{}, context.audit)

      assert copy.service_id == "src_wk_copy"
      assert copy.attributes.service_description == "Weekday (copy)"
      assert copy.calendar.monday == 1
      assert copy.calendar.start_date == ~D[2026-01-05]
      assert copy.calendar.id != source.calendar.id
      assert copy.attributes.id != source.attributes.id

      assert Enum.map(copy.exceptions, &{&1.date, &1.exception_type}) == [
               {~D[2026-01-07], 2},
               {~D[2026-01-10], 1}
             ]

      assert {:ok, usage} =
               Gtfs.calendar_usage(context.organization.id, context.version.id, "src_wk_copy")

      assert usage.trip_count == 0
      assert usage.route_ids == []

      assert table_state(context, "src_wk") == before_source
      assert length(logs_for(context.version, "src_wk")) == length(before_logs)

      assert [copy_log] = logs_for(context.version, "src_wk_copy")
      assert copy_log.action == "created"
      assert copy_log.changed_fields["before"] == nil
      assert copy_log.changed_fields["after"]["name"] == "Weekday (copy)"
      assert copy_log.entity_external_id == "src_wk_copy"
    end

    @tag :duplication
    test "duplicate suffixes advance through existing service ID and name collisions", context do
      create_weekly!(context, %{service_id: "dup", name: "Weekday"})
      create_weekly!(context, %{service_id: "dup_copy", name: "Weekday (copy)"})

      assert {:ok, second} = Gtfs.duplicate_calendar("dup", %{}, context.audit)
      assert second.service_id == "dup_copy_2"
      assert second.attributes.service_description == "Weekday (copy 2)"

      assert {:ok, third} = Gtfs.duplicate_calendar("dup", %{}, context.audit)
      assert third.service_id == "dup_copy_3"
      assert third.attributes.service_description == "Weekday (copy 3)"
    end

    @tag :duplication
    test "duplicating dates-only and metadata-only calendars keeps their shapes", context do
      create_dates_only!(context, %{
        service_id: "dt_src",
        name: "Shuttle",
        dates: [~D[2026-07-04]]
      })

      calendar_attribute_fixture(context.organization.id, context.version.id, %{
        service_id: "meta_src",
        service_description: "Unused"
      })

      assert {:ok, dates_copy} = Gtfs.duplicate_calendar("dt_src", %{}, context.audit)
      assert dates_copy.service_id == "dt_src_copy"
      assert dates_copy.calendar == nil
      assert Enum.map(dates_copy.exceptions, & &1.date) == [~D[2026-07-04]]

      assert {:ok, metadata_copy} = Gtfs.duplicate_calendar("meta_src", %{}, context.audit)
      assert metadata_copy.service_id == "meta_src_copy"
      assert metadata_copy.calendar == nil
      assert metadata_copy.exceptions == []
      assert metadata_copy.attributes.service_description == "Unused (copy)"

      refute Repo.exists?(
               from(c in Calendar,
                 where:
                   c.gtfs_version_id == ^context.version.id and
                     c.service_id in ["dt_src_copy", "meta_src_copy"]
               )
             )
    end

    @tag :duplication
    test "a missing source and explicit colliding overrides write nothing", context do
      create_weekly!(context, %{service_id: "dup", name: "Weekday"})

      before_logs =
        Repo.aggregate(
          from(l in ChangeLog, where: l.gtfs_version_id == ^context.version.id),
          :count
        )

      assert {:error, :not_found} = Gtfs.duplicate_calendar("missing", %{}, context.audit)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.duplicate_calendar("dup", %{name: " weekday "}, context.audit)

      assert Keyword.has_key?(errors, :service_description)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.duplicate_calendar("dup", %{service_id: "dup"}, context.audit)

      assert Keyword.has_key?(errors, :service_id)

      assert Repo.aggregate(
               from(l in ChangeLog, where: l.gtfs_version_id == ^context.version.id),
               :count
             ) ==
               before_logs
    end
  end

  describe "delete" do
    @tag :deletion
    test "an unused weekly delete removes all three tables with a complete before snapshot",
         context do
      create_weekly!(context, %{service_id: "del_wk", name: "To Delete"})

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "del_wk",
        date: ~D[2026-01-10],
        exception_type: 1
      })

      assert {:ok, payload} =
               Gtfs.get_calendar(context.organization.id, context.version.id, "del_wk")

      assert {:ok, review} =
               Gtfs.review_calendar_change(
                 {:delete, "del_wk"},
                 %{"del_wk" => payload.fingerprint},
                 context.audit
               )

      assert review.affected_service_ids == ["del_wk"]
      assert review.active_date_count == 41
      assert review.warnings == []
      assert is_binary(review.fingerprint)

      assert review.changes == %{
               action: :delete,
               service_id: "del_wk",
               name: "To Delete",
               kind: :weekly,
               trip_count: 0,
               active_date_count: 41,
               exception_count: 1
             }

      assert {:ok, %{service_id: "del_wk", action: :deleted}} =
               Gtfs.apply_calendar_change({:delete, "del_wk"}, review.fingerprint, context.audit)

      assert table_state(context, "del_wk") == %{calendar: [], exceptions: [], attributes: []}

      assert [created_log, deleted_log] = logs_for(context.version, "del_wk")
      assert created_log.action == "created"
      assert deleted_log.action == "deleted"
      assert deleted_log.entity_id == payload.attributes.id
      assert deleted_log.entity_external_id == "del_wk"
      assert deleted_log.changed_fields["after"] == nil

      before = deleted_log.changed_fields["before"]
      assert before["service_id"] == "del_wk"
      assert before["name"] == "To Delete"
      assert before["kind"] == "weekly"
      assert before["weekly"]["monday"] == 1
      assert before["weekly"]["end_date"] == "2026-02-27"
      assert before["attributes"]["service_description"] == "To Delete"
      assert before["dates"] == [%{"date" => "2026-01-10", "exception_type" => 1}]
    end

    @tag :deletion
    test "unused dates-only and metadata-only identities are deleted completely", context do
      create_dates_only!(context, %{
        service_id: "del_dt",
        name: "Shuttle",
        dates: [~D[2026-07-04]]
      })

      calendar_attribute_fixture(context.organization.id, context.version.id, %{
        service_id: "del_meta",
        service_description: "Unused"
      })

      for service_id <- ["del_dt", "del_meta"] do
        assert {:ok, payload} =
                 Gtfs.get_calendar(context.organization.id, context.version.id, service_id)

        assert {:ok, review} =
                 Gtfs.review_calendar_change(
                   {:delete, service_id},
                   %{service_id => payload.fingerprint},
                   context.audit
                 )

        assert {:ok, %{action: :deleted}} =
                 Gtfs.apply_calendar_change(
                   {:delete, service_id},
                   review.fingerprint,
                   context.audit
                 )

        assert table_state(context, service_id) == %{calendar: [], exceptions: [], attributes: []}
      end
    end

    @tag :deletion
    test "a same-scope trip blocks deletion with counts and routes and writes nothing", context do
      create_weekly!(context, %{service_id: "used", name: "Used"})
      route_a = route_fixture(context.organization.id, context.version.id, %{route_id: "ra"})
      route_b = route_fixture(context.organization.id, context.version.id, %{route_id: "rb"})

      trip_fixture(context.organization.id, context.version.id, route_a.route_id, %{
        service_id: "used"
      })

      for _ <- 1..2 do
        trip_fixture(context.organization.id, context.version.id, route_b.route_id, %{
          service_id: "used"
        })
      end

      assert {:ok, payload} =
               Gtfs.get_calendar(context.organization.id, context.version.id, "used")

      before = table_state(context, "used")
      before_logs = logs_for(context.version, "used")

      assert {:error, {:in_use, 3, ["ra", "rb"]}} =
               Gtfs.review_calendar_change(
                 {:delete, "used"},
                 %{"used" => payload.fingerprint},
                 context.audit
               )

      assert table_state(context, "used") == before
      assert logs_for(context.version, "used") == before_logs
    end

    @tag :deletion
    test "foreign-scope trips neither block a delete nor leak", context do
      payload = create_weekly!(context, %{service_id: "shared", name: "Shared"})

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      other_route = route_fixture(other_organization.id, other_version.id)

      trip_fixture(other_organization.id, other_version.id, other_route.route_id, %{
        service_id: "shared"
      })

      assert {:ok, review} =
               Gtfs.review_calendar_change(
                 {:delete, "shared"},
                 %{"shared" => payload.fingerprint},
                 context.audit
               )

      assert review.changes.trip_count == 0

      assert {:ok, %{action: :deleted}} =
               Gtfs.apply_calendar_change({:delete, "shared"}, review.fingerprint, context.audit)

      assert table_state(context, "shared") == %{calendar: [], exceptions: [], attributes: []}

      assert Repo.exists?(
               from(t in Trip,
                 where: t.gtfs_version_id == ^other_version.id and t.service_id == "shared"
               )
             )
    end

    @tag :deletion
    test "a trip added after review invalidates the reviewed delete", context do
      create_weekly!(context, %{service_id: "late_trip", name: "Late Trip"})

      assert {:ok, payload} =
               Gtfs.get_calendar(context.organization.id, context.version.id, "late_trip")

      assert {:ok, review} =
               Gtfs.review_calendar_change(
                 {:delete, "late_trip"},
                 %{"late_trip" => payload.fingerprint},
                 context.audit
               )

      route = route_fixture(context.organization.id, context.version.id)

      trip_fixture(context.organization.id, context.version.id, route.route_id, %{
        service_id: "late_trip"
      })

      assert {:error, :stale_review} =
               Gtfs.apply_calendar_change(
                 {:delete, "late_trip"},
                 review.fingerprint,
                 context.audit
               )

      refute identity_deleted?(context, "late_trip")

      assert {:ok, current} =
               Gtfs.get_calendar(context.organization.id, context.version.id, "late_trip")

      assert {:error, {:in_use, 1, [route_id]}} =
               Gtfs.review_calendar_change(
                 {:delete, "late_trip"},
                 %{"late_trip" => current.fingerprint},
                 context.audit
               )

      assert route_id == route.route_id
      refute identity_deleted?(context, "late_trip")
    end

    @tag :deletion
    test "a stale reviewed delete is refused and a repeated apply reports not_found", context do
      create_weekly!(context, %{service_id: "stale", name: "Stale"})

      assert {:ok, payload} =
               Gtfs.get_calendar(context.organization.id, context.version.id, "stale")

      assert {:ok, review} =
               Gtfs.review_calendar_change(
                 {:delete, "stale"},
                 %{"stale" => payload.fingerprint},
                 context.audit
               )

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "stale",
        date: ~D[2026-02-02],
        exception_type: 1
      })

      assert {:error, :stale_review} =
               Gtfs.apply_calendar_change({:delete, "stale"}, review.fingerprint, context.audit)

      assert Repo.exists?(
               from(c in Calendar,
                 where: c.gtfs_version_id == ^context.version.id and c.service_id == "stale"
               )
             )

      assert {:ok, current} =
               Gtfs.get_calendar(context.organization.id, context.version.id, "stale")

      assert current.fingerprint != payload.fingerprint

      assert {:ok, fresh} =
               Gtfs.review_calendar_change(
                 {:delete, "stale"},
                 %{"stale" => current.fingerprint},
                 context.audit
               )

      assert {:ok, %{action: :deleted}} =
               Gtfs.apply_calendar_change({:delete, "stale"}, fresh.fingerprint, context.audit)

      assert {:error, :not_found} =
               Gtfs.apply_calendar_change({:delete, "stale"}, fresh.fingerprint, context.audit)
    end
  end

  describe "review contract" do
    test "unimplemented, unknown and evidence-bypassing commands are refused", context do
      payload = create_weekly!(context, %{service_id: "svc", name: "Service"})
      fingerprints = %{"svc" => payload.fingerprint}

      unsupported = [
        {:save, "svc", %{}},
        {:convert, "svc", :dates_only, %{}},
        {:add_break, "svc", ~D[2026-01-10], ~D[2026-01-12]},
        {:put_exceptions, "svc", [~D[2026-01-10]], :added},
        {:remove_exceptions, "svc", [~D[2026-01-10]]},
        {:date_change, [~D[2026-01-10]], ["svc"], []}
      ]

      for command <- unsupported do
        assert {:error, :unsupported_command} =
                 Gtfs.review_calendar_change(command, fingerprints, context.audit)
      end

      assert {:error, :unsupported_command} =
               Gtfs.apply_calendar_change(hd(unsupported), "fingerprint", context.audit)

      for command <- [{:frobnicate, "svc"}, {:delete, ""}, {:delete, nil}, {:delete, 42}, :delete] do
        assert {:error, :invalid_command} =
                 Gtfs.review_calendar_change(command, fingerprints, context.audit)
      end

      assert {:error, :invalid_command} =
               Gtfs.apply_calendar_change({:frobnicate, "svc"}, "fingerprint", context.audit)

      assert {:error, :stale_review} =
               Gtfs.review_calendar_change({:delete, "svc"}, %{}, context.audit)

      assert {:error, :stale_review} =
               Gtfs.review_calendar_change({:delete, "svc"}, %{"svc" => nil}, context.audit)

      assert {:error, :stale_review} =
               Gtfs.review_calendar_change(
                 {:delete, "svc"},
                 %{"svc" => payload.fingerprint, "other" => payload.fingerprint},
                 context.audit
               )

      assert {:error, :stale_review} =
               Gtfs.review_calendar_change(
                 {:delete, "svc"},
                 %{"svc" => "0" <> String.duplicate("a", 63)},
                 context.audit
               )

      assert {:error, :not_found} =
               Gtfs.review_calendar_change(
                 {:delete, "missing"},
                 %{"missing" => payload.fingerprint},
                 context.audit
               )

      assert {:error, :stale_review} =
               Gtfs.apply_calendar_change({:delete, "svc"}, "bogus", context.audit)

      assert {:error, :stale_review} =
               Gtfs.apply_calendar_change({:delete, "svc"}, nil, context.audit)
    end
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp create_weekly!(context, attrs) do
    attrs =
      Map.merge(
        %{
          service_id: "wk_#{System.unique_integer([:positive])}",
          name: "Weekday",
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
        Map.new(attrs)
      )

    assert {:ok, payload} = Gtfs.create_calendar(attrs, context.audit)
    payload
  end

  defp create_dates_only!(context, attrs) do
    attrs =
      Map.merge(
        %{
          service_id: "dt_#{System.unique_integer([:positive])}",
          name: "Dates Only",
          kind: :dates_only,
          dates: [~D[2026-07-04]]
        },
        Map.new(attrs)
      )

    assert {:ok, payload} = Gtfs.create_calendar(attrs, context.audit)
    payload
  end

  defp logs_for(version, service_id) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.gtfs_version_id == ^version.id and l.entity_type == "calendar" and
            l.entity_external_id == ^service_id,
        order_by: [asc: l.inserted_at]
      )
    )
  end

  defp identity_deleted?(context, service_id) do
    table_state(context, service_id) == %{calendar: [], exceptions: [], attributes: []}
  end

  defp table_state(%{organization: organization, version: version}, service_id) do
    organization_id = organization.id
    version_id = version.id

    %{
      calendar:
        Repo.all(
          from(c in Calendar,
            where:
              c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id and
                c.service_id == ^service_id,
            order_by: [asc: c.id]
          )
        ),
      exceptions:
        Repo.all(
          from(d in CalendarDate,
            where:
              d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id and
                d.service_id == ^service_id,
            order_by: [asc: d.date, asc: d.exception_type]
          )
        ),
      attributes:
        Repo.all(
          from(a in CalendarAttribute,
            where:
              a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id and
                a.service_id == ^service_id,
            order_by: [asc: a.id]
          )
        )
    }
  end
end
