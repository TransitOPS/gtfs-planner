defmodule GtfsPlannerWeb.DashboardPlannerTest do
  @moduledoc """
  The GTFS Planner homepage (`#home-planner`) through the real
  `GtfsPlanner.Home` read boundary.

  Each case mounts `/` for an editor of a Planner organization, awaits the three
  async regions with `render_async/1` and asserts the rendered page, so the
  status, resume and check regions are observed against PostgreSQL rather than
  through stub assigns or hand-built maps.
  """

  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export.Run, as: ExportRun
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  @editor_role "pathways_studio_editor"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  describe "Planner status and attention" do
    test "calendars ending in 10 days raise the primary attention item", context do
      user = planner_member(context.organization)
      conn = log_in_user(context.conn, user, organization: context.organization)

      today = Date.utc_today()
      range_end = Date.add(today, 10)
      last_active = last_service_date(range_end)
      weekday_and_saturday_calendars(context, Date.add(today, -30), range_end)

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_async(view)

      assert has_element?(view, "#attention", "Service ends #{short_day(last_active)}")

      assert has_element?(
               view,
               "#attention a[href='#{~p"/gtfs/#{context.version.id}/calendars"}'].bg-action",
               "Open calendars"
             )

      assert ["Open calendars"] = primaries(html)
      assert html =~ ~r/id="attention".*id="editor-work"/s
    end

    test "weekday and Saturday calendars with no Sunday service raise no attention", context do
      user = planner_member(context.organization)
      conn = log_in_user(context.conn, user, organization: context.organization)

      today = Date.utc_today()
      weekday_and_saturday_calendars(context, Date.add(today, -30), Date.add(today, 90))
      schedules_destination(context)
      insert_schedule_change(context, user, ~U[2026-09-20 12:00:00.000000Z])

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_async(view)

      refute has_element?(view, "#attention")

      assert has_element?(
               view,
               "#resume-open.bg-action[href='#{~p"/gtfs/#{context.version.id}/routes/12/schedules?service_id=WKDY"}']",
               "Open schedules"
             )

      assert ["Open schedules"] = primaries(html)
    end

    test "an empty version renders the first-use panel as the only primary", context do
      user = planner_member(context.organization)
      conn = log_in_user(context.conn, user, organization: context.organization)

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_async(view)

      assert has_element?(view, "#firstuse", "Start with the service riders see today")

      assert has_element?(
               view,
               "#firstuse-import.bg-action[href='#{~p"/gtfs/#{context.version.id}/import"}']",
               "Import feed"
             )

      assert has_element?(
               view,
               "#firstuse-agency[href='#{~p"/gtfs/#{context.version.id}/settings/agencies"}']",
               "Add agency"
             )

      assert ["Import feed"] = primaries(html)
      assert has_element?(view, "#home-lede", "no calendars yet")
      refute has_element?(view, "#resume")
      refute has_element?(view, "#share")
      refute has_element?(view, "#areas")
    end

    test "a reversed calendar range makes no coverage claim and raises no attention", context do
      user = planner_member(context.organization)
      conn = log_in_user(context.conn, user, organization: context.organization)

      today = Date.utc_today()

      calendar_fixture(context.organization.id, context.version.id, %{
        service_id: "REVERSED",
        start_date: Date.add(today, 30),
        end_date: today
      })

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#home-lede", "calendar coverage could not be checked")
      refute has_element?(view, "#attention")
    end

    test "the lede states coverage and the areas strip counts the version", context do
      user = planner_member(context.organization)
      conn = log_in_user(context.conn, user, organization: context.organization)

      today = Date.utc_today()
      range_end = Date.add(today, 60)
      last_active = last_service_date(range_end)
      weekday_and_saturday_calendars(context, Date.add(today, -30), range_end)
      route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})
      station_with_platform(context, "STA", "PLT1")

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(
               view,
               "#home-lede",
               "Published #{long_day(context.version.published_at)} · calendars run through #{long_day(last_active)}"
             )

      d = document(render(view))
      assert text(d, "#area-routes") =~ "Routes · 1"
      assert text(d, "#area-calendars") =~ "Calendars · 2"
      assert text(d, "#area-stops") =~ "Stops & stations · 1"
    end

    test "a dead render shows both region skeletons before the data arrives", context do
      user = planner_member(context.organization)
      conn = log_in_user(context.conn, user, organization: context.organization)

      html = conn |> get(~p"/") |> html_response(200)
      d = document(html)

      assert text(d, "#home-title") == context.version.name
      assert LazyHTML.query(d, "#resume-loading") |> Enum.any?()
      assert LazyHTML.query(d, "#share-loading") |> Enum.any?()
      refute LazyHTML.query(d, "#attention") |> Enum.any?()
      refute LazyHTML.query(d, "#home-lede") |> Enum.any?()
    end
  end

  describe "Planner resume" do
    test "the featured item links to its schedules editor and rows carry local times", context do
      user = planner_member(context.organization)
      conn = log_in_user(context.conn, user, organization: context.organization)

      schedules_destination(context)
      insert_schedule_change(context, user, ~U[2026-09-20 12:00:00.000000Z])
      stop_change(context, user, "S4021", "Market St & 3rd", ~U[2026-09-19 09:12:00.000000Z])

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#resume-latest", "6 trips changed on Weekday")
      assert has_element?(view, "#resume-latest", "1 change that day")

      assert has_element?(
               view,
               "#resume-open[href='#{~p"/gtfs/#{context.version.id}/routes/12/schedules?service_id=WKDY"}']",
               "Open schedules"
             )

      assert render(element(view, "#resume-list")) =~
               ~r/\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{1,2}, \d{1,2}:\d{2} [AP]M\b/
    end

    test "a member with no changes sees the team list with author emails", context do
      author = planner_member(context.organization)
      viewer = planner_member(context.organization)
      conn = log_in_user(context.conn, viewer, organization: context.organization)

      schedules_destination(context)
      insert_schedule_change(context, author, ~U[2026-09-20 12:00:00.000000Z])

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#resume-title", "What your team changed recently")
      assert has_element?(view, "#resume-list li", author.email)
      refute has_element?(view, "#resume-latest")
    end

    test "a version with no changes shows the empty copy", context do
      user = planner_member(context.organization)
      conn = log_in_user(context.conn, user, organization: context.organization)

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(
               view,
               "#resume-empty",
               "Anything you change appears here, so you can come back to it."
             )
    end
  end

  describe "Planner check and share" do
    test "an expired download and the check summary render with their result links", context do
      user = planner_member(context.organization)
      conn = log_in_user(context.conn, user, organization: context.organization)

      now = DateTime.utc_now()

      check =
        insert_check(context, %{
          errors_count: 0,
          warnings_count: 12,
          started_at: DateTime.add(now, -30, :minute)
        })

      insert_export(context, %{
        artifact_expires_at: DateTime.add(now, -3, :minute),
        started_at: DateTime.add(now, -20, :minute),
        finished_at: DateTime.add(now, -10, :minute)
      })

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#export-status", "Download expired")
      assert has_element?(view, "#export-meta", "Full GTFS")
      assert has_element?(view, "#check-badge", "No errors · 12 warnings")

      assert has_element?(
               view,
               "#check-link[href='#{~p"/gtfs/#{context.version.id}/validation/#{check.id}"}']"
             )

      assert has_element?(
               view,
               "#export-link[href='#{~p"/gtfs/#{context.version.id}/export"}']",
               "Export GTFS"
             )
    end
  end

  # -- Fixtures --

  defp planner_member(organization) do
    user = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: [@editor_role]
      })

    user
  end

  # The reference's own case: weekdays and Saturdays with no Sunday service, so
  # the version-wide calendar screen reports a gap that attention must ignore.
  defp weekday_and_saturday_calendars(context, start_date, end_date) do
    calendar = %{
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: start_date,
      end_date: end_date
    }

    calendar_fixture(
      context.organization.id,
      context.version.id,
      Map.merge(calendar, %{service_id: "WKDY"})
    )

    calendar_fixture(
      context.organization.id,
      context.version.id,
      Map.merge(calendar, %{service_id: "SAT", saturday: 1})
    )

    calendar_attribute_fixture(context.organization.id, context.version.id, %{
      service_id: "WKDY",
      service_description: "Weekday"
    })

    calendar_attribute_fixture(context.organization.id, context.version.id, %{
      service_id: "SAT",
      service_description: "Saturday"
    })
  end

  # The route and calendar a schedules change points at, so the resume item
  # resolves to a link instead of a gone entity.
  defp schedules_destination(context) do
    route_fixture(context.organization.id, context.version.id, %{
      route_id: "12",
      route_short_name: "12",
      route_long_name: "Downtown – Riverside"
    })

    calendar_fixture(context.organization.id, context.version.id, %{
      service_id: "WKDY",
      start_date: Date.add(Date.utc_today(), -30),
      end_date: Date.add(Date.utc_today(), 90)
    })

    calendar_attribute_fixture(context.organization.id, context.version.id, %{
      service_id: "WKDY",
      service_description: "Weekday"
    })
  end

  defp station_with_platform(context, station_id, platform_id) do
    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: station_id,
      location_type: 1
    })

    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: platform_id,
      location_type: 0,
      parent_station: station_id
    })
  end

  defp stop_change(context, actor, stop_id, stop_name, inserted_at) do
    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: stop_id,
      stop_name: stop_name
    })

    insert_change_log(context, %{
      entity_type: "stop",
      entity_external_id: stop_id,
      changed_fields: %{"stop_lat" => %{"from" => "40.71", "to" => "40.72"}},
      actor_id: actor.id,
      actor_email: actor.email,
      inserted_at: inserted_at
    })
  end

  # One operation of six trips, so the item's detail is the domain's
  # "<n> trips changed on <calendar>" and the page counts one change that day.
  defp insert_schedule_change(context, actor, inserted_at) do
    operation_id = Ecto.UUID.generate()

    for index <- 1..6 do
      insert_change_log(context, %{
        entity_type: "trip",
        entity_external_id: "TRIP-#{index}",
        changed_fields: %{
          "before" => nil,
          "after" => %{"route_id" => "12", "service_id" => "WKDY"},
          "operation_id" => operation_id
        },
        actor_id: actor.id,
        actor_email: actor.email,
        inserted_at: inserted_at
      })
    end
  end

  defp insert_change_log(context, attrs) do
    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          entity_type: "trip",
          entity_id: Ecto.UUID.generate(),
          entity_external_id: Ecto.UUID.generate(),
          station_stop_id: nil,
          actor_id: Ecto.UUID.generate(),
          actor_email: "editor@example.test",
          snapshot: nil,
          changed_fields: nil,
          action: "updated",
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          inserted_at: ~U[2026-09-01 12:00:00.000000Z]
        },
        attrs
      )

    Repo.insert_all(ChangeLog, [row])
  end

  defp insert_check(context, attrs) do
    attrs =
      Map.merge(
        %{
          run_type: "mobility_data",
          status: "completed",
          errors_count: 0,
          warnings_count: 0,
          infos_count: 0,
          started_at: ~U[2026-09-20 09:00:00.000000Z]
        },
        attrs
      )

    %ValidationRun{
      id: Ecto.UUID.generate(),
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id
    }
    |> ValidationRun.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_export(context, attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      export_type: :full,
      state: :ready,
      phase: :cleanup,
      artifact_key: "exports/#{Ecto.UUID.generate()}.zip",
      artifact_filename: "gtfs.zip",
      artifact_sha256: String.duplicate("a", 64),
      artifact_size_bytes: 1024,
      artifact_expires_at: ~U[2026-09-21 12:00:00.000000Z],
      started_at: ~U[2026-09-20 11:50:00.000000Z],
      finished_at: ~U[2026-09-20 12:00:00.000000Z],
      inserted_at: ~U[2026-09-20 12:00:00.000000Z],
      updated_at: ~U[2026-09-20 12:00:00.000000Z]
    }

    Repo.insert!(struct!(ExportRun, Map.merge(defaults, attrs)))
  end

  # The version-wide calendars' last active date: a Sunday ends the window
  # without service, so the horizon stops on the Saturday.
  defp last_service_date(date) do
    if Date.day_of_week(date) == 7, do: Date.add(date, -1), else: date
  end

  defp short_day(date), do: Calendar.strftime(date, "%b %-d")
  defp long_day(date), do: Calendar.strftime(date, "%b %-d, %Y")

  defp document(html), do: LazyHTML.from_document(html)

  defp text(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp primaries(html) do
    html
    |> document()
    |> LazyHTML.query(".bg-action")
    |> Enum.map(&LazyHTML.text/1)
  end
end
