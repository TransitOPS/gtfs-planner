defmodule GtfsPlanner.Agents.Packs.CalendarsPrepareTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo

  @weekdays %{
    monday: 1,
    tuesday: 1,
    wednesday: 1,
    thursday: 1,
    friday: 1,
    saturday: 0,
    sunday: 0
  }
  @sundays %{
    monday: 0,
    tuesday: 0,
    wednesday: 0,
    thursday: 0,
    friday: 0,
    saturday: 0,
    sunday: 1
  }

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    other_version = gtfs_version_fixture(organization.id)
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)

    %{
      organization: organization,
      version: version,
      other_version: other_version,
      foreign_organization: foreign_organization,
      foreign_version: foreign_version,
      scope: scope_fixture(organization, version)
    }
  end

  describe "prepare_date_change" do
    test "prepares the drawer's date change and writes nothing", context do
      add_calendar(context.organization, context.version, "SCHOOL_WD", "School weekdays")
      add_calendar(context.organization, context.version, "SCHOOL_EX", "School express")

      calendar_dates = row_count(CalendarDate)
      change_logs = row_count(ChangeLog)

      args = %{
        "dates" => iso_dates(~D[2026-10-12], ~D[2026-10-16]),
        "stop" => ["SCHOOL_WD", "SCHOOL_EX"],
        "run" => []
      }

      assert {:prepared, %{command: command, summary: summary}, result} =
               prepare(args, context.scope)

      assert command ==
               {:date_change,
                [
                  ~D[2026-10-12],
                  ~D[2026-10-13],
                  ~D[2026-10-14],
                  ~D[2026-10-15],
                  ~D[2026-10-16]
                ], ["SCHOOL_EX", "SCHOOL_WD"], []}

      assert summary == %{
               title: "Stop service",
               detail: "Mon, Oct 12 – Fri, Oct 16, 2026 · 5 dates",
               lines: ["Stop · School express", "Stop · School weekdays"]
             }

      assert result == %{
               "calendars" => [
                 %{
                   "service_id" => "SCHOOL_EX",
                   "name" => "School express",
                   "action" => "stop",
                   "changing_dates" => 5
                 },
                 %{
                   "service_id" => "SCHOOL_WD",
                   "name" => "School weekdays",
                   "action" => "stop",
                   "changing_dates" => 5
                 }
               ],
               "warnings" => []
             }

      assert row_count(CalendarDate) == calendar_dates
      assert row_count(ChangeLog) == change_logs

      # The dispatch fence hands the same prepared change and result to the caller
      # and refuses an argument that tries to carry another scope.
      assert Dispatch.call(
               Calendars,
               context.scope,
               "prepare_date_change",
               Jason.encode!(args)
             ) == {:prepared, %{summary: summary, command: command}, result}

      assert Dispatch.call(
               Calendars,
               context.scope,
               "prepare_date_change",
               Jason.encode!(Map.put(args, "organization_id", context.foreign_organization.id))
             ) == {:tool_error, "Unexpected argument: organization_id"}

      assert row_count(CalendarDate) == calendar_dates
    end

    test "counts only the selected dates whose service actually changes", context do
      add_calendar(context.organization, context.version, "WD", "School weekdays")

      assert {:prepared, _prepared, result} =
               prepare(
                 %{
                   "dates" => iso_dates(~D[2026-10-12], ~D[2026-10-16]),
                   "stop" => ["WD"],
                   "run" => []
                 },
                 context.scope
               )

      assert changing_dates(result) == [5]

      assert {:prepared, _prepared, result} =
               prepare(%{"dates" => ["2026-10-17"], "stop" => ["WD"], "run" => []}, context.scope)

      assert changing_dates(result) == [0]

      assert {:prepared, %{summary: %{title: "Run service"}}, result} =
               prepare(%{"dates" => ["2026-10-17"], "stop" => [], "run" => ["WD"]}, context.scope)

      assert changing_dates(result) == [1]

      assert {:prepared, _prepared, result} =
               prepare(%{"dates" => ["2026-10-12"], "stop" => [], "run" => ["WD"]}, context.scope)

      assert changing_dates(result) == [0]
    end

    test "names both directions and a single date", context do
      add_calendar(context.organization, context.version, "WEEKDAY", "Weekday service")
      add_calendar(context.organization, context.version, "SUNDAY", "Sunday service", @sundays)

      assert {:prepared, %{summary: summary}, result} =
               prepare(
                 %{"dates" => ["2026-11-26"], "stop" => ["WEEKDAY"], "run" => ["SUNDAY"]},
                 context.scope
               )

      assert summary.title == "Change service"
      assert summary.detail == "Thu, Nov 26, 2026"
      assert summary.lines == ["Stop · Weekday service", "Run · Sunday service"]

      assert result["calendars"] == [
               %{
                 "service_id" => "WEEKDAY",
                 "name" => "Weekday service",
                 "action" => "stop",
                 "changing_dates" => 1
               },
               %{
                 "service_id" => "SUNDAY",
                 "name" => "Sunday service",
                 "action" => "run",
                 "changing_dates" => 1
               }
             ]
    end

    test "keeps only warnings dated inside the selection", context do
      add_calendar(context.organization, context.version, "WD", "School weekdays")

      # A removal on a Saturday the selection never touches.
      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "WD",
        date: ~D[2026-11-07],
        exception_type: 2
      })

      assert {:prepared, %{command: {:date_change, _, ["WD"], []}}, result} =
               prepare(%{"dates" => ["2026-10-17"], "stop" => ["WD"], "run" => []}, context.scope)

      assert result["warnings"] == [
               %{
                 "reason" => "removal_on_nonservice_day",
                 "date" => "2026-10-17",
                 "exception" => "removed",
                 "service_id" => "WD"
               }
             ]
    end

    test "rejects bad dates, empty targets, overlap and unknown or foreign IDs", context do
      assert {:error, message} =
               prepare(%{"dates" => ["2026-02-30"], "stop" => ["WD"], "run" => []}, context.scope)

      assert message == "Invalid date: 2026-02-30. Use a date like 2026-10-12."

      assert {:error, message} =
               prepare(
                 %{"dates" => ["2026-10-12", 5], "stop" => ["WD"], "run" => []},
                 context.scope
               )

      assert message == "Dates must be ISO dates like 2026-10-12."

      assert {:error, message} =
               prepare(%{"dates" => "2026-10-12", "stop" => ["WD"], "run" => []}, context.scope)

      assert message == "Dates must be a list of ISO dates."

      assert {:error, message} =
               prepare(%{"dates" => [], "stop" => ["WD"], "run" => []}, context.scope)

      assert message == "Provide at least one date."

      assert {:error, message} =
               prepare(%{"dates" => ["2026-10-12"], "stop" => "WD", "run" => []}, context.scope)

      assert message == "Argument stop must be a list of service IDs."

      assert {:error, message} =
               prepare(%{"dates" => ["2026-10-12"], "stop" => [], "run" => []}, context.scope)

      assert message == "Provide at least one calendar to stop or run."

      assert {:error, message} =
               prepare(
                 %{"dates" => ["2026-10-12"], "stop" => ["WD"], "run" => ["WD"]},
                 context.scope
               )

      assert message == "A calendar cannot be both stopped and run: WD."

      add_calendar(context.organization, context.version, "WD", "School weekdays")

      add_calendar(
        context.foreign_organization,
        context.foreign_version,
        "FOREIGN",
        "Foreign service"
      )

      add_calendar(context.organization, context.other_version, "OTHER_VERSION", "Other version")

      assert {:error, message} =
               prepare(
                 %{"dates" => ["2026-10-12"], "stop" => ["WD", "FOREIGN"], "run" => []},
                 context.scope
               )

      assert message == "No calendar with service_id FOREIGN in this service version."

      assert {:error, message} =
               prepare(
                 %{"dates" => ["2026-10-12"], "stop" => ["OTHER_VERSION"], "run" => []},
                 context.scope
               )

      assert message == "No calendar with service_id OTHER_VERSION in this service version."

      assert {:error, message} =
               prepare(
                 %{"dates" => ["2026-10-12"], "stop" => ["WD", "MISSING"], "run" => []},
                 context.scope
               )

      assert message == "No calendar with service_id MISSING in this service version."

      foreign_scope = %{context.scope | organization_id: context.foreign_organization.id}

      assert prepare(%{"dates" => ["2026-10-12"], "stop" => ["WD"], "run" => []}, foreign_scope) ==
               {:error, "This service version is not available."}

      too_many_dates = Enum.map(0..366, &Date.to_iso8601(Date.add(~D[2026-01-01], &1)))

      assert {:error, message} =
               prepare(
                 %{"dates" => too_many_dates, "stop" => ["WD"], "run" => []},
                 context.scope
               )

      assert message == "Use at most 366 dates."
    end

    test "sorts and deduplicates the target lists before building the command", context do
      add_calendar(context.organization, context.version, "DUP", "Duplicate service")
      add_calendar(context.organization, context.version, "TWIN", "Twin service")

      assert {:prepared, %{command: {:date_change, _, ["DUP"], ["TWIN"]}}, _result} =
               prepare(
                 %{
                   "dates" => ["2026-10-12"],
                   "stop" => ["DUP", "DUP"],
                   "run" => ["TWIN", "TWIN"]
                 },
                 context.scope
               )
    end

    test "sorts summary lines by calendar name, not by service ID", context do
      add_calendar(context.organization, context.version, "ZULU", "Alpha service")
      add_calendar(context.organization, context.version, "ALPHA", "Zulu service")

      assert {:prepared, %{command: {:date_change, _, ["ALPHA", "ZULU"], []}, summary: summary},
              result} =
               prepare(
                 %{"dates" => ["2026-10-12"], "stop" => ["ZULU", "ALPHA", "ZULU"], "run" => []},
                 context.scope
               )

      assert summary.lines == ["Stop · Alpha service", "Stop · Zulu service"]
      assert Enum.map(result["calendars"], & &1["service_id"]) == ["ALPHA", "ZULU"]
    end

    test "falls back to the service ID for a dates-only calendar with no name", context do
      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "HOL",
        date: ~D[2026-07-04],
        exception_type: 1
      })

      assert {:prepared, %{summary: summary}, result} =
               prepare(
                 %{"dates" => ["2026-07-04"], "stop" => ["HOL"], "run" => []},
                 context.scope
               )

      assert summary.lines == ["Stop · HOL"]

      assert result["calendars"] == [
               %{
                 "service_id" => "HOL",
                 "name" => "HOL",
                 "action" => "stop",
                 "changing_dates" => 1
               }
             ]

      assert result["warnings"] == [
               %{"reason" => "no_service", "service_id" => "HOL"},
               %{
                 "reason" => "removal_on_nonservice_day",
                 "date" => "2026-07-04",
                 "exception" => "removed",
                 "service_id" => "HOL"
               }
             ]
    end

    test "refuses a calendar whose weekly range the date evaluator refuses", context do
      add_calendar(context.organization, context.version, "REVERSED", "Reversed range", %{
        start_date: ~D[2026-12-31],
        end_date: ~D[2026-01-01]
      })

      calendar_dates = row_count(CalendarDate)

      assert {:error, message} =
               prepare(
                 %{"dates" => ["2026-10-12"], "stop" => ["REVERSED"], "run" => []},
                 context.scope
               )

      assert message ==
               "The calendar REVERSED has an invalid weekly range. Fix it on the Calendars page first."

      assert row_count(CalendarDate) == calendar_dates
    end

    test "maps a membership without the editor role to the access message", context do
      add_calendar(context.organization, context.version, "WD", "School weekdays")

      administrator = user_fixture()

      organization_membership_fixture(administrator, context.organization, [
        "pathways_studio_admin"
      ])

      administrator_scope = %{
        context.scope
        | user_id: administrator.id,
          user_email: administrator.email
      }

      assert prepare(
               %{"dates" => ["2026-10-12"], "stop" => ["WD"], "run" => []},
               administrator_scope
             ) ==
               {:error, "Access to calendars changed."}
    end

    test "bounds a prepared result that is too large for one tool result", context do
      for number <- 1..4 do
        calendar_fixture(context.organization.id, context.version.id, %{
          service_id: "BULK_#{number}"
        })
      end

      calendar_dates = row_count(CalendarDate)
      dates = Enum.map(0..364, &Date.to_iso8601(Date.add(~D[2026-01-01], &1)))
      args = %{"dates" => dates, "stop" => [], "run" => Enum.map(1..4, &"BULK_#{&1}")}

      # The selection itself is bigger than one tool result may carry: the pack
      # prepares it and the dispatch fence narrows it.
      assert {:prepared, _prepared, result} = prepare(args, context.scope)
      assert byte_size(Jason.encode!(result)) > 32_768

      assert Dispatch.call(Calendars, context.scope, "prepare_date_change", Jason.encode!(args)) ==
               {:tool_error, "Too much data for one result. Narrow the request."}

      assert row_count(CalendarDate) == calendar_dates
    end
  end

  defp prepare(args, scope), do: Calendars.call("prepare_date_change", args, scope)

  defp changing_dates(result), do: Enum.map(result["calendars"], & &1["changing_dates"])

  defp row_count(schema), do: Repo.aggregate(schema, :count)

  defp iso_dates(from, to), do: from |> Date.range(to) |> Enum.map(&Date.to_iso8601/1)

  defp add_calendar(organization, version, service_id, name, attrs \\ %{}) do
    calendar_fixture(
      organization.id,
      version.id,
      @weekdays |> Map.merge(attrs) |> Map.put(:service_id, service_id)
    )

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end

  defp scope_fixture(organization, version) do
    user = user_fixture()
    organization_membership_fixture(user, organization)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "calendars",
      version_name: version.name
    }
  end
end
