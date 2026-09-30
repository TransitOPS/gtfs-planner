defmodule GtfsPlannerWeb.Gtfs.BlocksConnectionChoiceLiveTest do
  # The connection drawer's choice: the three options and what each writes, the
  # R1 pre-check disabling the two explicit options and naming the day type that
  # blocks the pair, the warnings the stay option carries, the scope line over the
  # day types both trips run in, the rider table re-rendering for the chosen
  # option, and the discard guard in front of a draft the editor has not saved.
  #
  # Every case is observed through the ordinary `/gtfs/:version/blocks` route and
  # the `gap=` deep link, on the production `CatalogReadAdapter.Repo` and the
  # scoped `Blocking` context. The pre-check is the production
  # `Gtfs.check_in_seat_connections/3`, so the disabled options and the refusal
  # sentence come from the same `Blocking.InSeat.state/2` the day load and the
  # save use (CR-2). Rows are created inside the SQL Sandbox transaction and
  # rolled back; nothing here substitutes an adapter or a context.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Blocking.DayTypes

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    twelve =
      route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    twenty_four =
      route_fixture(organization.id, version.id, %{route_id: "R24", route_short_name: "24"})

    %{
      organization: organization,
      user: user,
      version: version,
      twelve: twelve,
      twenty_four: twenty_four
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp stop(context, attrs) do
    if Map.has_key?(attrs, :stop_lat) do
      stop_with_coordinates_fixture(context.organization.id, context.version.id, attrs)
    else
      GtfsPlanner.GtfsFixtures.stop_fixture(context.organization.id, context.version.id, attrs)
    end
  end

  defp coord(value), do: Decimal.new(value)

  defp trip(context, attrs) do
    attrs = Map.new(attrs)
    route_id = Map.get(attrs, :route, context.twelve.route_id)
    {first, attrs} = Map.pop(attrs, :first, "06:00:00")
    {last, attrs} = Map.pop(attrs, :last, "07:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      route_id,
      attrs
      |> Map.delete(:route)
      |> Map.put_new(:service_id, "W")
      |> Map.put_new(:trip_id, "trip_#{System.unique_integer([:positive])}")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  defp gap_url(base, from_trip, to_trip, extra \\ []) do
    base <> "?" <> URI.encode_query([{"gap", "#{from_trip.id}|#{to_trip.id}"}] ++ extra)
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp attribute_values(view, selector, attribute) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(LazyHTML.attribute(&1, attribute) |> List.first()))
  end

  defp main_stop(context) do
    stop(context, %{
      stop_id: "CHOICE_MAIN_#{System.unique_integer([:positive])}",
      stop_name: "Main St",
      stop_lat: coord("40.0200"),
      stop_lon: coord("-74.0000")
    })
  end

  # A weekday pair meeting at one stop, with a `gap=` deep link to its drawer.
  defp same_stop_pair(context, opts \\ []) do
    main = main_stop(context)

    a =
      trip(context, %{
        trip_id: Map.get(opts, :from_id, "a"),
        block_id: Map.get(opts, :block_id, "101"),
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "06:00:00",
        last: "07:00:00"
      })

    b =
      trip(context, %{
        route: context.twenty_four.route_id,
        trip_id: Map.get(opts, :to_id, "b"),
        block_id: Map.get(opts, :block_id, "101"),
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "07:10:00",
        last: "08:10:00"
      })

    {a, b, main}
  end

  describe "the pre-check" do
    setup %{organization: organization, version: version} do
      service_id = "W"

      calendar_service_fixture(organization.id, version.id, %{
        service_id: service_id,
        name: "Weekday",
        dates: @weekday_dates
      })

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "NS",
        name: "No school",
        dates: Enum.take(@weekday_dates, 1)
      })

      :ok
    end

    test "a trip running between the pair on another day type disables the two explicit options",
         context do
      {a, b, _main} = same_stop_pair(context)

      # `BIS_SH_X`'s shape: a trip of the second service runs between the pair, so
      # the pair is consecutive on the school day type and not on the other.
      trip(context, %{
        trip_id: "X",
        service_id: "NS",
        block_id: "101",
        first_stop: a.last_stop.stop_id,
        last_stop: a.last_stop.stop_id,
        first: "07:12:00",
        last: "08:12:00"
      })

      url = gap_url(blocks_path(context.version.id), a, b, day: DayTypes.key(["W"]))
      {:ok, view, _html} = live(editor_conn(context), url)

      assert has_element?(view, "#connection-choice-stay[disabled]")
      assert has_element?(view, "#connection-choice-reboard[disabled]")

      # "Not stated" removes the record rather than writing one, so the write rule
      # never refuses it and the option stays available.
      refute has_element?(view, "#connection-choice-not-stated[disabled]")

      assert has_element?(view, "#connection-blocked-reason", "Only Not stated is available.")
      assert has_element?(view, "#connection-blocked-reason", "trip X runs next on this vehicle")
      assert has_element?(view, "#connection-blocked-day-link", "Open Weekday + No school")
    end

    test "a pair that is consecutive everywhere leaves both explicit options enabled", context do
      {a, b, _main} = same_stop_pair(context)

      url = gap_url(blocks_path(context.version.id), a, b, day: DayTypes.key(["W"]))
      {:ok, view, _html} = live(editor_conn(context), url)

      refute has_element?(view, "#connection-choice-stay[disabled]")
      refute has_element?(view, "#connection-choice-reboard[disabled]")
      refute has_element?(view, "#connection-blocked-reason")
    end
  end

  describe "the rider table follows the chosen option" do
    setup %{organization: organization, version: version} do
      calendar_service_fixture(organization.id, version.id, %{
        service_id: "W",
        name: "Weekday",
        dates: @weekday_dates
      })

      :ok
    end

    test "choosing stay on an unstated same-stop pair leaves OTP unchanged and tags Transit",
         context do
      {a, b, _main} = same_stop_pair(context)

      url = gap_url(blocks_path(context.version.id), a, b)
      {:ok, view, _html} = live(editor_conn(context), url)

      # Unstated: OTP infers the link from the block, and stay writes one, so the
      # title is the same sentence either way.
      assert has_element?(
               view,
               "#gap-riders [data-app='OpenTripPlanner'][data-changes='false']",
               "Stay on board"
             )

      assert has_element?(
               view,
               "#gap-riders [data-app='Transit app']",
               "Decides from the block"
             )

      view
      |> element("#connection-form")
      |> render_change(%{
        "connection" => %{"choice" => "stay_on_board"},
        "_target" => ["connection-choice-stay"]
      })

      assert has_element?(
               view,
               "#gap-riders [data-app='OpenTripPlanner'][data-changes='false']",
               "Stay on board"
             )

      assert has_element?(
               view,
               "#gap-riders [data-app='Transit app']",
               "Stay on board"
             )

      assert has_element?(view, "#gap-riders [data-app='Transit app']", "Changes")
      refute has_element?(view, "#gap-riders [data-app='OpenTripPlanner']", "Changes")
    end
  end

  describe "the warnings inside the stay card" do
    setup %{organization: organization, version: version} do
      calendar_service_fixture(organization.id, version.id, %{
        service_id: "W",
        name: "Weekday",
        dates: @weekday_dates
      })

      :ok
    end

    test "an empty move names its distance once stay is chosen", context do
      # The exact 370 m great-circle separation the seeded browser move uses.
      here =
        stop(context, %{
          stop_id: "CHOICE_MOVE_A_#{System.unique_integer([:positive])}",
          stop_name: "Depot Row",
          stop_lat: coord("40.80000000"),
          stop_lon: coord("-73.94000000")
        })

      there =
        stop(context, %{
          stop_id: "CHOICE_MOVE_B_#{System.unique_integer([:positive])}",
          stop_name: "Depot Row North",
          stop_lat: coord("40.80332746"),
          stop_lon: coord("-73.94000000")
        })

      a =
        trip(context, %{
          trip_id: "ma",
          block_id: "MOVE",
          first_stop: here.stop_id,
          last_stop: here.stop_id,
          first: "14:00:00",
          last: "14:30:00"
        })

      b =
        trip(context, %{
          route: context.twenty_four.route_id,
          trip_id: "mb",
          block_id: "MOVE",
          first_stop: there.stop_id,
          last_stop: there.stop_id,
          first: "14:40:00",
          last: "15:10:00"
        })

      url = gap_url(blocks_path(context.version.id), a, b)
      {:ok, view, _html} = live(editor_conn(context), url)

      # Nothing is chosen yet, so nothing is warned about.
      refute has_element?(view, "[data-role='connection-choice-warning']")

      view
      |> element("#connection-form")
      |> render_change(%{
        "connection" => %{"choice" => "stay_on_board"},
        "_target" => ["connection-choice-stay"]
      })

      assert has_element?(view, "[data-warning='distance']", "370 m apart")
    end

    test "a stop where pickup is not allowed warns that OpenTripPlanner drops the record",
         context do
      main = main_stop(context)

      a =
        trip(context, %{
          trip_id: "pa",
          block_id: "PICKUP",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:00:00",
          last: "07:25:00"
        })

      b =
        trip(context, %{
          route: context.twenty_four.route_id,
          trip_id: "pb",
          block_id: "PICKUP",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:35:00",
          last: "08:00:00",
          first_pickup_type: 1
        })

      url = gap_url(blocks_path(context.version.id), a, b)
      {:ok, view, _html} = live(editor_conn(context), url)

      view
      |> element("#connection-form")
      |> render_change(%{
        "connection" => %{"choice" => "stay_on_board"},
        "_target" => ["connection-choice-stay"]
      })

      assert has_element?(
               view,
               "[data-warning='pickup']",
               "doesn't allow pickup at its first stop"
             )

      assert has_element?(view, "[data-warning='pickup']", "OpenTripPlanner drops this record")
    end
  end

  describe "the scope line" do
    setup %{organization: organization, version: version} do
      # Two services whose dates overlap on one day, so the pair runs on two day
      # types: {W} over the two remaining dates and {W, NS} over the shared one.
      calendar_service_fixture(organization.id, version.id, %{
        service_id: "W",
        name: "Weekday",
        dates: @weekday_dates
      })

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "NS",
        name: "No school",
        dates: Enum.take(@weekday_dates, 1)
      })

      :ok
    end

    test "it sums the date counts of the day types naming both services", context do
      {a, b, _main} = same_stop_pair(context)

      url = gap_url(blocks_path(context.version.id), a, b, day: DayTypes.key(["W"]))
      {:ok, view, _html} = live(editor_conn(context), url)

      # 3 dates in total: 1 on the day type that also runs the no-school service
      # and 2 on the weekday-only one, each date counted once.
      assert has_element?(view, "#connection-scope", "Applies on all 3 dates both trips run")
      assert has_element?(view, "#connection-scope", "No school + Weekday (1)")
      assert has_element?(view, "#connection-scope", "Weekday (2)")
    end
  end

  describe "the discard guard" do
    setup %{organization: organization, version: version} do
      calendar_service_fixture(organization.id, version.id, %{
        service_id: "W",
        name: "Weekday",
        dates: @weekday_dates
      })

      :ok
    end

    test "closing with a draft differing from the saved choice asks before discarding", context do
      {a, b, _main} = same_stop_pair(context)

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      url = gap_url(blocks_path(context.version.id), a, b)
      {:ok, view, _html} = live(editor_conn(context), url)

      # The saved type 4 record is the drawer's starting draft, so nothing is
      # dirty yet and Close is the plain close.
      assert has_element?(view, "#connection-choice-stay[checked]")
      assert has_element?(view, "[data-choice='stay_on_board'][data-saved='true']", "Saved")
      refute has_element?(view, "#connection-discard[data-open='true']")

      view
      |> element("#connection-form")
      |> render_change(%{
        "connection" => %{"choice" => "must_reboard"},
        "_target" => ["connection-choice-reboard"]
      })

      assert has_element?(view, "#connection-discard[data-open='false']")

      view |> element("#gap-drawer-close") |> render_click()

      assert has_element?(view, "#connection-discard[data-open='true']", "Discard this change?")
      assert has_element?(view, "#connection-discard-cancel", "Keep editing")
      assert has_element?(view, "#connection-discard-confirm", "Discard change")

      # Keep editing puts the drawer and the draft back exactly as they were.
      view |> element("#connection-discard-cancel") |> render_click()

      refute has_element?(view, "#connection-discard[data-open='true']")
      assert has_element?(view, "#gap-drawer[data-open='true']")
      assert has_element?(view, "#connection-choice-reboard[checked]")
    end

    test "discarding replays the close the confirmation stood in front of", context do
      {a, b, _main} = same_stop_pair(context)

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      url = gap_url(blocks_path(context.version.id), a, b)
      {:ok, view, _html} = live(editor_conn(context), url)

      view
      |> element("#connection-form")
      |> render_change(%{
        "connection" => %{"choice" => "must_reboard"},
        "_target" => ["connection-choice-reboard"]
      })

      view |> element("#gap-drawer-close") |> render_click()
      assert has_element?(view, "#connection-discard[data-open='true']")

      view |> element("#connection-discard-confirm") |> render_click()

      refute has_element?(view, "#connection-discard[data-open='true']")
      refute has_element?(view, "#gap-drawer")
    end
  end

  describe "the options themselves" do
    setup %{organization: organization, version: version} do
      calendar_service_fixture(organization.id, version.id, %{
        service_id: "W",
        name: "Weekday",
        dates: @weekday_dates
      })

      :ok
    end

    test "the three options say what each one writes", context do
      {a, b, _main} = same_stop_pair(context)

      url = gap_url(blocks_path(context.version.id), a, b)
      {:ok, view, _html} = live(editor_conn(context), url)

      assert has_element?(view, "#connection-form", "Can riders stay on board?")

      assert attribute_values(
               view,
               "#connection-form [data-role='connection-choice']",
               "data-choice"
             ) == ["not_stated", "stay_on_board", "must_reboard"]

      assert has_element?(
               view,
               "#connection-choice-not-stated + span",
               "Writes no transfer record"
             )

      assert has_element?(view, "#connection-choice-stay + span", "type 4")
      assert has_element?(view, "#connection-choice-reboard + span", "type 5")
    end

    test "a two-record pair preselects nothing and tags no option as saved", context do
      {a, b, main} = same_stop_pair(context)

      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 4,
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: main.stop_id,
        to_stop_id: main.stop_id
      })

      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 5,
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: nil,
        to_stop_id: nil
      })

      url = gap_url(blocks_path(context.version.id), a, b)
      {:ok, view, _html} = live(editor_conn(context), url)

      refute has_element?(view, "#connection-choice-stay[checked]")
      refute has_element?(view, "#connection-choice-reboard[checked]")
      refute has_element?(view, "#connection-choice-not-stated[checked]")
      refute has_element?(view, "[data-role='connection-saved-tag']")
    end
  end
end
