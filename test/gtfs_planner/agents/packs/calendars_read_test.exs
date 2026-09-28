defmodule GtfsPlanner.Agents.Packs.CalendarsReadTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Scope

  @weekdays %{
    monday: 1,
    tuesday: 1,
    wednesday: 1,
    thursday: 1,
    friday: 1,
    saturday: 0,
    sunday: 0
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

  describe "pack declaration" do
    test "declares exactly the three calendar tools with their activity labels" do
      assert Calendars.id() == "calendars"
      assert Calendars.title() == "Calendar helper"
      assert Calendars.skill() == ""

      assert Calendars.intro() ==
               "I can answer questions about calendars in this service version and prepare service date changes for you to review. I can't change routes, trips or stops."

      assert Calendars.examples() == [
               "Which calendars run next Monday?",
               "Run Sunday service on a holiday"
             ]

      assert Enum.map(Calendars.tools(), & &1.name) == [
               "list_calendars",
               "get_calendar",
               "prepare_date_change"
             ]

      assert Enum.map(Calendars.tools(), & &1.activity) == [
               "Looked up calendars",
               "Checked a calendar's dates",
               "Prepared a date change"
             ]

      assert Enum.all?(Calendars.tools(), &(&1.parameters["additionalProperties"] == false))
    end

    test "answers prepare_date_change with a bounded error until the prepare step", context do
      args = Jason.encode!(%{"dates" => ["2026-10-14"], "stop" => ["WD"], "run" => []})

      assert Dispatch.call(Calendars, context.scope, "prepare_date_change", args) ==
               {:tool_error, "Not available yet."}
    end
  end

  describe "list_calendars" do
    test "returns only calendars from the scope's organization and version", context do
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "r1"})

      trip_fixture(context.organization.id, context.version.id, route.route_id, %{
        service_id: "SHARED"
      })

      add_calendar(context.organization, context.version, "SHARED", "A version one")
      add_calendar(context.organization, context.other_version, "SHARED", "A version two")

      add_calendar(
        context.foreign_organization,
        context.foreign_version,
        "SHARED",
        "B version one"
      )

      assert {:ok, %{"calendars" => calendars, "total" => 1, "truncated" => false}} =
               list(%{}, context.scope)

      assert [row] = calendars

      assert row == %{
               "service_id" => "SHARED",
               "name" => "A version one",
               "kind" => "weekly",
               "days" => ["Mon", "Tue", "Wed", "Thu", "Fri"],
               "first_active_date" => "2026-01-01",
               "last_active_date" => "2026-12-31",
               "trip_count" => 1
             }
    end

    test "maps a foreign organization scope to a bounded version error", context do
      add_calendar(context.organization, context.version, "SCOPED", "Scoped service")

      foreign_scope = %{context.scope | organization_id: context.foreign_organization.id}

      assert list(%{}, foreign_scope) == {:error, "This service version is not available."}
    end

    test "filters case-insensitively on the name or the service ID", context do
      add_calendar(context.organization, context.version, "school_ex", "Weekday base")
      add_calendar(context.organization, context.version, "weekend", "School weekdays")
      add_calendar(context.organization, context.version, "plain", "Plain weekday")

      assert {:ok, %{"calendars" => calendars, "total" => 2}} =
               list(%{"query" => "SCHOOL"}, context.scope)

      assert Enum.map(calendars, & &1["service_id"]) == ["weekend", "school_ex"]
      assert Enum.map(calendars, & &1["name"]) == ["School weekdays", "Weekday base"]
    end

    test "orders matching calendars by downcased name then service ID", context do
      add_calendar(context.organization, context.version, "zulu", "alpha")
      add_calendar(context.organization, context.version, "alpha", "Zulu")
      add_calendar(context.organization, context.version, "dup_b", "Shared name")
      add_calendar(context.organization, context.version, "dup_a", "Shared name")

      assert {:ok, %{"calendars" => calendars}} = list(%{}, context.scope)
      assert Enum.map(calendars, & &1["service_id"]) == ["zulu", "dup_a", "dup_b", "alpha"]
    end

    test "caps a page at 50 and reports the remaining 51st calendar", context do
      ids = calendar_ids("cap", 51)

      Enum.each(
        ids,
        &calendar_fixture(context.organization.id, context.version.id, %{service_id: &1})
      )

      assert {:ok,
              %{
                "calendars" => first_page,
                "total" => 51,
                "truncated" => true,
                "next_offset" => 50,
                "catalog_fingerprint" => fingerprint
              }} = list(%{}, context.scope)

      assert Enum.map(first_page, & &1["service_id"]) == Enum.take(ids, 50)

      assert {:ok,
              %{
                "calendars" => second_page,
                "total" => 51,
                "truncated" => false,
                "next_offset" => nil,
                "catalog_fingerprint" => ^fingerprint
              }} = list(%{"offset" => 50, "catalog_fingerprint" => fingerprint}, context.scope)

      assert Enum.map(second_page, & &1["service_id"]) == Enum.drop(ids, 50)
    end

    test "returns 120 calendars exactly once over three fingerprint-bound pages", context do
      ids = calendar_ids("page", 120)

      Enum.each(
        ids,
        &calendar_fixture(context.organization.id, context.version.id, %{service_id: &1})
      )

      assert {:ok, first} = list(%{}, context.scope)
      assert first["total"] == 120
      assert first["truncated"] == true
      assert first["next_offset"] == 50
      assert length(first["calendars"]) == 50

      assert {:ok, second} =
               list(
                 %{
                   "offset" => first["next_offset"],
                   "catalog_fingerprint" => first["catalog_fingerprint"]
                 },
                 context.scope
               )

      assert second["truncated"] == true
      assert second["next_offset"] == 100
      assert second["catalog_fingerprint"] == first["catalog_fingerprint"]
      assert length(second["calendars"]) == 50

      assert {:ok, third} =
               list(
                 %{
                   "offset" => second["next_offset"],
                   "catalog_fingerprint" => second["catalog_fingerprint"]
                 },
                 context.scope
               )

      assert third["truncated"] == false
      assert third["next_offset"] == nil
      assert third["catalog_fingerprint"] == first["catalog_fingerprint"]
      assert length(third["calendars"]) == 20

      read =
        Enum.map(
          first["calendars"] ++ second["calendars"] ++ third["calendars"],
          & &1["service_id"]
        )

      assert read == ids
      assert length(Enum.uniq(read)) == 120
    end

    test "refuses a later page after a catalog change, without a fingerprint, or past the end",
         context do
      ids = calendar_ids("move", 51)

      Enum.each(
        ids,
        &calendar_fixture(context.organization.id, context.version.id, %{service_id: &1})
      )

      assert {:ok, %{"next_offset" => 50, "catalog_fingerprint" => fingerprint}} =
               list(%{}, context.scope)

      assert list(%{"offset" => 50}, context.scope) ==
               {:error, "Calendars changed. Start the search again."}

      assert list(%{"offset" => 50, "catalog_fingerprint" => "stale"}, context.scope) ==
               {:error, "Calendars changed. Start the search again."}

      assert list(%{"offset" => 999, "catalog_fingerprint" => fingerprint}, context.scope) ==
               {:error, "Offset is past the end of the matching calendars."}

      calendar_fixture(context.organization.id, context.version.id, %{service_id: "move_52"})

      assert list(%{"offset" => 50, "catalog_fingerprint" => fingerprint}, context.scope) ==
               {:error, "Calendars changed. Start the search again."}
    end

    test "reports weekly days in Mon..Sun order and an empty list for a dates-only calendar",
         context do
      add_calendar(context.organization, context.version, "WD", "School weekdays")

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "HOL",
        date: ~D[2026-07-04],
        exception_type: 1
      })

      calendar_attribute_fixture(context.organization.id, context.version.id, %{
        service_id: "HOL",
        service_description: "Holiday shuttle"
      })

      assert {:ok, %{"calendars" => calendars}} = list(%{}, context.scope)

      assert %{"kind" => "weekly", "days" => ["Mon", "Tue", "Wed", "Thu", "Fri"]} =
               Enum.find(calendars, &(&1["service_id"] == "WD"))

      assert %{"kind" => "dates_only", "days" => []} =
               Enum.find(calendars, &(&1["service_id"] == "HOL"))
    end

    test "rejects a model-supplied organization_id and runs the scoped read through Dispatch",
         context do
      add_calendar(context.organization, context.version, "SCOPED", "Scoped service")

      add_calendar(
        context.foreign_organization,
        context.foreign_version,
        "FOREIGN",
        "Foreign service"
      )

      args = Jason.encode!(%{"organization_id" => context.foreign_organization.id})

      assert Dispatch.call(Calendars, context.scope, "list_calendars", args) ==
               {:tool_error, "Unexpected argument: organization_id"}

      assert {:ok, %{"calendars" => [%{"service_id" => "SCOPED", "name" => "Scoped service"}]}} =
               Dispatch.call(Calendars, context.scope, "list_calendars", "{}")
    end
  end

  describe "get_calendar" do
    test "explains each date of a weekly calendar", context do
      add_calendar(context.organization, context.version, "WD", "School weekdays")

      assert {:ok, result} = get("WD", "2026-10-12", "2026-10-18", context.scope)

      assert result["service_id"] == "WD"
      assert result["name"] == "School weekdays"
      assert result["kind"] == "weekly"
      assert result["days"] == ["Mon", "Tue", "Wed", "Thu", "Fri"]

      assert Enum.map(result["dates"], & &1["date"]) == [
               "2026-10-12",
               "2026-10-13",
               "2026-10-14",
               "2026-10-15",
               "2026-10-16",
               "2026-10-17",
               "2026-10-18"
             ]

      assert Enum.map(result["dates"], & &1["weekday"]) == [
               "Mon",
               "Tue",
               "Wed",
               "Thu",
               "Fri",
               "Sat",
               "Sun"
             ]

      assert Enum.map(result["dates"], &{&1["runs"], &1["reason"]}) == [
               {true, "weekly"},
               {true, "weekly"},
               {true, "weekly"},
               {true, "weekly"},
               {true, "weekly"},
               {false, "not_scheduled"},
               {false, "not_scheduled"}
             ]
    end

    test "labels exception dates added and removed and falls back to the service ID", context do
      calendar_fixture(
        context.organization.id,
        context.version.id,
        Map.put(@weekdays, :service_id, "WD")
      )

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "WD",
        date: ~D[2026-10-14],
        exception_type: 2
      })

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "WD",
        date: ~D[2026-10-17],
        exception_type: 1
      })

      assert {:ok, result} = get("WD", "2026-10-13", "2026-10-18", context.scope)

      assert result["name"] == "WD"

      assert date(result, "2026-10-13") == %{
               "date" => "2026-10-13",
               "weekday" => "Tue",
               "runs" => true,
               "reason" => "weekly"
             }

      assert date(result, "2026-10-14") == %{
               "date" => "2026-10-14",
               "weekday" => "Wed",
               "runs" => false,
               "reason" => "removed"
             }

      assert date(result, "2026-10-17") == %{
               "date" => "2026-10-17",
               "weekday" => "Sat",
               "runs" => true,
               "reason" => "added"
             }

      assert date(result, "2026-10-18")["reason"] == "not_scheduled"
      assert date(result, "2026-10-18")["runs"] == false
    end

    test "reports a dates-only calendar's additions without weekly days", context do
      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "HOL",
        date: ~D[2026-07-04],
        exception_type: 1
      })

      assert {:ok, result} = get("HOL", "2026-07-04", "2026-07-05", context.scope)

      assert result["days"] == []
      assert result["kind"] == "dates_only"

      assert date(result, "2026-07-04") == %{
               "date" => "2026-07-04",
               "weekday" => "Sat",
               "runs" => true,
               "reason" => "added"
             }

      assert date(result, "2026-07-05") == %{
               "date" => "2026-07-05",
               "weekday" => "Sun",
               "runs" => false,
               "reason" => "not_scheduled"
             }
    end

    test "treats a service ID from another organization or version as not found", context do
      add_calendar(
        context.foreign_organization,
        context.foreign_version,
        "FOREIGN",
        "Foreign service"
      )

      add_calendar(context.organization, context.other_version, "OTHER_VERSION", "Other version")

      assert get("FOREIGN", "2026-10-12", "2026-10-18", context.scope) ==
               {:error, "No calendar with service_id FOREIGN in this service version."}

      assert get("OTHER_VERSION", "2026-10-12", "2026-10-18", context.scope) ==
               {:error, "No calendar with service_id OTHER_VERSION in this service version."}

      assert get("MISSING", "2026-10-12", "2026-10-18", context.scope) ==
               {:error, "No calendar with service_id MISSING in this service version."}
    end

    test "rejects invalid, reversed and oversized ranges with a message naming the problem",
         context do
      add_calendar(context.organization, context.version, "WD", "School weekdays")

      assert {:error, message} = get("WD", "2026-13-01", "2026-12-01", context.scope)
      assert message =~ "Invalid from date: 2026-13-01"

      assert {:error, message} = get("WD", "2026-10-12", "2026-10-11", context.scope)
      assert message =~ "before the start date"

      assert {:error, message} = get("WD", "2026-10-01", "2026-12-02", context.scope)
      assert message =~ "62 days"
    end

    test "accepts a range of exactly 62 days", context do
      add_calendar(context.organization, context.version, "WD", "School weekdays")

      assert {:ok, %{"dates" => dates}} = get("WD", "2026-10-01", "2026-12-01", context.scope)
      assert length(dates) == 62
      assert List.first(dates)["date"] == "2026-10-01"
      assert List.last(dates)["date"] == "2026-12-01"
    end
  end

  defp list(args, scope), do: Calendars.call("list_calendars", args, scope)

  defp get(service_id, from, to, scope) do
    Calendars.call(
      "get_calendar",
      %{"service_id" => service_id, "from" => from, "to" => to},
      scope
    )
  end

  defp date(result, iso_date) do
    Enum.find(result["dates"], &(&1["date"] == iso_date))
  end

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

  defp calendar_ids(prefix, count) do
    Enum.map(1..count, fn number ->
      prefix <> "_" <> String.pad_leading(Integer.to_string(number), 3, "0")
    end)
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
