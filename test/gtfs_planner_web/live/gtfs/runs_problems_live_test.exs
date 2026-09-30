defmodule GtfsPlannerWeb.Gtfs.RunsProblemsLiveTest do
  @moduledoc """
  EV-31: the problems drawer, with orphan removal.

  Two claims are tested here that a rendered drawer can otherwise fake. The
  button's count must be what the drawer LISTS, so the two are computed from
  one function and the test compares them rather than asserting a number twice.
  And the uncovered work is ONE item however many blocks it spans — a drawer
  that listed it per block would show three items for one problem, and its
  count would be wrong in the same way.

  The orphan case is the only one here that writes. It deletes rows that
  `Runs.load_runs/3` already excludes from every run it derives, so the
  assertion is about those rows going and the day reading the same afterwards.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Repo

  @moduletag :ev_31
  @moduletag timeout: 120_000

  setup do
    %{user: user_fixture()}
  end

  # The shared world: run 1001 over the head of block 101 and the tail of block
  # 102, so the day has a run finding, uncovered work, and both.
  defp world(ctx) do
    user = ctx.user
    w = runs_version_fixture()

    [first_101 | _tail_101] = w.blocks["101"]
    [_first_102, second_102] = w.blocks["102"]

    for trip <- [first_101, second_102] do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: "1001"
      })
    end

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: w.organization.id,
      roles: ["pathways_studio_editor"]
    })

    w
  end

  # Two run assignments whose trips are not in this day type at all: what is
  # left behind when a service group is removed.
  defp with_orphans(w) do
    import GtfsPlanner.BlockingFixtures
    now = DateTime.utc_now()
    [first | _] = w.blocks["101"]
    route_id = first.route_id

    for n <- 1..2 do
      # A trip on a service the weekday day type does not run: what a removed
      # service group leaves behind. A made-up `trip_id` would be refused by the
      # foreign key rather than exercising anything.
      trip =
        blocked_trip_fixture(w.organization.id, w.version.id, route_id, %{
          service_id: "SU",
          block_id: "GONE#{n}",
          trip_id: "GONE#{n}"
        })

      Repo.insert!(%TripRun{
        organization_id: w.organization.id,
        gtfs_version_id: w.version.id,
        trip_id: trip.id,
        day_type_key: w.day_type_key,
        run_id: "9001",
        inserted_at: now,
        updated_at: now
      })
    end

    w
  end

  # A day with nothing to review.
  #
  # The geometry has to line up or the day is never clean, and this took three
  # attempts to find. Every trip in ONE run is six pieces, and the fixture's
  # block then raises `cannot_reach_piece` between them; one run per trip leaves
  # runs that begin and end away from a marked relief, which raises
  # `not_at_relief`.
  #
  # What works is runs of TWO trips, split exactly at the block's marked relief
  # windows: each run is then a single piece whose ends are either the block's
  # own ends or a marked relief, which is the arrangement the checks accept.
  defp clean_world(ctx) do
    user = ctx.user
    w = runs_version_fixture()
    [a, b, c, d] = w.blocks["101"]
    [e, f] = w.blocks["102"]

    # `max_piece_minutes` lives on the BLOCK rules, not on the crew settings, so
    # a day can still be unclean after every trip is covered by relief-aligned
    # runs. It has to be widened here or `piece_too_long` is raised for every
    # run in the fixture and the drawer is never empty.
    {:ok, _} =
      Gtfs.update_blocking_settings(w.organization.id, w.version.id, %{max_piece_minutes: 720})

    # A tuple is not Enumerable, so `{{a, b}, "1001"}` would hand the inner
    # `for` a tuple of two trips rather than a list to walk.
    for {trips, run_id} <- [{[a, b], "1001"}, {[c, d], "1002"}, {[e, f], "1003"}] do
      for trip <- trips do
        trip_run_fixture(w.organization.id, w.version.id, %{
          trip: trip,
          day_type_key: w.day_type_key,
          run_id: run_id
        })
      end
    end

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: w.organization.id,
      roles: ["pathways_studio_editor"]
    })

    w
  end

  defp open(ctx, w) do
    conn = log_in_user(ctx.conn, ctx.user, organization: w.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{w.version.id}/runs")
    view
  end

  defp show(view), do: view |> element("#runs-review-problems") |> render_click()

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp text(view, selector) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp attribute(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp codes(view) do
    view
    |> doc()
    |> LazyHTML.query("[data-role=problems-finding]")
    |> LazyHTML.attribute("data-code")
  end

  defp orphan_rows(w) do
    Repo.all(
      from(row in TripRun,
        where: row.organization_id == ^w.organization.id and row.gtfs_version_id == ^w.version.id
      )
    )
    |> length()
  end

  describe "the header action" do
    test "it names the count and is primary while anything needs attention", ctx do
      w = world(ctx)
      view = open(ctx, w)

      count = attribute(view, "#runs-review-problems", "data-count") |> String.to_integer()

      assert has_element?(view, "#runs-review-problems", "Review problems · #{count}")
      assert attribute(view, "#runs-review-problems", "data-count") != "0"
      assert render(view) =~ "btn-primary"
    end

    test "the count is what the drawer lists", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show(view)

      # The button and the drawer must not be able to disagree. Comparing the
      # two is the assertion; asserting a number twice would only prove the
      # number twice.
      listed = length(codes(view)) + 1
      summary = text(view, "#runs-problems-summary")

      assert summary =~ "#{listed} to review"
      assert attribute(view, "#runs-review-problems", "data-count") == to_string(listed)
    end

    test "the uncovered work counts once, however many blocks it spans", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show(view)

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)

      # Both blocks are uncovered in this world, so counting per block would
      # add two where the drawer shows one section.
      assert length(day.derived.uncovered) == 2
      assert has_element?(view, "#runs-problems-uncovered")
      assert codes(view) |> Enum.all?(&(&1 != :uncovered_work and &1 != "uncovered_work"))
    end

    test "with nothing to review it is not primary", ctx do
      w = clean_world(ctx)

      view = open(ctx, w)

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      assert day.derived.uncovered == []
      assert Enum.filter(day.derived.findings, &(&1.severity in [:error, :warning])) == []

      assert attribute(view, "#runs-review-problems", "data-count") == "0"
      # Scoped to the Review problems BUTTON, not to the page as a string.
      #
      # It used to be a page-wide `refute render(view) =~ "btn-primary"`, which
      # passed until step 34 added the Crew rules drawer: that drawer keeps one
      # element in the DOM and toggles `data-open` on it, so its Save button is
      # present in the HTML whether or not the drawer is open. A CLOSED dialog's
      # controls are inert and invisible, so they are not the primary action the
      # reader can see, and counting them made this assertion about markup rather
      # than about the surface.
      refute attribute(view, "#runs-review-problems", "class") =~ "btn-primary"
    end
  end

  describe "the drawer" do
    test "it is not on screen until the button is pressed", ctx do
      w = world(ctx)
      view = open(ctx, w)

      # The container is always in the DOM and carries `data-open`; the drawer
      # component keeps one element and toggles it, so `has_element?` alone
      # would be true before the button is ever pressed.
      assert attribute(view, "#runs-problems-drawer-overlay", "data-open") == "false"
      show(view)
      assert attribute(view, "#runs-problems-drawer-overlay", "data-open") == "true"
    end

    test "it groups findings under their run, with a link to it", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show(view)

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs
      assert run.findings != []

      # One list item per finding, so a finding rendered twice would show here.
      for finding <- run.findings do
        assert length(Enum.filter(codes(view), &(&1 == to_string(finding.code)))) == 1
      end

      assert has_element?(view, "#runs-problems-run-1001", "Run 1001")
      assert has_element?(view, "[data-role=problems-run-link]", "Open run 1001")
    end

    test "the run link opens that run's drawer", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show(view)

      view |> element("[data-role=problems-run-link]") |> render_click()

      # `open_run` assigns the drawer rather than patching, so the claim is the
      # run drawer being open on THAT run.
      #
      # The chart's own `#runs-run-1001` is no evidence of that: it is on screen
      # whether or not the link carried a run id, so a link posting the wrong
      # run would still pass. The drawer's summary is the claim.
      assert has_element?(view, "#run-drawer")
      # The drawer's TITLE carries the run, not its summary line.
      assert text(view, "#run-drawer-title") == "Run 1001"
    end

    test "the uncovered item links to the Uncovered tab", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show(view)

      link = attribute(view, "[data-role=problems-uncovered-link]", "href")
      assert link =~ "panel=uncovered"
      assert link =~ "day=#{w.day_type_key}"
    end

    test "each finding carries its severity in words", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show(view)

      # Icon plus WORDS, the rule step 24 settled: a colour alone is not a
      # severity a reader can act on or a screen reader can read out. Both
      # halves are asserted, because a "plus" rule only holds while each half is
      # present — asserting the word alone would still pass with the icon gone.
      assert has_element?(view, "[data-role=problems-finding]", "Warning")

      icon =
        attribute(view, "[data-role=problems-finding] .hero-exclamation-triangle-mini", "class")

      assert icon != nil

      # The attribute is the DOMAIN's severity, not a constant, so it cannot
      # drift from the finding it labels.
      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)

      expected =
        day.derived.runs |> Enum.flat_map(& &1.findings) |> Enum.map(& &1.severity) |> Enum.uniq()

      assert expected != []

      assert to_string(hd(expected)) ==
               attribute(view, "[data-role=problems-finding]", "data-severity")
    end

    test "it closes again", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show(view)

      assert attribute(view, "#runs-problems-drawer-overlay", "data-open") == "true"
      view |> element("#runs-problems-drawer-close") |> render_click()
      assert attribute(view, "#runs-problems-drawer-overlay", "data-open") == "false"
    end
  end

  describe "orphan assignments" do
    test "with none there is no notice and no Remove", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show(view)

      refute has_element?(view, "#runs-problems-orphans")
      refute has_element?(view, "#runs-remove-orphans")
    end

    test "with some the notice says how many and what they are", ctx do
      w = world(ctx) |> with_orphans()
      view = open(ctx, w)
      show(view)

      # The count is the DOMAIN's, so it cannot drift from the rows that exist.
      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      notice = Enum.find(day.derived.findings, &(&1.code == :orphan_assignments))
      assert notice.detail.count == 2

      assert has_element?(view, "#runs-problems-orphans", "2 assignments")

      assert text(view, "#runs-problems-orphans") =~
               "2 assignments are for trips no longer in this day type."

      assert attribute(view, "#runs-problems-orphans", "data-count") == "2"
    end

    test "Remove deletes them and hides the notice", ctx do
      w = world(ctx) |> with_orphans()
      view = open(ctx, w)
      show(view)

      before = orphan_rows(w)
      assert before > 2

      view |> element("#runs-remove-orphans") |> render_click()

      # Re-read from the database: the toast saying "removed" is the page's
      # claim, and the rows are the fact.
      assert orphan_rows(w) == before - 2
      refute has_element?(view, "#runs-problems-orphans")
      refute has_element?(view, "#runs-remove-orphans")
    end

    test "it says what it deleted, and the day still reads the same", ctx do
      w = world(ctx) |> with_orphans()
      view = open(ctx, w)
      show(view)

      {:ok, before} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      runs_before = Enum.map(before.derived.runs, & &1.run_id)

      view |> element("#runs-remove-orphans") |> render_click()

      assert text(view, "[data-role=toast-text]") == "2 old run assignments removed."

      # Orphan rows are on no chart and in no run, so removing them must not
      # change a single run. A drawer that re-derived differently afterwards
      # would be a page that changed the schedule by deleting a notice.
      {:ok, after_removal} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      assert Enum.map(after_removal.derived.runs, & &1.run_id) == runs_before
    end

    test "a day with no problems left says so", ctx do
      w = clean_world(ctx) |> with_orphans()

      view = open(ctx, w)
      show(view)
      view |> element("#runs-remove-orphans") |> render_click()

      # The orphan notice was the only thing in the drawer; with it gone the
      # drawer says so rather than showing an empty list of nothing.
      #
      # `data-open` rather than `has_element?`, because the drawer container is
      # always in the DOM and a closed one matches `has_element?` just as well
      # as an open one. Removal must leave the drawer OPEN too: closing it would
      # hide the very message that says the work is done.
      assert attribute(view, "#runs-problems-drawer-overlay", "data-open") == "true"

      assert has_element?(
               view,
               "#runs-problems-drawer",
               "Every run passes its checks, and every blocked trip is in a run."
             )
    end
  end
end
