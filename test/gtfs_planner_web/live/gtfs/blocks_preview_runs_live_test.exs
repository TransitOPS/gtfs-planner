defmodule GtfsPlannerWeb.Gtfs.BlocksPreviewRunsLiveTest do
  # The Suggested blocks panel names the runs a proposal reaches, and links to
  # them.
  #
  # The surface is Blocks rather than Runs, and the behavior is a sentence plus a
  # link: before applying a blocks suggestion, a planner can see how many saved
  # runs it will disturb and go look at them.
  #
  # The count is read from the domain in every case that asserts a number, so a
  # count that happened to match a hardcoded 2 would prove nothing. It is read
  # over trip DB UUIDs (`move.trip.id`), not GTFS trip ids, because `TripRun`
  # joins on the UUID.
  #
  # Rows are created inside the SQL Sandbox transaction and rolled back; nothing
  # here substitutes an adapter, a context or a plan.
  #
  # Run with:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_preview_runs_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [select: 3, where: 3]

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Repo

  @moduletag :ev_36
  @moduletag timeout: 120_000

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    # Two day types, because one cannot show that the count is over runs rather
    # than over day types.
    dates = for(offset <- 0..25, do: Date.add(~D[2026-10-05], offset))

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "WK",
      name: "Weekday",
      dates: dates
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SA",
      name: "Saturday",
      dates: Enum.filter(dates, &(Date.day_of_week(&1) == 6))
    })

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R12",
        route_short_name: "12",
        route_long_name: "Riverside"
      })

    for {stop_id, name, lat} <- [
          {"AB_RS_A", "Riverside Station", "40.0100"},
          {"AB_RS_B", "Riverside Station", "40.0100"},
          {"AB_VALLEY", "Valley College", "40.0200"},
          {"AB_MKT", "Market Square", "40.0670"}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0000")
      })
    end

    context = %{organization: organization, user: user, version: version, route: route}

    garage_fixture(organization.id, %{
      garage_id: "GAR",
      name: "Riverside Garage",
      lat: Decimal.new("40.0050"),
      lon: Decimal.new("-74.0000")
    })

    trips =
      for {trip_id, block_id, first, last} <- [
            {"6101", "101", "06:00:00", "06:35:00"},
            {"8101", "101", "06:43:00", "07:18:00"},
            {"6105", "102", "09:00:00", "09:30:00"},
            {"8105", "102", "10:00:00", "10:30:00"},
            {"6106", nil, "13:00:00", "13:30:00"}
          ] do
        trip!(context, %{
          trip_id: trip_id,
          block_id: block_id,
          service_id: service_for(first),
          first: first,
          last: last
        })
      end

    context = Map.put(context, :trip, List.first(trips))
    context
  end

  # Weekday trips run on the weekday service, the rest on Saturday, so BOTH day
  # types hold trips and a Blocks proposal can reach runs on either.
  defp service_for("13:00:00"), do: "SA"
  defp service_for(_first), do: "WK"

  defp trip!(context, attrs) do
    attrs = Map.new(attrs)
    {first, attrs} = Map.pop(attrs, :first)
    {last, attrs} = Map.pop(attrs, :last)

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.route.route_id,
      %{
        service_id: "WK",
        first_stop: "AB_RS_A",
        last_stop: "AB_VALLEY"
      }
      |> Map.merge(attrs)
      |> Map.put(:first_arrival, first)
      |> Map.put(:first_departure, first)
      |> Map.put(:last_arrival, last)
      |> Map.put(:last_departure, last)
    )
  end

  defp open(context) do
    # A FRESH conn per open: `live/2` consumes the conn it is given.
    conn = log_in_user(context.conn, context.user, organization: context.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{context.version.id}/blocks")
    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp text(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp attribute(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Preview builds the plan under `start_async`, so the panel follows the task's
  # result rather than the click. Waited for rather than assumed, so a failure is
  # a failed assertion and not a stalled suite.
  defp preview(_context, view, scope \\ "replace_all") do
    view |> element("#blocks-suggest") |> render_click()
    # `replace_all` replans EVERY trip, so its moves reach trips that are already
    # in saved runs. The default scope only plans unassigned work, and the
    # fixture's trips are all in runs by then, so it would move nothing and the
    # count would be zero for a reason that has nothing to do with the feature.
    view |> form("#suggest-scope-form", %{"scope" => scope}) |> render_change()
    view |> element("#suggest-preview") |> render_click()

    assert wait_for(fn -> has_element?(view, "#suggestion") end) == :ok
    view
  end

  # Cut every block on every day type, so saved runs exist on BOTH and a Blocks
  # proposal has real trips to move. Goes through the domain's own path.
  defp cut_runs(context) do
    {:ok, day} = Blocking.load_day(context.organization.id, context.version.id, nil)

    for day_type <- day.day_types do
      {:ok, plan} =
        Gtfs.suggest_runs(context.organization.id, context.version.id, day_type.key, :replace_all)

      {:ok, _result} =
        Gtfs.apply_run_plan(
          GtfsPlanner.AccountsFixtures.editor_audit_fixture(
            context.organization.id,
            context.version.id
          ),
          plan
        )
    end

    context
  end

  # ONE trip in ONE run, through the page's own write path.
  #
  # The other trips stay uncovered, so a `replace_all` proposal moves all of them
  # and reaches only this one run — which is what makes the count exactly one.
  defp cut_one_run(context) do
    # Day types are keyed by a hash, not by their service ids, so the key is
    # read back off the day. The weekday day type is chosen because the captured
    # trip runs on the weekday service, so it is one a proposal will move.
    {:ok, day} = Blocking.load_day(context.organization.id, context.version.id, nil)

    day_type_key =
      Enum.find_value(day.day_types, fn day_type ->
        if day_type.service_ids == [context.trip.service_id], do: day_type.key
      end)

    refute is_nil(day_type_key), "the fixture must have a day type for #{context.trip.service_id}"

    moves = [%{trip_id: context.trip.id, from: nil, to: :new}]

    {:ok, _result} =
      Gtfs.apply_run_moves(
        GtfsPlanner.AccountsFixtures.editor_audit_fixture(
          context.organization.id,
          context.version.id
        ),
        day_type_key,
        moves
      )

    context
  end

  defp run_count(context) do
    version_id = context.version.id

    GtfsPlanner.Gtfs.TripRun
    |> where([t], t.gtfs_version_id == ^version_id)
    |> select([t], t.run_id)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp day_type_count(context) do
    {:ok, day} = Blocking.load_day(context.organization.id, context.version.id, nil)
    length(day.day_types)
  end

  describe "the line" do
    test "is absent when the proposal touches no run", context do
      assert run_count(context) == 0

      view = preview(context, open(context))

      # The UX obligation is "hidden at zero": a line reading "0 runs" would be
      # noise on every proposal that happens to touch nothing.
      refute has_element?(view, "#suggestion-runs-touched")
      refute view |> render() =~ "move trips in 0 run"
    end

    test "names the domain's own count and links to Runs for that day", context do
      context = cut_runs(context)

      saved_runs = run_count(context)
      day_types = day_type_count(context)

      assert day_types == 2, "this case is only meaningful with runs on two day types"
      assert saved_runs > 0

      view = preview(context, open(context))

      # The EXPECTED count, from the same plan and the same domain function the
      # page uses — so a hardcoded number cannot satisfy it.
      plan = assigns(view).plan_preview
      trip_ids = plan.moves |> Enum.map(& &1.trip.id) |> Enum.uniq()
      expected = Gtfs.count_runs_for_trips(context.organization.id, context.version.id, trip_ids)

      assert expected > 0,
             "the fixture must have runs in the moved trips for this case to mean anything"

      assert attribute(view, "#suggestion-runs-touched", "data-runs") ==
               Integer.to_string(expected)

      body = text(view, "#suggestion-runs-touched")

      # Whitespace-tolerant: the formatter may wrap between the count and its
      # noun, and a literal match would then fail on layout, not content.
      # The trailing period is load-bearing: without it `run` also matches inside
      # `runs`, and a component that always rendered the singular would pass.
      assert Regex.match?(~r/move trips in\s+#{expected}\s+runs?\./, body),
             "the line must name the run count; got: #{body}"

      # The fixture's full cut touches more than one run, so the noun is plural
      # here and the singular is pinned by the "a count of one" case.
      assert body =~ "runs. Review them on Runs after applying."

      refute body =~ "1 runs"

      assert body =~ "Review them on Runs after applying."

      assert has_element?(
               view,
               ~s(#suggestion-runs-touched a[href="/gtfs/#{context.version.id}/runs?day=#{plan.day_type_key}"])
             )
    end

    test "a run on two day types is two runs", context do
      context = cut_runs(context)

      view = preview(context, open(context))
      count = attribute(view, "#suggestion-runs-touched", "data-runs")

      plan = assigns(view).plan_preview
      trip_ids = plan.moves |> Enum.map(& &1.trip.id) |> Enum.uniq()

      # Counted from the assignments, independently of the page's helper.
      #
      # A run's identity is `{day_type_key, run_id}`, so one run id saved on two
      # day types is two pieces of saved work and must read as two. Counting
      # distinct run ids alone would say 1 here, which is the wrong answer for a
      # planner deciding what to go and look at: they will meet two separate
      # pieces of work on the page.
      expected =
        GtfsPlanner.Gtfs.TripRun
        |> where([t], t.trip_id in ^trip_ids)
        |> select([t], {t.day_type_key, t.run_id})
        |> Repo.all()
        |> Enum.uniq()
        |> length()

      assert count == Integer.to_string(expected)

      assert count ==
               Integer.to_string(
                 Gtfs.count_runs_for_trips(context.organization.id, context.version.id, trip_ids)
               )

      # And the fixture really does put the same run on both day types, so the
      # trap this test exists for is present rather than hypothetical.
      assert day_type_count(context) == 2

      distinct_run_ids =
        GtfsPlanner.Gtfs.TripRun
        |> where([t], t.trip_id in ^trip_ids)
        |> select([t], t.run_id)
        |> Repo.all()
        |> Enum.uniq()
        |> length()

      assert expected > distinct_run_ids,
             "the fixture must share a run id across day types for this case to mean anything"
    end
  end

  describe "a count of one" do
    test "reads as one run, in the singular", context do
      # The fixture's full cut produces TWO touched runs, so every case above
      # would be satisfied by a hardcoded "2" or by an unconditional plural.
      # Cutting a SINGLE run gives a count of exactly one, which is the only way
      # to pin the singular and to make a hardcoded number fail.
      context = cut_one_run(context)

      assert run_count(context) == 1

      view = preview(context, open(context))

      assert attribute(view, "#suggestion-runs-touched", "data-runs") == "1"

      body = text(view, "#suggestion-runs-touched")

      assert Regex.match?(~r/move trips in\s+1\s+run\./, body),
             "a count of one must read in the singular; got: #{body}"

      # The plural form must be GONE, not merely accompanied by the singular.
      assert not (body =~ "1 runs")
    end
  end

  describe "computed once, not per render" do
    test "the count is an assign taken when the preview was built", context do
      context = cut_runs(context)
      view = preview(context, open(context))

      assert Integer.to_string(assigns(view).runs_touched) ==
               attribute(view, "#suggestion-runs-touched", "data-runs")

      # Every one of these re-renders the panel. A query in `render/1` would run
      # again on each; an assign cannot. The value is unchanged either way, which
      # is the point: it is a fact about the plan, not a reading of the page.
      view |> element("#blocks-day-form") |> render_change(%{"day" => nil})

      assert has_element?(view, "#suggestion-runs-touched")

      assert Integer.to_string(assigns(view).runs_touched) ==
               attribute(view, "#suggestion-runs-touched", "data-runs")
    end

    test "discarding clears the count with the preview", context do
      context = cut_runs(context)
      view = preview(context, open(context))
      assert assigns(view).runs_touched > 0

      view |> element("#discard-suggestion") |> render_click()

      refute has_element?(view, "#suggestion")
      refute has_element?(view, "#suggestion-runs-touched")

      # The ASSIGN, not just the line. `refute has_element?/2` alone would pass
      # even with a stale count left in the socket, because the panel is hidden
      # for want of a plan rather than for want of a count — and the next
      # preview would then show the previous proposal's figure.
      assert assigns(view).runs_touched == 0
    end
  end

  # Waited for rather than assumed, so a slow `start_async` is a failed
  # assertion and not a stalled suite. The preview's plan arrives as a task
  # result, which is why the panel cannot be asserted on synchronously.
  defp wait_for(condition, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(condition, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> Process.sleep(25) && do_wait(fun, deadline)
    end
  end
end
