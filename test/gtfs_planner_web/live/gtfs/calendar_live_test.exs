defmodule GtfsPlannerWeb.Gtfs.CalendarLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Repo

  defp editor_context(_context) do
    organization = organization_fixture()
    user = user_fixture()

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    %{
      user: user,
      organization: organization,
      membership: membership,
      version: gtfs_version_fixture(organization.id)
    }
  end

  setup :editor_context

  defp new_path(version), do: "/gtfs/#{version.id}/calendars/new"

  defp detail_path(version, service_id) do
    "/gtfs/#{version.id}/calendars/show?service_id=" <> URI.encode_www_form(service_id)
  end

  defp list_path(version), do: "/gtfs/#{version.id}/calendars"

  defp postgres_local_today(timezone) do
    %{rows: [[%Date{} = date]]} = Repo.query!("SELECT (now() AT TIME ZONE $1)::date", [timezone])

    date
  end

  defp calendar_attrs(service_id, attrs) do
    Map.merge(
      %{
        service_id: service_id,
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-03-02],
        end_date: ~D[2026-03-31]
      },
      Map.new(attrs)
    )
  end

  defp attribute_attrs(service_id, name, attrs \\ %{}) do
    Map.merge(%{service_id: service_id, service_description: name}, Map.new(attrs))
  end

  defp seeded_weekly(context, service_id, name, attrs \\ %{}) do
    calendar_fixture(
      context.organization.id,
      context.version.id,
      calendar_attrs(service_id, attrs)
    )

    calendar_attribute_fixture(
      context.organization.id,
      context.version.id,
      attribute_attrs(service_id, name)
    )
  end

  defp stored(context, service_id) do
    {:ok, payload} = Gtfs.fetch_calendar(context.organization.id, context.version.id, service_id)

    payload
  end

  defp weekly_row(context, service_id) do
    Repo.one(
      from(c in Calendar,
        where: c.organization_id == ^context.organization.id and c.service_id == ^service_id
      )
    )
  end

  defp exception_rows(context, service_id) do
    Enum.sort_by(
      Repo.all(
        from(d in CalendarDate,
          where: d.organization_id == ^context.organization.id and d.service_id == ^service_id
        )
      ),
      &Date.to_erl(&1.date)
    )
  end

  defp dialog_open?(html, id) do
    html |> attribute_values("##{id}", "data-open") |> Enum.member?("true")
  end

  # One station with an entrance and a platform, joined by the named pathway, so
  # a closure on that pathway resolves to a station the usage links can open.
  defp station_with_pathway(context, station_id, pathway_id) do
    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: station_id,
      location_type: 1
    })

    child_stop_fixture(context.organization.id, context.version.id, station_id, %{
      stop_id: station_id <> "_ENT",
      location_type: 2
    })

    child_stop_fixture(context.organization.id, context.version.id, station_id, %{
      stop_id: station_id <> "_PLAT",
      location_type: 0
    })

    pathway_fixture(
      context.organization.id,
      context.version.id,
      station_id <> "_ENT",
      station_id <> "_PLAT",
      %{pathway_id: pathway_id}
    )
  end

  defp closure_rows(context, service_id) do
    Repo.all(
      from(e in PathwayEvolution,
        where:
          e.organization_id == ^context.organization.id and
            e.gtfs_version_id == ^context.version.id and e.service_id == ^service_id
      )
    )
  end

  defp cell_aria_label(html, date) do
    html |> attribute_values("#month-cell-#{Date.to_iso8601(date)}", "aria-label") |> List.first()
  end

  defp input_value(html, id), do: html |> attribute_values("##{id}", "value") |> List.first()

  defp attribute_values(html, selector, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
  end

  test "timeline remains chronological across a year boundary", context do
    seeded_weekly(context, "TIMELINE", "Timeline", %{
      start_date: ~D[2026-12-28],
      end_date: ~D[2027-01-12]
    })

    for date <- [~D[2026-12-31], ~D[2027-01-01], ~D[2027-01-04]],
        do:
          calendar_date_fixture(context.organization.id, context.version.id, %{
            service_id: "TIMELINE",
            date: date,
            exception_type: 2
          })

    {:ok, view, html} =
      live(
        log_in_user(context.conn, context.user, organization: context.organization),
        detail_path(context.version, "TIMELINE")
      )

    ids = attribute_values(html, "[id^=periods-segment-]", "id")

    assert ids == [
             "periods-segment-period-2026-12-28",
             "periods-segment-break-2026-12-31",
             "periods-segment-period-2027-01-05"
           ]

    for day <- ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday),
        do: assert(has_element?(view, "#months th", day))
  end

  test "initial unavailable read retries the original identity", context do
    import Mox
    adapter = GtfsPlanner.Gtfs.CatalogReadAdapterMock
    key = :gtfs_catalog_read_adapter
    previous = Application.get_env(:gtfs_planner, key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:gtfs_planner, key, previous),
        else: Application.delete_env(:gtfs_planner, key)
    end)

    seeded_weekly(context, "RETRY", "Retry calendar")
    Application.put_env(:gtfs_planner, key, adapter)
    stub(adapter, :fetch_calendar, fn _, _, "RETRY" -> {:error, :unavailable} end)

    {:ok, view, _} =
      live(
        log_in_user(context.conn, context.user, organization: context.organization),
        detail_path(context.version, "RETRY")
      )

    stub(adapter, :fetch_calendar, fn org, version, "RETRY" ->
      Calendars.get_calendar(org, version, "RETRY")
    end)

    render_click(view, "retry")
    assert has_element?(view, "#calendar-name[value='Retry calendar']")
  end

  test "exception-only identity has an editor and a working reviewed delete", context do
    calendar_date_fixture(context.organization.id, context.version.id, %{
      service_id: "ONLY",
      date: ~D[2026-03-03],
      exception_type: 1
    })

    {:ok, view, _} =
      live(
        log_in_user(context.conn, context.user, organization: context.organization),
        detail_path(context.version, "ONLY")
      )

    refute has_element?(view, "#calendar-date-input")
    assert has_element?(view, "#calendar-exception-form")
    render_click(view, "delete")
    assert has_element?(view, "#calendar-review-dialog[data-open=true]")
    assert {:error, {:live_redirect, _}} = render_click(view, "apply_review")

    assert Gtfs.fetch_calendar(context.organization.id, context.version.id, "ONLY") ==
             {:error, :not_found}
  end

  test "weekly save with no effective days requires explicit confirmation", context do
    seeded_weekly(context, "LAST", "Last service")

    {:ok, view, _} =
      live(
        log_in_user(context.conn, context.user, organization: context.organization),
        detail_path(context.version, "LAST")
      )

    params = %{
      "calendar" => %{
        "name" => "Last service",
        "weekdays" => ["monday"],
        "start_date" => "2026-03-07",
        "end_date" => "2026-03-07"
      }
    }

    render_submit(view, "submit_form", params)
    assert has_element?(view, "#calendar-review-dialog[data-open=true]")
    assert has_element?(view, "#calendar-review-warnings", "No service days")
    assert stored(context, "LAST").active_dates != []
    render_click(view, "cancel_review")
    assert stored(context, "LAST").active_dates != []
    render_submit(view, "submit_form", params)
    render_click(view, "apply_review")
    assert stored(context, "LAST").active_dates == []
  end

  test "draft preview changes a service cell without writing", context do
    today = Date.utc_today()
    first = Date.beginning_of_month(today)
    last = Date.end_of_month(today)
    second = Date.add(first, 1)

    seeded_weekly(context, "PREVIEW", "Preview", %{
      start_date: first,
      end_date: last,
      saturday: 1,
      sunday: 1
    })

    {:ok, view, html} =
      live(
        log_in_user(context.conn, context.user, organization: context.organization),
        detail_path(context.version, "PREVIEW")
      )

    before = cell_aria_label(html, second)

    render_change(view, "validate", %{
      "calendar" => %{
        "weekdays" => ~w(monday tuesday wednesday thursday friday saturday sunday),
        "end_date" => Date.to_iso8601(first)
      }
    })

    assert cell_aria_label(render(view), second) != before
    assert stored(context, "PREVIEW").calendar.end_date == last
    assert has_element?(view, "#calendar-preview-intro", "Includes your unsaved changes.")
  end

  test "unnamed imported zero-day schedule permits a metadata-only save", context do
    calendar_fixture(
      context.organization.id,
      context.version.id,
      calendar_attrs("ZERO", %{monday: 0, tuesday: 0, wednesday: 0, thursday: 0, friday: 0})
    )

    {:ok, view, _} =
      live(
        log_in_user(context.conn, context.user, organization: context.organization),
        detail_path(context.version, "ZERO")
      )

    render_submit(view, "submit_form", %{
      "calendar" => %{"name" => "", "weekdays" => [], "service_schedule_name" => "Season"}
    })

    render_click(view, "apply_review")
    assert stored(context, "ZERO").attributes.service_schedule_name == "Season"
    assert stored(context, "ZERO").attributes.service_description == nil
  end

  describe "creating either kind from ordinary navigation" do
    test "creates a weekly calendar and reloads its stored values", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, new_path(version))

      assert render(view) =~ "Create calendar"
      assert has_element?(view, "#calendar-form")
      assert has_element?(view, "#calendar-weekdays-monday")
      refute has_element?(view, "#periods")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#calendar-form", %{
                 calendar: %{
                   service_id: "SCHOOL_WEEK",
                   name: "School days",
                   kind: "weekly",
                   weekdays: ~w(monday tuesday wednesday thursday friday),
                   start_date: "2026-03-02",
                   end_date: "2026-03-31",
                   service_schedule_name: "Winter 2026",
                   service_schedule_type: "Weekday",
                   service_schedule_typicality: "1",
                   rating_description: "School-year rating"
                 }
               })
               |> render_submit()

      assert to == detail_path(version, "SCHOOL_WEEK")

      {:ok, detail, html} = live(conn, to)
      assert html =~ "School days"
      assert input_value(html, "calendar-name") == "School days"
      assert has_element?(detail, "#calendar-weekdays-monday[checked]")
      assert has_element?(detail, "#calendar-weekdays-saturday:not([checked])")
      assert has_element?(detail, "#calendar-exceptions")
      assert has_element?(detail, "#calendar-exception-form")
      refute has_element?(detail, "#calendar-service-id")

      payload = stored(%{organization: organization, version: version}, "SCHOOL_WEEK")
      assert payload.calendar.monday == 1
      assert payload.calendar.saturday == 0
      assert payload.calendar.start_date == ~D[2026-03-02]
      assert payload.attributes.service_description == "School days"
      assert payload.attributes.service_schedule_type == "Weekday"
      assert payload.attributes.service_schedule_typicality == 1
      assert payload.attributes.rating_description == "School-year rating"
    end

    test "creates a specific-date calendar with no synthetic weekly row", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, new_path(version))

      html =
        view
        |> form("#calendar-form", %{calendar: %{kind: "dates_only", name: "Holiday extras"}})
        |> render_change()

      refute html =~ "calendar-start-date"
      refute html =~ "calendar-weekdays"
      assert html =~ "calendar-date-input"

      with_date =
        render_change(view, "validate", %{
          "calendar" => %{
            "kind" => "dates_only",
            "name" => "Holiday extras",
            "date_input" => "2026-05-01"
          }
        })

      assert with_date =~ "calendar-draft-date-2026-05-01"
      assert input_value(with_date, "calendar-date-input") == ""

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#calendar-form", %{
                 calendar: %{service_id: "EVENTS", kind: "dates_only", name: "Holiday extras"}
               })
               |> render_submit()

      context = %{organization: organization, version: version}
      assert weekly_row(context, "EVENTS") == nil

      assert Enum.map(exception_rows(context, "EVENTS"), &{&1.date, &1.exception_type}) ==
               [{~D[2026-05-01], 1}]

      {:ok, _detail, html} = live(conn, to)
      assert html =~ "Runs only on chosen dates"
      assert html =~ "Holiday extras"
    end

    test "refuses an unchanged name and requires weekly days and additions", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, new_path(version))

      blank =
        view
        |> form("#calendar-form", %{calendar: %{name: "", service_id: "NONAME"}})
        |> render_submit()

      assert blank =~ "calendar-name-error"
      assert blank =~ "Enter a calendar name."
      assert blank =~ ~s{aria-invalid="true"}
      refute weekly_row(%{organization: organization, version: version}, "NONAME")

      no_days =
        view
        |> form("#calendar-form", %{
          calendar: %{
            name: "No days",
            service_id: "NODAYS",
            kind: "weekly",
            weekdays: [],
            start_date: "2026-03-02",
            end_date: "2026-03-31"
          }
        })
        |> render_submit()

      assert no_days =~ "calendar-weekdays-error"
      assert no_days =~ "Choose at least one service day."

      reversed =
        view
        |> form("#calendar-form", %{
          calendar: %{
            name: "Reversed",
            service_id: "REV",
            kind: "weekly",
            weekdays: ["monday"],
            start_date: "2026-03-31",
            end_date: "2026-03-02"
          }
        })
        |> render_submit()

      assert reversed =~ "calendar-end-date-error"
      assert reversed =~ "The end date must be on or after the start date."

      no_dates =
        view
        |> form("#calendar-form", %{
          calendar: %{name: "No dates", service_id: "NOD", kind: "dates_only"}
        })
        |> render_submit()

      assert no_dates =~ "calendar-date-input-error"
      assert no_dates =~ "Add at least one service date."

      # Every failed submit retains the draft and still holds the identifier.
      assert input_value(render(view), "calendar-name") == "No dates"
    end

    test "refuses a duplicate name while keeping the submitted values", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      seeded_weekly(%{organization: organization, version: version}, "TAKEN", "School days")
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, new_path(version))

      html =
        view
        |> form("#calendar-form", %{
          calendar: %{
            name: "  school days  ",
            service_id: "DUPE",
            kind: "weekly",
            weekdays: ~w(monday tuesday wednesday thursday friday),
            start_date: "2026-03-02",
            end_date: "2026-03-31"
          }
        })
        |> render_submit()

      assert html =~ "calendar-name-error"
      assert input_value(html, "calendar-name") == "school days"
      assert weekly_row(%{organization: organization, version: version}, "DUPE") == nil
    end

    test "suggests an editable service ID from the name", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, new_path(version))

      html =
        view
        |> form("#calendar-form", %{calendar: %{name: "Summer School 2026"}})
        |> render_change()

      assert input_value(html, "calendar-service-id") == "summer_school_2026"
    end

    test "keeps following the name while each keystroke resubmits the suggested service ID", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, new_path(version))

      for name <- ["D", "DOCQA", "DOCQA Weekday"] do
        service_id = input_value(render(view), "calendar-service-id")

        view
        |> form("#calendar-form", %{calendar: %{name: name, service_id: service_id}})
        |> render_change()
      end

      assert input_value(render(view), "calendar-service-id") == "docqa_weekday"
    end

    test "follows the name again after it is cleared and retyped", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, new_path(version))

      for name <- ["Weekday", "", "Saturday"] do
        service_id = input_value(render(view), "calendar-service-id")

        view
        |> form("#calendar-form", %{calendar: %{name: name, service_id: service_id}})
        |> render_change()
      end

      assert input_value(render(view), "calendar-service-id") == "saturday"
    end

    test "keeps a service ID the user typed when the name changes", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, new_path(version))

      view
      |> form("#calendar-form", %{calendar: %{name: "Weekday"}})
      |> render_change()

      view
      |> form("#calendar-form", %{calendar: %{service_id: "WKDY"}})
      |> render_change()

      for name <- ["Weekday s", "Weekday sch"] do
        service_id = input_value(render(view), "calendar-service-id")

        view
        |> form("#calendar-form", %{calendar: %{name: name, service_id: service_id}})
        |> render_change()
      end

      assert input_value(render(view), "calendar-service-id") == "WKDY"
    end

    test "never re-derives the service ID of an existing calendar when it is renamed", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "summer", "Summer")
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "summer"))

      refute has_element?(view, "#calendar-service-id")

      view
      |> form("#calendar-form", %{calendar: %{name: "Winter"}})
      |> render_change()

      view
      |> form("#calendar-form")
      |> render_submit()

      assert stored(context, "summer").attributes.service_description == "Winter"
      assert {:error, :not_found} = Gtfs.fetch_calendar(organization.id, version.id, "winter")
    end
  end

  defp submit_reversed_rating(view) do
    view
    |> form("#calendar-form", %{
      calendar: %{
        name: "Rated",
        service_id: "RATED",
        kind: "weekly",
        weekdays: ["monday"],
        start_date: "2026-03-02",
        end_date: "2026-03-31",
        rating_start_date: "2026-06-30",
        rating_end_date: "2026-06-01"
      }
    })
    |> render_submit()
  end

  describe "the More details disclosure on the create form" do
    setup %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, new_path(version))

      %{view: view}
    end

    test "starts closed", %{view: view} do
      assert has_element?(view, "#calendar-more-details")
      refute has_element?(view, "#calendar-more-details[open]")
    end

    test "stays open while a field inside it changes", %{view: view} do
      view |> element("#calendar-more-details-summary") |> render_click()
      assert has_element?(view, "#calendar-more-details[open]")

      view
      |> form("#calendar-form", %{calendar: %{service_schedule_name: "W"}})
      |> render_change()

      assert has_element?(view, "#calendar-more-details[open]")
    end

    test "returns to closed when the summary is toggled twice", %{view: view} do
      view |> element("#calendar-more-details-summary") |> render_click()
      view |> element("#calendar-more-details-summary") |> render_click()

      refute has_element?(view, "#calendar-more-details[open]")
    end

    test "opens to show an error on a field inside it after a save", %{view: view} do
      submit_reversed_rating(view)

      assert has_element?(view, "#calendar-more-details[open]")

      assert has_element?(
               view,
               "#calendar-more-details #calendar-rating-end-error",
               "The schedule period must end on or after it starts."
             )

      assert has_element?(view, "#calendar-rating-end[aria-invalid='true']")
    end

    test "stays open once an error opened it and the next change validates", %{view: view} do
      submit_reversed_rating(view)

      view
      |> form("#calendar-form", %{calendar: %{rating_end_date: "2026-07-31"}})
      |> render_change()

      assert has_element?(view, "#calendar-more-details[open]")
      refute has_element?(view, "#calendar-rating-end-error")
    end

    test "stays closed when only a field outside it fails", %{view: view} do
      view
      |> form("#calendar-form", %{calendar: %{name: "", service_id: "NONAME"}})
      |> render_submit()

      assert has_element?(view, "#calendar-name-error")
      refute has_element?(view, "#calendar-more-details[open]")
    end
  end

  describe "service ID routing at the real router" do
    test "encoded, reserved and unknown service IDs load or report not found", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}

      for service_id <- ["svc/with space%and+plus", "new", "show", "percent%25id"] do
        calendar_attribute_fixture(
          organization.id,
          version.id,
          attribute_attrs(service_id, "Service #{service_id}")
        )
      end

      conn = log_in_user(conn, user, organization: organization)

      # The list link and the detail load agree on one decode.
      {:ok, list, _html} = live(conn, list_path(version))
      html = render(list)
      encoded = URI.encode_www_form("svc/with space%and+plus")
      assert html =~ "/calendars/show?service_id=#{encoded}"

      for service_id <- ["svc/with space%and+plus", "new", "show", "percent%25id"] do
        {:ok, _view, detail_html} = live(conn, detail_path(version, service_id))
        assert detail_html =~ "Service #{service_id}"
      end

      # Create stays unambiguous next to a stored "new" identity.
      {:ok, _view, create_html} = live(conn, new_path(version))
      assert create_html =~ "calendar-form"
      assert create_html =~ "Feed ID"

      for path <- [
            "/gtfs/#{version.id}/calendars/show",
            "/gtfs/#{version.id}/calendars/show?service_id="
          ] do
        {:ok, _view, not_found_html} = live(conn, path)
        assert not_found_html =~ "calendar-not-found"
        refute not_found_html =~ "calendar-form"
      end

      assert {:error, :not_found} = Gtfs.fetch_calendar(organization.id, version.id, "missing")
      assert context.version.id == version.id
    end
  end

  describe "derived periods and three-month preview" do
    test "shows the exact states for a Fri/Mon/Tue closure and an outside addition", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      today = postgres_local_today("Etc/UTC")
      friday = Date.add(today, rem(5 - Date.day_of_week(today) + 7, 7))
      monday = Date.add(friday, 3)
      tuesday = Date.add(friday, 4)
      saturday = Date.add(friday, 1)
      outside = Date.add(today, 30)

      calendar_fixture(organization.id, version.id, %{
        service_id: "CLOSURE",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: Date.add(today, -30),
        end_date: Date.add(today, 10)
      })

      calendar_attribute_fixture(
        organization.id,
        version.id,
        attribute_attrs("CLOSURE", "Closure service")
      )

      for {date, type} <- [
            {friday, 2},
            {monday, 2},
            {tuesday, 2},
            {saturday, 1},
            {outside, 1}
          ] do
        calendar_date_fixture(organization.id, version.id, %{
          service_id: "CLOSURE",
          date: date,
          exception_type: type
        })
      end

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, detail_path(version, "CLOSURE"))

      # The three removed expected days span a weekend, so they form one break: the
      # strip draws it, and the changes list shows it once with its dates a disclosure away.
      assert has_element?(view, "#periods-timeline")
      assert html =~ "1 break"
      assert has_element?(view, "#periods-remove-break-break-#{Date.to_iso8601(friday)}")
      assert html =~ "Break · "
      assert html =~ "3 service days without service"
      assert has_element?(view, "#calendar-changes-summary", "1 break")

      # A break's coverage gap is stated under the strip, not raised as a warning.
      assert has_element?(view, "#periods-gaps", "No service")

      # Out-of-range additions stay outside the periods, are one warning to check, and
      # say so on their own row.
      assert has_element?(view, "#periods-warnings", "1 thing to check")
      assert has_element?(view, "#periods-warnings", "is outside the regular dates")
      assert has_element?(view, "#periods-warnings", "stored as its own change")

      assert has_element?(
               view,
               "#calendar-exception-chips-#{Date.to_iso8601(outside)}",
               "Outside the regular dates."
             )

      # Symbols plus text plus a legend for every state.
      assert has_element?(view, "#months-legend")

      for word <- ["Runs", "Day off", "Extra service", "Not a service day", "Today"] do
        assert has_element?(view, "#months-legend", word)
      end

      # One month is rendered, and the window moves a month at a time.
      assert Enum.count(LazyHTML.query(LazyHTML.from_fragment(html), "#months table")) == 1

      first_month = Date.new!(today.year, today.month, 1)
      next_month = shift_month(first_month, 1)
      keyboard = render_keydown(view, "preview_keys", %{"key" => "ArrowRight"})
      assert keyboard =~ Elixir.Calendar.strftime(next_month, "%B %Y")

      assert render_click(view, "preview_step", %{"step" => "next"}) =~
               Elixir.Calendar.strftime(shift_month(next_month, 1), "%B %Y")

      assert render_click(view, "preview_step", %{"step" => "prev"}) =~
               Elixir.Calendar.strftime(next_month, "%B %Y")

      assert render_click(view, "preview_step", %{"step" => "today"}) =~
               Elixir.Calendar.strftime(first_month, "%B %Y")

      # Exact accessible states in the month grid, in whichever month each date falls.
      assert cell_label_in_month(view, today, friday) =~ "Day off"
      assert cell_label_in_month(view, today, monday) =~ "Day off"
      assert cell_label_in_month(view, today, tuesday) =~ "Day off"
      assert cell_label_in_month(view, today, saturday) =~ "Extra service"
      assert cell_label_in_month(view, today, outside) =~ "Extra service"
    end

    test "a long schedule is drawn whole instead of clipped", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      today = postgres_local_today("Etc/UTC")
      first = Date.add(today, -400)
      last = Date.add(today, 400)

      calendar_fixture(organization.id, version.id, %{
        service_id: "LONG",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: first,
        end_date: last
      })

      calendar_attribute_fixture(
        organization.id,
        version.id,
        attribute_attrs("LONG", "Long running service")
      )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, detail_path(version, "LONG"))

      label =
        "#{Elixir.Calendar.strftime(first, "%b %-d, %Y")} – #{Elixir.Calendar.strftime(last, "%b %-d, %Y")}"

      # The period row names both ends of the multi-year range, so the preview and
      # the timeline describe the whole schedule rather than a clipped window.
      assert html =~ "0 breaks"
      assert html =~ label
      assert has_element?(view, "#periods-timeline")
    end

    test "discloses the UTC fallback and its absence", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      seeded_weekly(%{organization: organization, version: version}, "ZONE", "Zone service")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} = live(conn, detail_path(version, "ZONE"))
      assert html =~ "calendar-timezone-fallback"
      assert html =~ "Today’s date may be off by a day"
      assert html =~ "no agency timezone"

      agency_fixture(organization.id, version.id, %{agency_timezone: "Pacific/Auckland"})
      {:ok, _view, zoned} = live(conn, detail_path(version, "ZONE"))
      refute zoned =~ "calendar-timezone-fallback"
    end

    test "unknown unnamed imported services show the service ID without inventing a write", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      calendar_fixture(organization.id, version.id, calendar_attrs("IMPORTED_UNNAMED", %{}))
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} = live(conn, detail_path(version, "IMPORTED_UNNAMED"))
      assert html =~ "IMPORTED_UNNAMED"
      assert html =~ "Imported without a name"
      assert input_value(html, "calendar-name") == ""

      # An unrelated native edit leaves the unnamed identity unnamed.
      {:ok, view, _html} = live(conn, detail_path(version, "IMPORTED_UNNAMED"))
      render_click(view, "add_dates", %{"exception" => %{"date" => "2026-05-01"}})
      render_click(view, "apply_review")

      context = %{organization: organization, version: version}
      payload = stored(context, "IMPORTED_UNNAMED")
      assert payload.attributes.service_description == nil
      assert Enum.map(exception_rows(context, "IMPORTED_UNNAMED"), & &1.date) == [~D[2026-05-01]]
    end
  end

  describe "a calendar whose end date is before its start date" do
    setup context do
      seeded_weekly(context, "REVERSED", "Reversed range", %{
        start_date: ~D[2026-03-31],
        end_date: ~D[2026-03-02]
      })

      %{conn: log_in_user(context.conn, context.user, organization: context.organization)}
    end

    test "opens with the error callout and the stored dates in the form", context do
      {:ok, view, html} = live(context.conn, detail_path(context.version, "REVERSED"))

      assert has_element?(view, "#calendar-range-error")
      assert input_value(html, "calendar-start-date") == "2026-03-31"
      assert input_value(html, "calendar-end-date") == "2026-03-02"
      assert input_value(html, "calendar-name") == "Reversed range"
    end

    test "keeps rendering while the form still holds a reversed range", context do
      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      # One date at a time: the range stays reversed after each edit.
      start_moved =
        view
        |> form("#calendar-form", %{calendar: %{start_date: "2026-04-30"}})
        |> render_change()

      assert input_value(start_moved, "calendar-start-date") == "2026-04-30"
      assert input_value(start_moved, "calendar-end-date") == "2026-03-02"
      assert has_element?(view, "#calendar-range-error")

      end_moved =
        view
        |> form("#calendar-form", %{calendar: %{end_date: "2026-04-01"}})
        |> render_change()

      assert input_value(end_moved, "calendar-end-date") == "2026-04-01"
      assert has_element?(view, "#calendar-range-error")
    end

    test "saves a corrected range and drops the error callout", context do
      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      view
      |> form("#calendar-form", %{calendar: %{end_date: "2026-04-30"}})
      |> render_change()

      view
      |> form("#calendar-form", %{calendar: %{end_date: "2026-04-30"}})
      |> render_submit()

      row = weekly_row(context, "REVERSED")
      assert {row.start_date, row.end_date} == {~D[2026-03-31], ~D[2026-04-30]}
      refute has_element?(view, "#calendar-range-error")
      assert stored(context, "REVERSED").coverage_error == nil
      assert stored(context, "REVERSED").active_dates != []
    end

    test "refuses a save that leaves the range reversed and writes nothing", context do
      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      html =
        view
        |> form("#calendar-form", %{calendar: %{name: "Renamed range"}})
        |> render_submit()

      assert html =~ "calendar-end-date-error"
      assert html =~ "must be on or after the start date"
      assert has_element?(view, "#calendar-range-error")

      row = weekly_row(context, "REVERSED")
      assert {row.start_date, row.end_date} == {~D[2026-03-31], ~D[2026-03-02]}
      assert stored(context, "REVERSED").attributes.service_description == "Reversed range"
    end

    test "does not offer a break, single-date changes or conversion to specific dates",
         context do
      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "REVERSED",
        date: ~D[2026-07-04],
        exception_type: 1
      })

      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      refute has_element?(view, "#calendar-break-form")
      refute has_element?(view, "#calendar-exception-form")
      refute has_element?(view, "[id^='calendar-exception-chips-remove-']")
      assert has_element?(view, "#calendar-exception-chips-2026-07-04")
      assert has_element?(view, "#calendar-kind-dates-only[disabled]")
      refute has_element?(view, "#calendar-kind-weekly[disabled]")
    end

    test "offers them again once a corrected range is saved", context do
      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      view
      |> form("#calendar-form", %{calendar: %{end_date: "2026-04-30"}})
      |> render_submit()

      assert has_element?(view, "#calendar-break-form")
      assert has_element?(view, "#calendar-exception-form")
      refute has_element?(view, "#calendar-kind-dates-only[disabled]")
    end

    test "refuses a forged break and keeps the view open", context do
      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      render_submit(view, "add_break", %{
        "break" => %{"first_date" => "2026-03-09", "last_date" => "2026-03-13"}
      })

      assert has_element?(view, "#calendar-error", "Correct this calendar’s dates first.")
      refute has_element?(view, "#calendar-review-dialog[data-open=true]")
      assert has_element?(view, "#calendar-range-error")
      assert exception_rows(context, "REVERSED") == []
    end

    test "refuses a forged conversion to specific dates and keeps the view open", context do
      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      render_click(view, "set_kind", %{"kind" => "dates_only"})

      render_submit(view, "submit_form", %{
        "calendar" => %{"kind" => "dates_only", "name" => "Reversed range"}
      })

      assert has_element?(view, "#calendar-error", "Correct this calendar’s dates first.")
      refute has_element?(view, "#calendar-review-dialog[data-open=true]")
      row = weekly_row(context, "REVERSED")
      assert {row.start_date, row.end_date} == {~D[2026-03-31], ~D[2026-03-02]}
      assert exception_rows(context, "REVERSED") == []
    end

    test "refuses forged single-date changes and keeps the view open", context do
      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "REVERSED",
        date: ~D[2026-07-04],
        exception_type: 1
      })

      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      render_submit(view, "add_dates", %{"exception" => %{"date" => "2026-08-01"}})
      assert has_element?(view, "#calendar-error", "Correct this calendar’s dates first.")

      render_click(view, "remove_date", %{"date" => "2026-07-04"})
      assert has_element?(view, "#calendar-error", "Correct this calendar’s dates first.")

      render_click(view, "remove_break", %{"dates" => "2026-07-04"})
      assert has_element?(view, "#calendar-error", "Correct this calendar’s dates first.")

      assert Enum.map(exception_rows(context, "REVERSED"), & &1.date) == [~D[2026-07-04]]
    end

    test "deletes after review when no trip uses it", context do
      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      view |> element("#calendar-delete") |> render_click()

      assert has_element?(
               view,
               "#calendar-review-dialog[data-open=true]",
               "Delete Reversed range?"
             )

      assert {:error, {:live_redirect, %{to: to}}} = render_click(view, "apply_review")
      assert to == list_path(context.version)

      assert weekly_row(context, "REVERSED") == nil

      assert {:error, :not_found} =
               Gtfs.fetch_calendar(context.organization.id, context.version.id, "REVERSED")
    end

    test "reports the trips that block its deletion", context do
      route =
        route_fixture(context.organization.id, context.version.id, %{route_id: "R_REVERSED"})

      trip_fixture(context.organization.id, context.version.id, route.route_id, %{
        service_id: "REVERSED"
      })

      {:ok, view, _html} = live(context.conn, detail_path(context.version, "REVERSED"))

      view |> element("#calendar-delete") |> render_click()

      assert has_element?(
               view,
               "#calendar-delete-blocked",
               "1 trip on R_REVERSED still runs on it"
             )

      assert has_element?(view, "#calendar-delete-blocked-route-R_REVERSED")
      refute has_element?(view, "#calendar-review-dialog[data-open=true]")
      assert weekly_row(context, "REVERSED") != nil
    end
  end

  describe "dirty guards and independent actions" do
    test "a dirty schedule blocks break and date actions until save or discard", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "DIRTY", "Dirty service")
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "DIRTY"))

      dirty =
        view
        |> form("#calendar-form", %{calendar: %{name: "Renamed schedule"}})
        |> render_change()

      assert input_value(dirty, "calendar-name") == "Renamed schedule"
      assert has_element?(view, "#calendar-save")

      break_html =
        render_submit(view, "add_break", %{
          "break" => %{"first_date" => "2026-03-09", "last_date" => "2026-03-11"}
        })

      assert dialog_open?(break_html, "calendar-dirty-dialog")
      assert exception_rows(context, "DIRTY") == []

      # Keeping the edits writes nothing and retains every field.
      kept = render_click(view, "keep_editing")
      refute dialog_open?(kept, "calendar-dirty-dialog")
      assert input_value(kept, "calendar-name") == "Renamed schedule"
      assert exception_rows(context, "DIRTY") == []

      # Asking again keeps the pending action, and discarding then runs it through
      # its own review.
      render_submit(view, "add_break", %{
        "break" => %{"first_date" => "2026-03-09", "last_date" => "2026-03-11"}
      })

      discarded = render_click(view, "discard_changes")
      assert input_value(discarded, "calendar-name") == "Dirty service"
      assert dialog_open?(discarded, "calendar-review-dialog")
      assert exception_rows(context, "DIRTY") == []

      render_click(view, "apply_review")

      assert Enum.map(exception_rows(context, "DIRTY"), &{&1.date, &1.exception_type}) == [
               {~D[2026-03-09], 2},
               {~D[2026-03-10], 2},
               {~D[2026-03-11], 2}
             ]
    end

    test "a cancelled review dialog writes nothing and applies only its own fingerprint", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "CANCEL", "Cancel service")
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "CANCEL"))

      review =
        render_click(view, "add_break", %{
          "break" => %{"first_date" => "2026-03-09", "last_date" => "2026-03-11"}
        })

      assert dialog_open?(review, "calendar-review-dialog")
      assert review =~ "3 service days in the range would be skipped"
      assert exception_rows(context, "CANCEL") == []

      cancelled = render_click(view, "cancel_review")
      refute dialog_open?(cancelled, "calendar-review-dialog")
      assert input_value(cancelled, "calendar-break-first") == "2026-03-09"
      assert input_value(cancelled, "calendar-break-last") == "2026-03-11"
      assert exception_rows(context, "CANCEL") == []

      opened =
        render_click(view, "add_break", %{
          "break" => %{"first_date" => "2026-03-09", "last_date" => "2026-03-11"}
        })

      assert dialog_open?(opened, "calendar-review-dialog")
      applied = render_click(view, "apply_review")
      refute dialog_open?(applied, "calendar-review-dialog")
      assert applied =~ "date changes were stored" or applied =~ "service dates were removed"

      assert Enum.map(exception_rows(context, "CANCEL"), &{&1.date, &1.exception_type}) == [
               {~D[2026-03-09], 2},
               {~D[2026-03-10], 2},
               {~D[2026-03-11], 2}
             ]
    end

    test "removing a stored date change needs no dialog but a data-loss change does", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "CHIPS", "Chip service")

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "CHIPS",
        date: ~D[2026-03-09],
        exception_type: 2
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "CHIPS"))

      assert has_element?(view, "#calendar-exception-chips-2026-03-09", "No service")

      # Removing the only removal keeps other service days, so it applies directly.
      removed = render_click(view, "remove_date", %{"date" => "2026-03-09"})
      refute dialog_open?(removed, "calendar-review-dialog")
      assert exception_rows(context, "CHIPS") == []

      # A forged or malformed date is refused without writing.
      forged = render_click(view, "remove_date", %{"date" => "not-a-date"})
      assert forged =~ "could not be read"
      assert exception_rows(context, "CHIPS") == []
    end

    test "a change that would leave no service asks for confirmation", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "ONLY_DATE",
        date: ~D[2026-05-01],
        exception_type: 1
      })

      calendar_attribute_fixture(
        organization.id,
        version.id,
        attribute_attrs("ONLY_DATE", "Single date service")
      )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "ONLY_DATE"))

      last_active =
        render_click(view, "remove_date", %{"date" => "2026-05-01"})

      assert dialog_open?(last_active, "calendar-review-dialog")

      cancelled = render_click(view, "cancel_review")
      refute dialog_open?(cancelled, "calendar-review-dialog")
      assert length(exception_rows(context, "ONLY_DATE")) == 1

      render_click(view, "remove_date", %{"date" => "2026-05-01"})
      render_click(view, "apply_review")
      assert exception_rows(context, "ONLY_DATE") == []
    end
  end

  describe "reviewed conversion, duplication and deletion" do
    test "a weekly to specific-date conversion preserves the whole effective set", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "CONVERT", "Convert me")

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "CONVERT",
        date: ~D[2026-03-09],
        exception_type: 2
      })

      # An addition outside the weekly range must survive the conversion.
      calendar_date_fixture(organization.id, version.id, %{
        service_id: "CONVERT",
        date: ~D[2026-06-01],
        exception_type: 1
      })

      {:ok, before} = Gtfs.get_calendar(organization.id, version.id, "CONVERT")
      effective = before.active_dates
      assert ~D[2026-06-01] in effective

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "CONVERT"))

      view
      |> form("#calendar-form", %{calendar: %{kind: "dates_only", name: "Convert me"}})
      |> render_change()

      review =
        view
        |> form("#calendar-form", %{calendar: %{kind: "dates_only", name: "Convert me"}})
        |> render_submit()

      assert dialog_open?(review, "calendar-review-dialog")
      assert review =~ "to chosen dates?"

      assert review =~ "Stores all #{length(effective)} service dates as chosen dates."

      render_click(view, "cancel_review")
      assert weekly_row(context, "CONVERT") != nil

      view
      |> form("#calendar-form", %{calendar: %{kind: "dates_only", name: "Convert me"}})
      |> render_submit()

      applied = render_click(view, "apply_review")
      refute dialog_open?(applied, "calendar-review-dialog")

      assert weekly_row(context, "CONVERT") == nil
      assert before.calendar.id != nil

      stored_dates =
        context
        |> exception_rows("CONVERT")
        |> Enum.map(& &1.date)

      assert stored_dates == effective
      assert ~D[2026-06-01] in stored_dates
    end

    test "a used specific-date calendar cannot convert to a weekly schedule", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "USED_DATES",
        date: ~D[2026-05-01],
        exception_type: 1
      })

      calendar_attribute_fixture(
        organization.id,
        version.id,
        attribute_attrs("USED_DATES", "Used dates only")
      )

      route = route_fixture(organization.id, version.id, %{route_id: "R_CAL"})
      trip_fixture(organization.id, version.id, route.route_id, %{service_id: "USED_DATES"})

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "USED_DATES"))

      view
      |> form("#calendar-form", %{calendar: %{kind: "weekly", name: "Used dates only"}})
      |> render_change()

      html =
        view
        |> form("#calendar-form", %{
          calendar: %{
            kind: "weekly",
            name: "Used dates only",
            weekdays: ["monday"],
            start_date: "2026-01-05",
            end_date: "2026-01-31"
          }
        })
        |> render_submit()

      assert html =~ "1 trip uses this calendar, so it can’t switch to a weekly schedule."
      refute has_element?(view, "#calendar-delete-blocked")
      refute dialog_open?(html, "calendar-review-dialog")
      assert weekly_row(context, "USED_DATES") == nil
    end

    test "duplication creates a distinct identity with no trips", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "COPY_ME", "Copy me")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "COPY_ME"))

      assert {:error, {:live_redirect, %{to: to}}} = render_click(view, "duplicate")
      assert to == detail_path(version, "COPY_ME_copy")

      {:ok, _copy} = Gtfs.get_calendar(organization.id, version.id, "COPY_ME_copy")
      copy = stored(context, "COPY_ME_copy")

      assert copy.attributes.service_description == "Copy me (copy)"
      assert copy.attributes.id != stored(context, "COPY_ME").attributes.id
      assert copy.calendar.monday == 1
      assert copy.usage.trip_count == 0
      assert stored(context, "COPY_ME").attributes.service_description == "Copy me"
    end

    test "a used calendar reports its actual trips instead of deleting", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "USED_DELETE", "Used for delete")

      route = route_fixture(organization.id, version.id, %{route_id: "R_USED"})

      for index <- 1..3 do
        trip_fixture(organization.id, version.id, route.route_id, %{
          trip_id: "USED_#{index}",
          service_id: "USED_DELETE"
        })
      end

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "USED_DELETE"))

      html = render_click(view, "delete")

      assert has_element?(view, "#calendar-delete-blocked")
      assert html =~ "3 trips"
      assert has_element?(view, "#calendar-delete-blocked-route-R_USED")
      refute dialog_open?(html, "calendar-review-dialog")
      assert weekly_row(context, "USED_DELETE") != nil
      assert weekly_row(context, "USED_DELETE").id != nil
    end

    test "an unused calendar deletes after review and returns to the refreshed list", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "UNUSED_DELETE", "Unused for delete")
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "UNUSED_DELETE"))

      review = render_click(view, "delete")
      assert has_element?(view, "#calendar-review-dialog", "Removes")
      assert dialog_open?(review, "calendar-review-dialog")
      assert review =~ "Delete Unused for delete?"
      assert weekly_row(context, "UNUSED_DELETE") != nil

      assert {:error, {:live_redirect, %{to: to}}} = render_click(view, "apply_review")
      assert to == list_path(version)

      assert weekly_row(context, "UNUSED_DELETE") == nil
      assert exception_rows(context, "UNUSED_DELETE") == []

      assert {:error, :not_found} =
               Gtfs.fetch_calendar(organization.id, version.id, "UNUSED_DELETE")
    end
  end

  describe "reference guards" do
    test "a closure-only calendar refuses deletion and names the closures", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "CLOSURE_ONLY", "Closure only service")
      station_with_pathway(context, "STN_CLOSURE", "PW/CLOSURE ONE")

      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: "PW/CLOSURE ONE",
        service_id: "CLOSURE_ONLY"
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "CLOSURE_ONLY"))

      refused = render_click(view, "delete")

      assert has_element?(
               view,
               "#calendar-delete-blocked",
               "Scheduled closures use this calendar, so it can’t be deleted"
             )

      assert refused =~ "1 scheduled closure uses this calendar on pathway"
      refute refused =~ "This calendar is used by trips"
      refute has_element?(view, "#calendar-delete-blocked", "trips use this calendar")

      # The refusal names the exact pathway and links it to the station that owns
      # it, with the natural ID encoded rather than interpolated.
      assert attribute_values(refused, "#calendar-usage-pathways-0", "href") == [
               "/gtfs/#{version.id}/stops/STN_CLOSURE/evolutions?pathway=PW%2FCLOSURE+ONE"
             ]

      assert attribute_values(refused, "#calendar-delete-pathways-0", "data-pathway-id") == [
               "PW/CLOSURE ONE"
             ]

      # A refusal writes nothing and opens no review.
      refute dialog_open?(refused, "calendar-review-dialog")
      assert has_element?(view, "#calendar-form")
      assert weekly_row(context, "CLOSURE_ONLY") != nil
      assert length(closure_rows(context, "CLOSURE_ONLY")) == 1
    end

    test "a calendar used by trips and closures names both and keeps the loaded form", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "BOTH_USES", "Both uses")
      station_with_pathway(context, "STN_BOTH", "PW/BOTH ONE")

      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: "PW/BOTH ONE",
        service_id: "BOTH_USES"
      })

      route = route_fixture(organization.id, version.id, %{route_id: "R_BOTH"})

      for index <- 1..3 do
        trip_fixture(organization.id, version.id, route.route_id, %{
          trip_id: "BOTH_#{index}",
          service_id: "BOTH_USES"
        })
      end

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, detail_path(version, "BOTH_USES"))

      # The usage strip keeps the trip count and adds the closure count with the
      # exact addresses of both references.
      assert has_element?(view, "#calendar-trips", "3 trips on 1 route")

      assert has_element?(
               view,
               "#calendar-usage-closures",
               "1 scheduled closure uses this calendar"
             )

      assert attribute_values(html, "#calendar-usage-route-R_BOTH", "href") == [
               "/gtfs/#{version.id}/routes/R_BOTH"
             ]

      assert attribute_values(html, "#calendar-usage-pathways-0", "data-pathway-id") == [
               "PW/BOTH ONE"
             ]

      refused = render_click(view, "delete")

      assert has_element?(
               view,
               "#calendar-delete-blocked",
               "Trips and closures use this calendar, so it can’t be deleted"
             )

      assert has_element?(view, "#calendar-delete-blocked", "3 trips on R_BOTH still run on it")
      assert refused =~ "1 scheduled closure uses this calendar"

      assert attribute_values(refused, "#calendar-delete-pathways-0", "data-station-stop-id") ==
               [
                 "STN_BOTH"
               ]

      # The link names the station's Closures tab, the tab's own name.
      assert [label] = attribute_values(refused, "#calendar-delete-pathways-0", "aria-label")
      assert label =~ "on the STN_BOTH Closures tab"

      refute dialog_open?(refused, "calendar-review-dialog")

      # The loaded form survives the refusal with its stored values.
      assert input_value(refused, "calendar-name") == "Both uses"
      assert input_value(refused, "calendar-start-date") == "2026-03-02"
      assert input_value(refused, "calendar-end-date") == "2026-03-31"
      assert weekly_row(context, "BOTH_USES") != nil
    end

    test "the last stored date is refused and an emptied referenced week is warned", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "GUARD_DATE",
        date: ~D[2026-05-01],
        exception_type: 1
      })

      calendar_attribute_fixture(
        organization.id,
        version.id,
        attribute_attrs("GUARD_DATE", "Guard date service")
      )

      station_with_pathway(context, "STN_DATE", "PW/DATE ONE")

      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: "PW/DATE ONE",
        service_id: "GUARD_DATE"
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "GUARD_DATE"))

      refused = render_click(view, "remove_date", %{"date" => "2026-05-01"})

      # The refusal sits beside the attempted date change, names the date and
      # the closure, and is not the deletion callout.
      assert has_element?(view, "#calendar-date-error")
      refute has_element?(view, "#calendar-delete-blocked")
      assert refused =~ "May 1, 2026 was not removed"
      assert refused =~ "1 scheduled closure uses it"

      assert attribute_values(refused, "#calendar-date-error-pathways-0", "href") == [
               "/gtfs/#{version.id}/stops/STN_DATE/evolutions?pathway=PW%2FDATE+ONE"
             ]

      refute dialog_open?(refused, "calendar-review-dialog")
      assert has_element?(view, "#calendar-exception-chips-2026-05-01")

      assert Enum.map(exception_rows(context, "GUARD_DATE"), &{&1.date, &1.exception_type}) == [
               {~D[2026-05-01], 1}
             ]

      # A weekly calendar that keeps its native row is warned and allowed, and
      # the review states what the empty dates mean for its closure.
      seeded_weekly(context, "GUARD_WEEK", "Guard week", %{
        start_date: ~D[2026-05-01],
        end_date: ~D[2026-05-01]
      })

      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: "PW/DATE ONE",
        service_id: "GUARD_WEEK"
      })

      {:ok, week_view, _html} = live(conn, detail_path(version, "GUARD_WEEK"))

      review =
        render_click(week_view, "add_break", %{
          "break" => %{"first_date" => "2026-05-01", "last_date" => "2026-05-01"}
        })

      assert dialog_open?(review, "calendar-review-dialog")
      assert has_element?(week_view, "#calendar-review-closures")
      assert review =~ "1 scheduled closure uses this calendar"

      assert attribute_values(review, "#calendar-review-closures-pathways-0", "href") == [
               "/gtfs/#{version.id}/stops/STN_DATE/evolutions?pathway=PW%2FDATE+ONE"
             ]

      applied = render_click(week_view, "apply_review")

      refute dialog_open?(applied, "calendar-review-dialog")
      assert weekly_row(context, "GUARD_WEEK") != nil

      assert Enum.map(exception_rows(context, "GUARD_WEEK"), &{&1.date, &1.exception_type}) == [
               {~D[2026-05-01], 2}
             ]
    end
  end

  describe "failure, staleness and authority" do
    test "a stale second tab cannot overwrite and keeps its input", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "STALE", "Original name")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, first, _html} = live(conn, detail_path(version, "STALE"))
      {:ok, second, _html} = live(conn, detail_path(version, "STALE"))

      first
      |> form("#calendar-form", %{calendar: %{name: "First save"}})
      |> render_submit()

      assert stored(context, "STALE").attributes.service_description == "First save"

      stale =
        second
        |> form("#calendar-form", %{calendar: %{name: "Second save"}})
        |> render_submit()

      assert stale =~ "changed in another session"
      assert input_value(stale, "calendar-name") == "Second save"
      assert stored(context, "STALE").attributes.service_description == "First save"
      assert has_element?(second, "#calendar-error[role=alert]")
    end

    test "a revoked membership cannot write from an already-open editor", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      membership: membership
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "REVOKED", "Revoked service")
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "REVOKED"))

      deactivate_membership_fixture(membership)

      html =
        view
        |> form("#calendar-form", %{calendar: %{name: "Should not save"}})
        |> render_submit()

      assert html =~ "no longer have permission"
      assert input_value(html, "calendar-name") == "Should not save"
      assert stored(context, "REVOKED").attributes.service_description == "Revoked service"
    end

    test "forged or unopened review events cannot write", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "FORGED", "Forged service")
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "FORGED"))

      # No reviewed command is pending, so applying writes nothing.
      render_click(view, "apply_review")
      assert weekly_row(context, "FORGED") != nil
      assert exception_rows(context, "FORGED") == []

      # A break range that cannot be parsed is refused.
      html =
        render_submit(view, "add_break", %{
          "break" => %{"first_date" => "2026-03-31", "last_date" => "2026-03-02"}
        })

      assert html =~ "last day off must be on or after the first day off"
      assert exception_rows(context, "FORGED") == []

      # A date that stores no change is a no-op, not an invented removal.
      assert render_click(view, "remove_date", %{"date" => "2026-12-25"}) =~
               "No change was needed."

      assert exception_rows(context, "FORGED") == []
    end

    test "both version events ask before leaving a dirty editor and never mutate the target", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      seeded_weekly(
        %{organization: organization, version: version},
        "VERSION_SWITCH",
        "Switch me"
      )

      other_version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "VERSION_SWITCH"))

      other_list = "/gtfs/#{other_version.id}/calendars"

      # A clean editor switches straight to the other version's calendar list.
      assert {:error, {:live_redirect, %{to: ^other_list}}} =
               render_click(view, "switch_gtfs_version", %{"version" => other_version.id})

      {:ok, view, _html} = live(conn, detail_path(version, "VERSION_SWITCH"))

      dirty =
        view
        |> form("#calendar-form", %{calendar: %{name: "Dirty name"}})
        |> render_change()

      assert input_value(dirty, "calendar-name") == "Dirty name"

      asked = render_click(view, "gtfs_version_loaded", %{"version_id" => other_version.id})
      assert dialog_open?(asked, "calendar-dirty-dialog")

      kept = render_click(view, "keep_editing")
      refute dialog_open?(kept, "calendar-dirty-dialog")
      assert input_value(kept, "calendar-name") == "Dirty name"

      assert render_click(view, "gtfs_version_loaded", %{"version_id" => other_version.id})
             |> dialog_open?("calendar-dirty-dialog")

      assert {:error, {:live_redirect, %{to: ^other_list}}} =
               render_click(view, "discard_changes")

      assert {:error, :not_found} =
               Gtfs.fetch_calendar(organization.id, other_version.id, "VERSION_SWITCH")

      assert Repo.aggregate(
               from(c in Calendar, where: c.gtfs_version_id == ^other_version.id),
               :count
             ) == 0
    end

    test "an unknown version id never navigates", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      seeded_weekly(%{organization: organization, version: version}, "NO_SWITCH", "No switch")
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, detail_path(version, "NO_SWITCH"))

      assert render_click(view, "switch_gtfs_version", %{"version" => Ecto.UUID.generate()}) =~
               "No switch"

      assert render_click(view, "gtfs_version_loaded", %{
               "version_id" => to_string(version.id)
             }) =~ "No switch"
    end

    test "a foreign version discloses no calendar data", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      seeded_weekly(
        %{organization: organization, version: gtfs_version_fixture(organization.id)},
        "LOCAL_ONLY",
        "Local only"
      )

      other = organization_fixture()
      other_version = gtfs_version_fixture(other.id)

      calendar_attribute_fixture(
        other.id,
        other_version.id,
        attribute_attrs("FOREIGN_SECRET", "Foreign secret")
      )

      conn = log_in_user(conn, user, organization: organization)
      assert {:error, {:redirect, _}} = live(conn, detail_path(other_version, "FOREIGN_SECRET"))
      assert {:error, {:redirect, _}} = live(conn, new_path(other_version))
    end

    test "a non-editor cannot open the create or detail route", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      seeded_weekly(%{organization: organization, version: version}, "GUARDED", "Guarded service")
      viewer = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: viewer.id,
        organization_id: organization.id,
        roles: ["pathways_studio_admin"]
      })

      conn = log_in_user(conn, viewer, organization: organization)

      assert {:error, {:redirect, _}} = live(conn, new_path(version))
      assert {:error, {:redirect, _}} = live(conn, detail_path(version, "GUARDED"))
    end
  end

  describe "header summary" do
    test "states what a used every-day calendar runs and which trips depend on it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      today = postgres_local_today("Etc/UTC")
      context = %{organization: organization, version: version}

      seeded_weekly(context, "EVERY_DAY", "Every day", %{
        monday: 1,
        saturday: 1,
        sunday: 1,
        start_date: Date.add(today, -5),
        end_date: Date.add(today, 60)
      })

      route = route_fixture(organization.id, version.id, %{route_id: "R_HEAD"})
      trip_fixture(organization.id, version.id, route.route_id, %{service_id: "EVERY_DAY"})

      {:ok, view, _html} =
        live(
          log_in_user(conn, user, organization: organization),
          detail_path(version, "EVERY_DAY")
        )

      assert has_element?(view, "h1", "Every day")
      assert has_element?(view, "#calendar-badge", "Runs today")
      assert has_element?(view, "#calendar-lede", "Runs every day")
      assert has_element?(view, "#calendar-meta", "1 trip on 1 route uses this calendar")
      assert has_element?(view, "#calendar-meta", "EVERY_DAY")
    end

    test "says a calendar with no trips is unused and offers the route list", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      today = postgres_local_today("Etc/UTC")

      seeded_weekly(%{organization: organization, version: version}, "IDLE", "Idle", %{
        start_date: Date.add(today, -5),
        end_date: Date.add(today, 90)
      })

      {:ok, view, _html} =
        live(
          log_in_user(conn, user, organization: organization),
          detail_path(version, "IDLE")
        )

      assert has_element?(view, "#calendar-badge", "Not used by trips")
      assert has_element?(view, "#calendar-meta", "No trips use this calendar yet")
      assert has_element?(view, "#calendar-usage", "No trips use this calendar")
      assert has_element?(view, "#calendar-open-routes[href='/gtfs/#{version.id}/routes']")
    end

    test "reads a chosen-dates calendar from its dates and shows added dates as running", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      today = postgres_local_today("Etc/UTC")
      first = Date.add(today, 3)

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "CHOSEN",
        date: first,
        exception_type: 1
      })

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "CHOSEN",
        date: Date.add(first, 1),
        exception_type: 1
      })

      calendar_attribute_fixture(
        organization.id,
        version.id,
        attribute_attrs("CHOSEN", "Chosen dates")
      )

      {:ok, view, _html} =
        live(
          log_in_user(conn, user, organization: organization),
          detail_path(version, "CHOSEN")
        )

      assert has_element?(view, "#calendar-lede", "Runs only on chosen dates · 2 dates")
      assert has_element?(view, "#calendar-changes-title", "Service dates")
      refute has_element?(view, "#calendar-break-form")

      # An added date on a chosen-dates calendar is a day it runs, so no cell claims extra service.
      label = cell_label_in_month(view, today, first)
      assert label =~ "Runs"
      refute label =~ "Extra service"
      refute has_element?(view, "#months-legend", "Extra service")
    end
  end

  describe "rejected submit" do
    test "lists every failing field at once, links each, and moves focus to the first", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), new_path(version))

      view
      |> form("#calendar-form", %{calendar: %{name: "", start_date: "", end_date: ""}})
      |> render_submit()

      assert has_element?(view, "#calendar-form-errors", "Calendar not created")
      assert has_element?(view, "#calendar-form-errors a[href='#calendar-name']")
      assert has_element?(view, "#calendar-form-errors a[href='#calendar-start-date']")
      assert has_element?(view, "#calendar-form-errors a[href='#calendar-end-date']")
      assert_push_event(view, "focus_form_error", %{form_id: "calendar-form"})
    end

    test "shows no summary while the person is only typing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), new_path(version))

      view |> form("#calendar-form", %{calendar: %{name: "Typing"}}) |> render_change()

      refute has_element?(view, "#calendar-form-errors")
    end

    test "opens the feed ID disclosure when the ID is already taken", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      seeded_weekly(%{organization: organization, version: version}, "TAKEN_ID", "Taken ID")

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), new_path(version))

      refute has_element?(view, "#calendar-service-id-details[open]")

      view
      |> form("#calendar-form", %{
        calendar: %{
          name: "A fresh name",
          service_id: "TAKEN_ID",
          start_date: "2026-03-02",
          end_date: "2026-03-31"
        }
      })
      |> render_submit()

      assert has_element?(view, "#calendar-service-id-details[open]")

      assert has_element?(
               view,
               "#calendar-service-id-error",
               "Another calendar already uses this feed ID."
             )
    end
  end

  describe "outcome messages" do
    test "a save reports beside the schedule and a date change beside the changes", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      seeded_weekly(%{organization: organization, version: version}, "MESSAGES", "Messages")

      {:ok, view, _html} =
        live(
          log_in_user(conn, user, organization: organization),
          detail_path(version, "MESSAGES")
        )

      view |> form("#calendar-form", %{calendar: %{name: "Renamed"}}) |> render_submit()

      assert has_element?(view, "#calendar-schedule #calendar-status", "Saved.")
      refute has_element?(view, "#calendar-changes #calendar-status")

      render_click(view, "add_dates", %{"exception" => %{"date" => "2026-03-14"}})

      assert has_element?(view, "#calendar-changes #calendar-status", "Extra service added.")
      refute has_element?(view, "#calendar-schedule #calendar-status")
    end

    test "a refused date names the fix beside the changes and keeps the schedule message clear",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      seeded_weekly(%{organization: organization, version: version}, "REFUSED", "Refused")

      {:ok, view, _html} =
        live(
          log_in_user(conn, user, organization: organization),
          detail_path(version, "REFUSED")
        )

      render_submit(view, "add_break", %{"break" => %{"first_date" => "", "last_date" => ""}})

      assert has_element?(
               view,
               "#calendar-changes #calendar-error[role=alert]",
               "choose it twice"
             )

      refute has_element?(view, "#calendar-schedule #calendar-error")
    end
  end

  describe "breaks and discarding" do
    test "restoring a break applies directly, names what came back and moves focus to the message",
         %{conn: conn, user: user, organization: organization, version: version} do
      context = %{organization: organization, version: version}
      seeded_weekly(context, "BREAKS", "Breaks")

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "BREAKS",
        date: ~D[2026-03-09],
        exception_type: 2
      })

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "BREAKS",
        date: ~D[2026-03-10],
        exception_type: 2
      })

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "BREAKS",
        date: ~D[2026-03-11],
        exception_type: 2
      })

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), detail_path(version, "BREAKS"))

      assert has_element?(view, "#calendar-break-2026-03-09", "3 service days without service")

      view |> element("#periods-remove-break-break-2026-03-09") |> render_click()

      assert exception_rows(context, "BREAKS") == []
      assert has_element?(view, "#calendar-changes #calendar-status", "3 dates restored.")
      refute has_element?(view, "#calendar-break-2026-03-09")
      assert_push_event(view, "focus_scoped_target", %{id: "calendar-status"})
    end

    test "discard changes asks first, keeps the draft on Keep editing and resets on confirm", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      seeded_weekly(%{organization: organization, version: version}, "DISCARD", "Discard me")

      {:ok, view, _html} =
        live(
          log_in_user(conn, user, organization: organization),
          detail_path(version, "DISCARD")
        )

      refute has_element?(view, "#calendar-discard")

      view |> form("#calendar-form", %{calendar: %{name: "Edited"}}) |> render_change()
      assert has_element?(view, "#calendar-unsaved")

      view |> element("#calendar-discard") |> render_click()
      assert dialog_open?(render(view), "calendar-dirty-dialog")
      assert has_element?(view, "#calendar-dirty-dialog", "will be dropped")

      kept = render_click(view, "keep_editing")
      refute dialog_open?(kept, "calendar-dirty-dialog")
      assert input_value(kept, "calendar-name") == "Edited"

      view |> element("#calendar-discard") |> render_click()
      discarded = render_click(view, "discard_changes")

      refute dialog_open?(discarded, "calendar-dirty-dialog")
      assert input_value(discarded, "calendar-name") == "Discard me"
      refute has_element?(view, "#calendar-discard")
    end
  end

  # The preview shows one month, so a date outside it is read after stepping to its month.
  defp cell_label_in_month(view, today, date) do
    render_click(view, "preview_step", %{"step" => "today"})
    months = (date.year - today.year) * 12 + (date.month - today.month)

    html =
      Enum.reduce(List.duplicate(:next, months), render(view), fn :next, _html ->
        render_click(view, "preview_step", %{"step" => "next"})
      end)

    cell_aria_label(html, date)
  end

  defp shift_month(%Date{} = month, offset) do
    total = month.year * 12 + (month.month - 1) + offset
    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end
end
