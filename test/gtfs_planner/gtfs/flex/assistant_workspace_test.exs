defmodule GtfsPlanner.Gtfs.Flex.AssistantWorkspaceTest do
  @moduledoc """
  Merge evidence (EV-1) for `GtfsPlanner.Gtfs.Flex.Assistant.workspace/1,2`:
  the scoped saved-service projection and its immutable fingerprint.

  The expectations are hand-derived from the acceptance cases and from the
  native Flex wording, not from a second invocation of the module under test:

    * The representative fixture's "Newport Dial-a-Ride" is an area service
      with two areas (`a1` Newport, `a2` Toledo), weekday and Saturday hours
      including one overnight window, a service-wide business-day booking rule
      on the `office` calendar and one Saturday-scoped rule. Its generated
      wording therefore names `Newport only:`, `Toledo only:`, reads the
      overnight Saturday window as next day, and books Monday trips by 4:00 pm
      the Friday before.
    * "Valley Line detours" is a detour service with no areas of its own; its
      hours are the calendars and band it runs on, so it has no area geometry to
      keep and no calendar-scoped booking line.
    * Only the selected service is described. The fixture's other two services
      hold a different phone number and different names, none of which may
      appear in the projection.
    * Area geometry is a server-side input to the export and the overlap checks,
      so the projection carries area names and keys and no polygon.
    * A calendar a stored field names but the version does not hold leaves the
      workspace explicitly incomplete rather than complete over a missing input.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Assistant
  alias GtfsPlanner.Gtfs.Flex.Assistant.Snapshot
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @collect_timeout 10_000
  @pause_timeout 30_000
  @race_handler {__MODULE__, :flex_workspace_snapshot_race}

  setup do
    {:ok, supervisor: start_supervised!({Task.Supervisor, []})}
  end

  describe "workspace/2 loads the scoped saved service (AC-1, AC-3)" do
    setup :flex_context

    test "returns the selected service's native wording and code-owned evidence", context do
      service = context.area

      assert {:ok, workspace, evidence} = Assistant.workspace(context.scope, service.id)

      assert workspace.service_id == service.id
      assert workspace.dependencies.service.name == "Newport Dial-a-Ride"
      assert workspace.dependencies.service.kind == :area

      # The exact native inputs are what `Checks.run/3` and `Export.plan/5` read.
      assert Enum.map(workspace.dependencies.areas, & &1.key) == ["a1", "a2"]

      assert Enum.map(workspace.area_inputs, fn %{area: area} -> area.name end) ==
               ["Newport", "Toledo"]

      assert workspace.area_inputs |> hd() |> Map.fetch!(:geojson) |> is_map()
      assert workspace.checks != []
      assert workspace.check_status.errors == Enum.count(workspace.checks, &(&1.level == :error))

      # The generated wording is the native wording for the saved service: two
      # areas prefix their own name, the overnight window reads as next day, and
      # the business-day rule books Monday trips by 4:00 pm the Friday before.
      assert workspace.wording.where_line == "Anywhere in Newport or Toledo"
      assert "Newport only: Weekdays 7:00 am–6:00 pm" in workspace.wording.hours_lines
      assert "Toledo only: Weekdays 9:00 am–3:00 pm" in workspace.wording.hours_lines

      assert "Newport only: Saturdays 6:00 pm–1:00 am (next day)" in workspace.wording.hours_lines

      assert "Book Monday trips by 4:00 pm the Friday before" in workspace.wording.deadline_lines
      assert workspace.wording.message =~ "Book Monday trips by 4:00 pm the Friday before"
      assert workspace.wording.rider_name == "Newport Dial-a-Ride"

      # A saved service compared with itself has no unsaved changes.
      assert workspace.wording.changes == []

      assert %{"weekday" => weekday, "office" => office, "saturday" => saturday} =
               workspace.calendar_rows

      assert weekday.weekly.monday == 1
      assert weekday.weekly.saturday == 0
      assert weekday.attributes.service_schedule_name == "Weekday"
      assert weekday.exceptions == []
      assert office.weekly.monday == 1
      assert saturday.weekly.saturday == 1

      assert evidence.kind == "flex_policy_workspace"
      assert evidence.title == "Newport Dial-a-Ride"
      assert evidence.total == length(workspace.checks)
      assert evidence.total_label == "readiness checks"
      assert evidence.completeness == :complete
      assert evidence.completeness_reason == nil
      assert evidence.source_ref == "gtfs_flex_policy_workspace"
      assert evidence.source_revision == "2"
      assert evidence.digest == digest(workspace.view)

      assert evidence.scope.organization_id == context.organization.id
      assert evidence.scope.gtfs_version_id == context.version.id

      assert evidence.resources == [
               %{kind: "flex_service", id: service.id, label: "Newport Dial-a-Ride"}
             ]

      assert fact(evidence, "Hours rows") == "4"
      assert fact(evidence, "Booking rules") == "2"
      assert fact(evidence, "Areas") == "2"
    end

    test "keeps the frozen fingerprint stable and content-addressed", context do
      service = context.area

      assert {:ok, first, _evidence} = Assistant.workspace(context.scope, service.id)
      assert {:ok, second, _evidence} = Assistant.workspace(context.scope, service.id)

      assert first.fingerprint == second.fingerprint
      assert first.fingerprint == Assistant.fingerprint(first.dependencies)
      assert byte_size(first.fingerprint) == 64

      # A calendar-only change moves the fingerprint, and the changed content is
      # the calendar row the workspace carries.
      assert {1, _returned} =
               Repo.update_all(
                 from(c in Calendar,
                   where:
                     c.organization_id == ^context.organization.id and
                       c.gtfs_version_id == ^context.version.id and c.service_id == "weekday",
                   select: c.id
                 ),
                 set: [saturday: 1]
               )

      assert {:ok, third, _evidence} = Assistant.workspace(context.scope, service.id)

      assert third.fingerprint != first.fingerprint
      assert third.calendar_rows["weekday"].weekly.saturday == 1
    end

    test "writes no entity, audit or job row", context do
      service = context.area
      before = row_counts(context.organization.id, context.version.id)

      assert {:ok, _workspace, _evidence} = Assistant.workspace(context.scope, service.id)

      assert {:ok, _workspace, _evidence} =
               Assistant.workspace(scope_with_source(context.scope, service.id))

      assert row_counts(context.organization.id, context.version.id) == before
    end

    test "workspace/1 reads the service id from the accepted source snapshot", context do
      service = context.area

      assert {:ok, workspace, evidence} =
               Assistant.workspace(scope_with_source(context.scope, service.id))

      assert workspace.service_id == service.id
      assert evidence.kind == "flex_policy_workspace"
    end

    test "a scope with no usable accepted source is one unavailable answer", context do
      service = context.area

      # No snapshot at all.
      assert {:error, :unavailable} = Assistant.workspace(context.scope)

      # A snapshot accepted for another kind of source names no Flex service.
      assert {:error, :unavailable} =
               context.scope
               |> scope_with_source(service.id)
               |> retag_snapshot("calendar_dates")
               |> Assistant.workspace()

      # A snapshot with no service id at all.
      assert {:error, :unavailable} =
               context.scope
               |> scope_with_source(nil)
               |> Assistant.workspace()

      # A service id that is not a UUID never reaches the scoped read as one.
      assert {:error, :unavailable} =
               context.scope
               |> scope_with_source("not-a-uuid")
               |> Assistant.workspace()

      assert service.id
    end
  end

  describe "workspace/2 refuses without metadata (AC-1)" do
    setup :flex_context

    test "a foreign or cross-version service is one unavailable answer", context do
      service = context.area

      assert {:error, :unavailable} = Assistant.workspace(context.foreign_scope, service.id)

      assert {:error, :unavailable} =
               Assistant.workspace(
                 scope_for(context.organization, context.other_version),
                 service.id
               )

      assert {:error, :unavailable} = Assistant.workspace(context.scope, Ecto.UUID.generate())
      assert {:error, :unavailable} = Assistant.workspace(context.scope, "not-a-uuid")
    end

    test "a deleted service is unavailable", context do
      service = context.area

      assert :ok = Flex.delete_service(context.audit, service.id)

      assert {:error, :unavailable} = Assistant.workspace(context.scope, service.id)
    end

    test "another organization's calendar of the same id is not this version's input", context do
      service = context.area

      foreign =
        calendar_fixture(context.foreign_organization.id, context.foreign_version.id, %{
          service_id: "weekday",
          monday: 0,
          tuesday: 0,
          wednesday: 0,
          thursday: 0,
          friday: 0,
          saturday: 1,
          sunday: 1,
          start_date: ~D[2026-01-01],
          end_date: ~D[2026-12-31]
        })

      assert foreign.organization_id == context.foreign_organization.id

      assert {:ok, workspace, _evidence} = Assistant.workspace(context.scope, service.id)

      assert workspace.calendar_rows |> Map.keys() |> Enum.sort() ==
               ["office", "saturday", "weekday"]

      # The scoped version's own weekday calendar wins; the foreign one changes
      # nothing this workspace can see.
      assert workspace.calendar_rows["weekday"].weekly.saturday == 0
    end

    test "another service's contacts and name never enter the projection", context do
      service = context.area

      assert {:ok, workspace, _evidence} = Assistant.workspace(context.scope, service.id)
      encoded = Jason.encode!(workspace.view)

      # The fixture's registered-riders service has this phone number.
      assert context.registered_service.phone == "(541) 555-0143"

      refute encoded =~ "555-0143"
      refute encoded =~ "Newport Access"
      refute encoded =~ "Valley Line detours"
      assert workspace.dependencies.service.id == service.id
    end

    test "another version's areas are not this service's areas", context do
      service = context.area

      assert {:ok, workspace, _evidence} = Assistant.workspace(context.scope, service.id)

      # The workspace's areas are this service's own rows, by id.
      assert Enum.map(workspace.area_inputs, fn %{area: area} -> {area.key, area.id} end) ==
               Enum.map(service.areas, &{&1.key, &1.id})

      # The other version's copy carries the same area keys and different rows,
      # so an area is identified by its row and never by its key alone.
      assert {:ok, 3} =
               Flex.copy_from_version(
                 flex_audit_fixture(context.organization.id, context.other_version.id),
                 context.version.id
               )

      assert {:ok, copied} =
               Flex.list_services(context.organization.id, context.other_version.id)
               |> Enum.find(&(&1.key == service.key))
               |> then(&{:ok, &1})

      assert copied.id != service.id
      assert copied.key == service.key
      assert Enum.map(copied.areas, & &1.key) == ["a1", "a2"]
      assert Enum.map(copied.areas, & &1.id) != Enum.map(service.areas, & &1.id)

      # And the other version's copy is not this version's service, so the same
      # id resolves to nothing there without disclosing what it holds.
      assert {:error, :not_found} =
               Flex.get_service(context.organization.id, context.version.id, Ecto.UUID.generate())
    end

    test "an hours row naming a foreign area key stays this service's own row", context do
      service = context.area

      # A stored hours row may name an area key this service does not have; the
      # readiness check owns that finding and the workspace still describes only
      # the selected service's own areas.
      {:ok, _saved} =
        Flex.save_service(
          context.audit,
          service,
          %{hours: [%{area_key: "a9", service_id: "weekday", start: "08:00", end: "17:00"}]},
          Enum.map(service.areas, &%{key: &1.key, name: &1.name, source: &1.source})
        )

      assert {:ok, workspace, _evidence} = Assistant.workspace(context.scope, service.id)

      assert Enum.map(workspace.dependencies.areas, & &1.key) == ["a1", "a2"]
      assert Enum.map(workspace.view["hours"], & &1["area_key"]) == ["a9"]

      # No area of this or any other service is invented to satisfy the row.
      assert length(workspace.view["areas"]) == 2
    end

    test "a missing referenced calendar is explicitly incomplete", context do
      service = context.area

      assert {:ok, _workspace, _evidence} = Assistant.workspace(context.scope, service.id)

      # The service still names `weekday` in two hours rows after the calendar
      # leaves the version, so the workspace cannot be complete.
      delete_calendar(context, "weekday")

      assert {:error, {:incomplete, {:missing_calendar, "weekday"}}} =
               Assistant.workspace(context.scope, service.id)
    end

    test "a business-day rule whose office calendar left is incomplete", context do
      service = context.area

      assert {:ok, _workspace, _evidence} = Assistant.workspace(context.scope, service.id)

      # The office calendar leaves the version while a stored rule still names
      # it, so the business-day dependency is unresolved.
      delete_calendar(context, "office")

      assert {:error, {:incomplete, {:missing_calendar, "office"}}} =
               Assistant.workspace(context.scope, service.id)
    end

    test "a revoked membership is forbidden before any service read", context do
      service = context.area
      revoked = revoke(context.scope)

      assert {:error, :forbidden} = Assistant.workspace(revoked, service.id)
    end

    test "a user with no membership in the organization is forbidden", context do
      service = context.area

      scope = %{
        context.scope
        | user_id: context.outsider.id,
          user_email: context.outsider.email
      }

      assert {:error, :forbidden} = Assistant.workspace(scope, service.id)
    end
  end

  describe "the provider projection is minimal (AC-3)" do
    setup :flex_context

    test "carries the selected policy, named areas, relevant calendars and wording", context do
      service = context.area

      assert {:ok, workspace, _evidence} = Assistant.workspace(context.scope, service.id)
      view = workspace.view

      assert view["service"]["id"] == service.id
      assert view["service"]["name"] == "Newport Dial-a-Ride"
      assert view["service"]["kind"] == "area"
      assert view["service"]["phone"] == "(541) 555-0142"
      assert view["service"]["booking_url"] == "https://example.org/book"
      assert view["service"]["lock_version"] == service.lock_version

      assert Enum.map(view["hours"], &{&1["area_key"], &1["service_id"], &1["start"], &1["end"]}) ==
               [
                 {"a1", "weekday", "07:00", "18:00"},
                 {"a2", "weekday", "09:00", "15:00"},
                 {"a1", "saturday", "18:00", "01:00"},
                 {"a2", "saturday", "09:00", "15:00"}
               ]

      assert Enum.map(view["booking_rules"], & &1["when"]) == ["earlier_day", "earlier_day"]
      assert Enum.map(view["booking_rules"], & &1["office_service_id"]) == ["office", nil]
      assert Enum.map(view["booking_rules"], & &1["business_days"]) == [true, false]
      assert Enum.map(view["booking_rules"], & &1["service_id"]) == [nil, "saturday"]

      assert Enum.map(view["areas"], &{&1["key"], &1["name"]}) ==
               [{"a1", "Newport"}, {"a2", "Toledo"}]

      assert view["calendars"] |> Enum.map(& &1["service_id"]) |> Enum.sort() ==
               ["office", "saturday", "weekday"]

      assert view["rider_text"]["where"] == "Anywhere in Newport or Toledo"

      assert view["check_status"]["errors"] ==
               Enum.count(view["checks"], &(&1["level"] == "error"))

      assert view["fingerprint"] == workspace.fingerprint
    end

    test "excludes area geometry, unrelated services and other contacts", context do
      assert {:ok, workspace, _evidence} = Assistant.workspace(context.scope, context.area.id)
      encoded = Jason.encode!(workspace.view)

      for area <- workspace.view["areas"] do
        refute Map.has_key?(area, "geojson")
        refute Map.has_key?(area, "coordinates")
      end

      refute encoded =~ "Polygon"
      refute encoded =~ "124.05"

      # The version's full facts and the stored geometry stay server-side: they
      # are the native checks' and the export's own inputs, not the model's.
      refute Map.has_key?(workspace.view, "facts")
      refute Map.has_key?(workspace.view, "dependencies")
      refute Map.has_key?(workspace.view, "area_inputs")

      assert MapSet.member?(workspace.facts.service_ids, "weekday")
      assert workspace.area_inputs |> hd() |> Map.fetch!(:geojson) |> is_map()
      assert workspace.dependencies.service.id == context.area.id
    end

    test "a detour service reports its own calendars, band and single rule", context do
      service = context.detour

      assert {:ok, workspace, evidence} = Assistant.workspace(context.scope, service.id)

      assert workspace.dependencies.service.kind == :detour
      assert workspace.area_inputs == []

      # Its hours name the weekday and Saturday calendars and its one
      # business-day rule names the office calendar.
      assert workspace.calendar_rows |> Map.keys() |> Enum.sort() ==
               ["office", "saturday", "weekday"]

      assert workspace.wording.where_line == "Detours up to ¼ mile from Route 20"

      assert workspace.wording.hours_lines == [
               "On Route 20 trips: weekdays and Saturdays, 9:00 am–3:00 pm only"
             ]

      # A detour has exactly one service-wide rule, so there is no
      # calendar-scoped line.
      assert "Book Monday trips by 4:00 pm the Friday before" in workspace.wording.deadline_lines
      assert length(workspace.dependencies.service.booking_rules) == 1
      assert evidence.completeness == :complete
    end

    test "the projection and its evidence share the 32 KiB tool-result bound", context do
      assert {:ok, workspace, evidence} = Assistant.workspace(context.scope, context.area.id)

      bytes = byte_size(Jason.encode!(workspace.view)) + byte_size(Jason.encode!(evidence))

      assert bytes <= 32_768
    end
  end

  describe "one repeatable-read snapshot (AC-1, AC-3)" do
    test "reads a controlled writer's committed change wholly before or wholly after", %{
      supervisor: supervisor
    } do
      context = in_task(supervisor, fn -> flex_scope() end)
      on_exit(fn -> cleanup([context]) end)

      parent = self()
      use_production_snapshot()

      reader = start_worker(fn -> pause_then_read(context, parent) end)

      assert_receive {:reader_ready, reader_pid}, @collect_timeout

      # The reader pauses inside its repeatable-read transaction, after it has
      # read the service and before it reads the calendars and areas.
      pause_after_service_read(parent, reader_pid)
      send(reader_pid, :start_read)
      assert_receive {:reader_paused, ^reader_pid}, @collect_timeout

      # The writer commits a calendar the saved service names, between the
      # service read and the calendar read of the same workspace.
      assert :ok = in_task(supervisor, fn -> rename_calendar(context, "renamed-saturday") end)
      send(reader_pid, :resume_query)

      assert {:ok, before_change, _evidence} = await_worker(reader)

      # Wholly before the commit: the saved service still names `saturday`, that
      # calendar is still here, and the fingerprint describes that one state.
      assert before_change.dependencies.service.hours |> Enum.map(& &1.service_id) |> Enum.sort() ==
               ["saturday", "saturday", "weekday", "weekday"]

      assert before_change.calendar_rows["saturday"].weekly.saturday == 1

      assert before_change.calendar_rows |> Map.keys() |> Enum.sort() ==
               ["office", "saturday", "weekday"]

      # Wholly after the commit: the calendar the service names is gone, so the
      # workspace is explicitly incomplete about it. Two whole states, never one
      # of each.
      assert {:error, {:incomplete, {:missing_calendar, "saturday"}}} =
               in_task(supervisor, fn ->
                 Assistant.workspace(context.scope, context.area.id)
               end)
    end

    test "leaves every source row unchanged and writes nothing", %{supervisor: supervisor} do
      context = in_task(supervisor, fn -> flex_scope() end)
      on_exit(fn -> cleanup([context]) end)

      before = row_counts(context.organization.id, context.version.id)

      assert {:ok, _workspace, _evidence} = Assistant.workspace(context.scope, context.area.id)

      assert row_counts(context.organization.id, context.version.id) == before
    end
  end

  # --- fixtures ---------------------------------------------------------------

  defp flex_context(context) do
    Map.merge(context, flex_scope())
  end

  defp flex_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    other_version = gtfs_version_fixture(organization.id)

    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)

    feed = flex_representative_fixture(organization, version)

    %{
      organization: organization,
      version: version,
      other_version: other_version,
      foreign_organization: foreign_organization,
      foreign_version: foreign_version,
      area: feed.services.area,
      detour: feed.services.detour,
      registered_service: feed.services.registered,
      audit: flex_audit_fixture(organization.id, version.id),
      scope: scope_for(organization, version),
      foreign_scope: scope_for(foreign_organization, foreign_version),
      outsider: user_fixture()
    }
  end

  defp scope_for(organization, version) do
    user = user_fixture()
    organization_membership_fixture(user, organization)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "flex_policy",
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }
  end

  # The accepted `flex_policy` snapshot a host freezes after explicit editor
  # acceptance, with the workspace's `service_id` bound beside it. `nil` builds
  # a source that names no service at all.
  defp scope_with_source(%Scope{} = scope, service_id) do
    payload =
      if is_nil(service_id) do
        %{"section" => "hours_booking"}
      else
        %{
          "service_id" => service_id,
          "section" => "hours_booking",
          "source" => %{
            "text" => "Weekdays 8 am to 5 pm, Saturdays 9 am to 3 pm",
            "label" => "Approved hours policy",
            "accepted" => true
          }
        }
      end

    {:ok, context} =
      Scope.with_source_snapshot(scope.resource_context, %{
        kind: "flex_policy",
        payload: payload
      })

    %{scope | resource_context: context}
  end

  defp retag_snapshot(%Scope{} = scope, kind) do
    snapshot = Scope.source_snapshot(scope)

    %{
      scope
      | resource_context: %{scope.resource_context | source_snapshot: %{snapshot | kind: kind}}
    }
  end

  defp revoke(%Scope{} = scope) do
    Repo.delete_all(
      from(m in UserOrgMembership,
        where: m.user_id == ^scope.user_id and m.organization_id == ^scope.organization_id
      )
    )

    scope
  end

  defp delete_calendar(context, service_id) do
    for schema <- [Calendar, CalendarAttribute, CalendarDate] do
      Repo.delete_all(
        from(row in schema,
          where:
            row.organization_id == ^context.organization.id and
              row.gtfs_version_id == ^context.version.id and row.service_id == ^service_id
        )
      )
    end
  end

  # The writer renames one calendar identity, so the saved service's Saturday
  # hours name a calendar this version no longer holds.
  defp rename_calendar(context, service_id) do
    for schema <- [Calendar, CalendarAttribute] do
      {1, _returned} =
        Repo.update_all(
          from(row in schema,
            where:
              row.organization_id == ^context.organization.id and
                row.gtfs_version_id == ^context.version.id and row.service_id == "saturday"
          ),
          set: [service_id: service_id]
        )
    end

    :ok
  end

  defp row_counts(organization_id, _version_id) do
    %{
      services:
        Repo.aggregate(
          from(s in FlexService, where: s.organization_id == ^organization_id),
          :count
        ),
      areas:
        Repo.aggregate(from(a in FlexArea, where: a.organization_id == ^organization_id), :count),
      calendars:
        Repo.aggregate(from(c in Calendar, where: c.organization_id == ^organization_id), :count),
      calendar_dates:
        Repo.aggregate(
          from(d in CalendarDate, where: d.organization_id == ^organization_id),
          :count
        ),
      audit:
        Repo.aggregate(from(l in ChangeLog, where: l.organization_id == ^organization_id), :count)
    }
  end

  defp fact(evidence, label) do
    Enum.find_value(evidence.facts, fn fact -> if fact.label == label, do: fact.value end)
  end

  defp digest(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # -- snapshot plumbing ------------------------------------------------------

  defp use_production_snapshot do
    previous = Application.get_env(:gtfs_planner, :gtfs_flex_assistant_snapshot)
    on_exit(fn -> Application.put_env(:gtfs_planner, :gtfs_flex_assistant_snapshot, previous) end)

    Application.put_env(:gtfs_planner, :gtfs_flex_assistant_snapshot, Snapshot.Repo)
  end

  # The reader runs the production entrypoint on its own committing connection,
  # so `SET TRANSACTION ISOLATION LEVEL` applies and the pause happens inside the
  # snapshot rather than inside the test's rolled-back transaction.
  defp pause_then_read(context, parent) do
    send(parent, {:reader_ready, self()})

    receive do
      :start_read -> :ok
    end

    unboxed(fn -> Assistant.workspace(context.scope, context.area.id) end)
  end

  defp pause_after_service_read(parent, reader_pid) do
    :telemetry.attach(
      @race_handler,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, reader} ->
        if self() == reader and
             String.contains?(to_string(metadata[:query]), ~s(FROM "flex_services")) do
          :telemetry.detach(@race_handler)
          send(owner, {:reader_paused, self()})

          receive do
            :resume_query -> :ok
          after
            @pause_timeout -> :ok
          end
        end
      end,
      {parent, reader_pid}
    )

    on_exit(fn -> :telemetry.detach(@race_handler) end)
  end

  defp start_worker(fun) do
    parent = self()
    spawn_monitor(fn -> send(parent, {:done, self(), unboxed(fun)}) end)
  end

  defp await_worker({pid, ref}) do
    receive do
      {:done, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("workspace worker failed: #{inspect(reason)}")
    after
      @collect_timeout ->
        flunk("workspace worker timed out")
    end
  end

  defp in_task(supervisor, fun) do
    supervisor
    |> Task.Supervisor.async_nolink(fn -> unboxed(fun) end)
    |> Task.await(@collect_timeout)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Unboxed cases commit, so this package's own fixtures are deleted explicitly.
  defp cleanup(contexts) do
    unboxed(fn ->
      organization_ids = Enum.map(contexts, & &1.organization.id)

      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(st in StopTime, where: st.organization_id in ^organization_ids))

      Repo.delete_all(
        from(ps in RoutePatternStop, where: ps.organization_id in ^organization_ids)
      )

      Repo.delete_all(from(p in RoutePattern, where: p.organization_id in ^organization_ids))
      Repo.delete_all(from(sh in Shape, where: sh.organization_id in ^organization_ids))
      Repo.delete_all(from(a in FlexArea, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(s in FlexService, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(st in Stop, where: st.organization_id in ^organization_ids))
      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))

      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id in ^organization_ids))

      Repo.delete_all(from(ag in Agency, where: ag.organization_id in ^organization_ids))
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id in ^organization_ids))

      # `organizations_active_gtfs_version_owner_fkey` refuses a delete of the
      # version an organization has selected, so the pointer is cleared the way an
      # editor would clear it before the version itself goes.
      Repo.update_all(
        from(o in Organization, where: o.id in ^organization_ids),
        set: [active_gtfs_version_id: nil]
      )

      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      # The generated user emails are reused by the next partition, so the
      # fixture's committed users go with the organizations that created them.
      Repo.delete_all(from(u in User, where: like(u.email, "user-%@example.com")))

      refute Repo.exists?(from(s in FlexService, where: s.organization_id in ^organization_ids))
      refute Repo.exists?(from(c in Calendar, where: c.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end
end
