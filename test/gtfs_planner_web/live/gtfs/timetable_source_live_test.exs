defmodule GtfsPlannerWeb.Gtfs.TimetableSourceLiveTest do
  # Step 3: the reviewed-source controls on the existing Paste page.
  #
  # Everything here drives the ordinary production path — `live/2` on the real
  # Paste route, the real `#paste-form` read, then the real
  # `#timetable-source-form` submit — so the accepted mapping and dates can
  # only come from native form events. The expectations are written by hand
  # from the fixture's own times and the calendar arithmetic below, never from
  # a call into `TimetableSource`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  # 2026-11-02 through 2026-11-30 holds 21 ISO weekdays (Mon 2 through Mon 30),
  # and Thanksgiving is Thursday 2026-11-26, so the reviewed source below
  # covers exactly 20 dates.
  @first_date "2026-11-02"
  @last_date "2026-11-30"
  @thanksgiving "2026-11-26"

  setup do
    organization =
      organization_fixture(%{alias: "timetable-source-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "timetable-source-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(build_conn(), user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  # One route, one Weekday calendar, three stops on an outbound pattern and a
  # trip at 06:00 and one at 07:00, so a pasted 06:00 row and a pasted 07:00 row
  # each resolve to exactly one feed trip.
  defp source_route(context, minutes) do
    %{organization: organization, version: version} = context

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "SRC1",
        route_short_name: "14",
        route_long_name: "Harbor – Union"
      })

    calendar_fixture(organization.id, version.id, %{service_id: "SRC_WKD"})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "SRC_WKD",
      service_description: "Weekday",
      service_schedule_name: "Weekday"
    })

    Enum.each(1..3, fn index ->
      stop_fixture(organization.id, version.id, %{
        stop_id: "SRC_S#{index}",
        stop_name: "Source Stop #{index}"
      })
    end)

    pattern =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "SRC-MAIN",
        route_pattern_name: "Main",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"SRC_S1", 0, 0, 1},
          {"SRC_S2", 300, 360, 1},
          {"SRC_S3", 660, 720, 1}
        ]
      })

    Enum.each(minutes, fn minute ->
      schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
        service_id: "SRC_WKD",
        trip_id: "SRC_T#{minute}",
        start_time: clock(minute * 60) <> ":00",
        trip_headsign: "Union Depot"
      })
    end)

    %{route: route, calendar: "SRC_WKD", pattern: pattern}
  end

  defp paste_path(version, route, query \\ %{}) do
    path = "/gtfs/#{version.id}/routes/#{route.route_id}/schedules/paste"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp exact_text do
    "Trip\tSource Stop 1\tSource Stop 2\tSource Stop 3\n" <>
      "101\t06:00\t06:05\t06:10\n102\t07:00\t07:05\t07:10"
  end

  defp open_paste(context, text \\ nil) do
    route = source_route(context, [360, 420])
    {:ok, view, _html} = live(context.conn, paste_path(context.version, route.route))

    render_submit(view, "read", %{
      "paste" => %{"text" => text || exact_text(), "layout" => "auto", "header" => "true"}
    })

    {view, route}
  end

  defp source_params(overrides) do
    Map.merge(
      %{
        "label" => "",
        "revision" => "",
        "notes" => "",
        "first_date" => @first_date,
        "last_date" => @last_date,
        "date_policy" => "weekly",
        "weekdays" => ~w(1 2 3 4 5),
        "school_dates" => "",
        "added_dates" => "",
        "removed_dates" => "",
        "confirm" => "true"
      },
      overrides
    )
  end

  defp submit_source(view, overrides) do
    render_submit(view, "source_review", %{"source" => source_params(overrides)})
  end

  describe "reviewed source" do
    test "submitting the source form accepts the reviewed dates and shows their provenance",
         context do
      {view, _route} = open_paste(context)

      assert has_element?(view, "#paste-form")
      assert has_element?(view, "#timetable-source-form")

      submit_source(view, %{
        "label" => "Harbor printed table",
        "revision" => "rev 3",
        "notes" => "Thanksgiving is not served.",
        "removed_dates" => @thanksgiving
      })

      assert has_element?(view, "#timetable-source-accepted", "Harbor printed table · rev 3")
      assert has_element?(view, "#timetable-source-accepted", "on Main")
      assert has_element?(view, "#timetable-source-accepted", "20 service dates")
      assert has_element?(view, "#timetable-source-accepted", "in 2026-11-02 – 2026-11-30")
      assert has_element?(view, "#timetable-source-accepted", "2 mapped rows")
      assert has_element?(view, "#timetable-source-accept")
      refute has_element?(view, "#timetable-source-errors")
      refute has_element?(view, "#timetable-helper-too-large")

      # The pasted rows still map to the same two feed trips.
      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-source-summary")
    end

    test "the reviewed source is only offered once the columns step resolved the paste",
         context do
      # Column B does not name a stop, so the native review keeps its column
      # issues and there is no accepted mapping to review yet.
      {view, _route} =
        open_paste(
          context,
          "Trip\tSource Stop 1\tNowhere\tSource Stop 3\n101\t06:00\t06:05\t06:10"
        )

      assert has_element?(view, "#paste-columns")
      refute has_element?(view, "#timetable-source-form")
    end

    test "editing the notes releases the accepted source and keeps the pasted timetable",
         context do
      {view, _route} = open_paste(context)
      submit_source(view, %{"label" => "Harbor printed table"})

      assert has_element?(view, "#timetable-source-accepted")

      render_change(view, "source_change", %{
        "source" => source_params(%{"label" => "Harbor printed table", "notes" => "Corrected."})
      })

      refute has_element?(view, "#timetable-source-accepted")
      refute has_element?(view, "#timetable-helper-too-large")

      # The copied timetable is untouched: the native review, its summary and
      # the editable notes are all still there.
      assert has_element?(view, "#paste-form")
      assert has_element?(view, "#paste-source-summary", "2 trip rows")
      assert has_element?(view, "#paste-review")
      assert view |> element("#timetable-source-notes") |> render() =~ "Corrected."
    end

    test "an interval that is not a date is refused inline and nothing is accepted", context do
      {view, _route} = open_paste(context)

      submit_source(view, %{"first_date" => "2026-13-01", "notes" => "Still here."})

      assert has_element?(view, "#timetable-source-errors", "The first date is not an ISO date")
      assert has_element?(view, "#timetable-source-first-date[aria-invalid='true']")
      refute has_element?(view, "#timetable-source-accepted")
      assert view |> element("#timetable-source-notes") |> render() =~ "Still here."
    end

    test "a school policy without school dates stays unresolved with the input kept", context do
      {view, _route} = open_paste(context)

      submit_source(view, %{
        "date_policy" => "school",
        "weekdays" => [],
        "school_dates" => "",
        "notes" => "School starts after Thanksgiving."
      })

      assert has_element?(view, "#timetable-source-unresolved", "No school dates were supplied")
      refute has_element?(view, "#timetable-source-accepted")

      # The refused write keeps what was typed.
      assert view |> element("#timetable-source-notes") |> render() =~ "School starts after"
      assert view |> element("#timetable-source-policy") |> render() =~ "school"
      assert has_element?(view, "#paste-form")
    end

    test "a source the helper cannot carry is refused visibly while the paste stays usable",
         context do
      route = source_route(context, Enum.to_list(360..379))

      # 366 inclusive dates over 20 copied rows puts the reviewed source past
      # the 65,536-byte ceiling the helper context enforces, while every row
      # still resolves to exactly one feed trip.
      stops = Enum.map(1..3, &"Source Stop #{&1}")
      header = Enum.join(["Trip" | stops], "\t")

      rows =
        Enum.map_join(360..379, "\n", fn minute ->
          "#{minute}\t#{clock(minute * 60)}\t#{clock(minute * 60 + 300)}\t#{clock(minute * 60 + 660)}"
        end)

      {:ok, view, _html} = live(context.conn, paste_path(context.version, route.route))

      render_submit(view, "read", %{
        "paste" => %{"text" => header <> "\n" <> rows, "layout" => "auto", "header" => "true"}
      })

      submit_source(view, %{
        "label" => "A year of Harbor tables",
        "first_date" => "2026-11-01",
        "last_date" => "2027-11-01"
      })

      assert has_element?(view, "#timetable-helper-too-large")
      assert has_element?(view, "#timetable-helper-too-large", "larger than the helper accepts")

      # The refusal is about the helper only: the accepted review, the
      # comparison controls and the native paste all remain.
      assert has_element?(view, "#timetable-source-accepted", "20 mapped rows")
      assert has_element?(view, "#paste-form")
      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-apply", "Apply")
    end
  end

  defp clock(seconds) when seconds < 24 * 3600 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    Enum.map_join(
      [hours, minutes],
      ":",
      &(&1 |> Integer.to_string() |> String.pad_leading(2, "0"))
    )
  end
end
