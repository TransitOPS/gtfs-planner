defmodule GtfsPlannerWeb.Gtfs.RunsSuggestLiveTest do
  @moduledoc """
  The Suggest runs drawer and the inline suggestion preview.

  The claim is narrow and worth stating exactly, because a preview that looks
  right but wrote a row would satisfy most of the assertions below: a suggestion
  is drawn, never saved. So every case here is paired with a count of the saved
  rows taken either straight from the database or through the page's own "before"
  figure, and the counts must not move. The independent check — that `trip_runs`
  is untouched — is what makes the rendering assertions mean something.

  The four figures in the panel are read from the plan, so the test recomputes
  them from `Gtfs.suggest_runs/4` and compares both directions. A panel that
  rendered one correct number and three invented ones would pass a weaker test.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Repo

  @moduletag :ev_34
  @moduletag timeout: 120_000

  setup do
    %{conn: build_conn(), user: user_fixture()}
  end

  # `conn` is rebuilt per case by ConnCase, so each `open/2` gets a session of
  # its own. `live/2` consumes the conn it is given.

  defp world(ctx) do
    w = runs_version_fixture()

    Accounts.create_user_org_membership(%{
      user_id: ctx.user.id,
      organization_id: w.organization.id,
      roles: ["pathways_studio_editor"]
    })

    w
  end

  defp open(ctx, w) do
    # A FRESH conn per open: `live/2` consumes the conn it is given, and reusing
    # one from a previous case silently re-uses a closed session.
    conn = log_in_user(ctx.conn, ctx.user, organization: w.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{w.version.id}/runs")
    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp text(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp attribute(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp view_for("runs-timeline-body"), do: "timeline"
  defp view_for(_body), do: "list"

  defp open_suggest(view) do
    view |> element("#runs-suggest") |> render_click()
  end

  defp preview(view) do
    view |> element("#runs-preview") |> render_click()
  end

  defp plan_for(w, scope) do
    {:ok, plan} =
      Gtfs.suggest_runs(w.organization.id, w.version.id, w.day_type_key, scope)

    plan
  end

  # The saved assignments, read DIRECTLY from the table. This is the independent
  # half of the step's claim: the page's own counts could be wrong in the same
  # way the panel's figures are, so the "nothing was written" assertion is made
  # against rows and not against rendered text.
  # The shared `runs_version_fixture` has BLOCKS AND NO RUNS — it is a first-use
  # day, which is why steps 21 and 35 needed their own fixtures. Half of this
  # step's cases are about runs that ALREADY EXIST: a suggestion that keeps their
  # numbers, changed rows next to unchanged ones, a run drawer to refuse, and a
  # Discard that has something to restore. So they need a day that has been cut.
  #
  # `replace_all` is the right way to do it: it is the domain's own path, and it
  # is the same scope the rebuild cases preview, so the fixture cannot disagree
  # with the feature about what a rebuild produces.
  defp with_runs(w) do
    {:ok, plan} = Gtfs.suggest_runs(w.organization.id, w.version.id, w.day_type_key, :replace_all)
    {:ok, _result} = Gtfs.apply_run_plan(w.organization.id, w.version.id, plan)
    w
  end

  # A day that has runs AND uncovered work.
  #
  # Neither extreme will do. The bare fixture has no runs at all, so "keeps
  # current runs and their numbers" has nothing to keep; a full rebuild covers
  # everything, so the uncovered scope is correctly disabled and there is nothing
  # for it to add. Covering ONE of the fixture's two uncovered segments leaves
  # both halves present, which is the only state in which the uncovered scope
  # means anything.
  #
  # It goes through the same `apply_run_moves` the page's Create run uses, so the
  # fixture cannot drift from the feature's own write path.
  defp partly_covered(w) do
    {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
    [segment | _rest] = day.derived.uncovered

    moves = Enum.map(segment.trips, fn trip -> %{trip_id: trip.id, from: nil, to: :new} end)

    {:ok, _result} =
      Gtfs.apply_run_moves(w.organization.id, w.version.id, w.day_type_key, moves)

    w
  end

  defp uncovered_trip_count(w) do
    {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)

    day.derived.uncovered
    |> Enum.map(fn segment -> length(segment.trips) end)
    |> Enum.sum()
  end

  defp saved_run_ids(w) do
    import Ecto.Query

    GtfsPlanner.Gtfs.TripRun
    |> where([t], t.gtfs_version_id == ^w.version.id)
    |> select([t], t.run_id)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp uncovered_only(view, w) do
    view |> open_suggest()
    # The radio is DISABLED on a day with no uncovered work, and clicking it then
    # is a test error rather than a product one — so only click what is offered.
    if has_element?(view, "#runs-scope-uncovered[disabled]") do
      view |> element("#runs-scope-rebuild") |> render_click()
      view |> preview()
      plan_for(w, :replace_all)
    else
      view |> element("#runs-scope-uncovered") |> render_click()
      view |> preview()
      plan_for(w, :uncovered_only)
    end
  end

  describe "the drawer" do
    test "opens on the page and offers both scopes", ctx do
      w = world(ctx)
      view = open(ctx, w)

      refute has_element?(view, "#runs-suggest-drawer-overlay[data-open=\"true\"]")

      open_suggest(view)

      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open=\"true\"]")
      assert has_element?(view, "#runs-scope-uncovered")
      assert has_element?(view, "#runs-scope-rebuild")
      assert has_element?(view, "#runs-preview")
    end

    test "names the rules it will use, from the day rather than a constant", ctx do
      w = world(ctx)
      view = open(ctx, w)

      open_suggest(view)

      body = text(view, "#runs-suggest-drawer")

      assert body =~ "Rules used"
      # The drawer's own sentence about what the scope would do.
      assert body =~ "Cut blocks at relief windows and pair the pieces into runs"
      assert body =~ "Nothing is saved until you apply"

      # The VALUES, not just the headings. Each figure is read from the loaded
      # day and the crew, so a constant in the markup cannot pass — and a
      # constant here would be worse than a missing value, because a reader
      # deciding whether to trust a suggestion is reading them.
      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      crew = day.crew

      assert body =~ "#{crew.paid_break_max_minutes} min or less"
      assert body =~ "#{crew.report_pull_out_minutes} min before a pull-out"
      assert body =~ "#{crew.report_relief_minutes} min before a relief"

      limit_minutes = div(crew.max_spread_minutes * 60, 3600)
      assert body =~ "#{limit_minutes} h, never exceeded"

      # The piece limit is the one rule that is NOT on the crew, so it is the one
      # most likely to be hardcoded by someone who read the other four. It comes
      # from the day's blocking context.
      case day.day.context.max_piece_minutes do
        nil -> assert body =~ "Not set"
        minutes -> assert body =~ "#{div(minutes, 60)} h #{rem(minutes, 60)} min"
      end
    end

    test "the relief points are the day's own windows, not a fixed list", ctx do
      w = world(ctx)
      view = open(ctx, w)

      open_suggest(view)

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)

      stop_ids =
        day.day.blocks
        |> Enum.flat_map(fn
          %{windows: windows} when is_list(windows) -> Enum.map(windows, & &1.stop_id)
          _ -> []
        end)
        |> Enum.uniq()
        |> Enum.sort()

      body = text(view, "#runs-suggest-drawer")

      for stop_id <- stop_ids do
        assert body =~ stop_id,
               "the drawer's relief points must name the day's own stop #{stop_id}"
      end
    end

    test "opens on the scope that has something to plan", ctx do
      # With uncovered work, the uncovered scope is the one that would do
      # something, so it is the one offered first.
      w = world(ctx)
      view = open(ctx, w)
      open_suggest(view)

      assert has_element?(view, "#runs-scope-uncovered[checked]")
      refute has_element?(view, "#runs-scope-rebuild[checked]")

      # With none, offering it would be offering a no-op.
      cut = ctx |> world() |> with_runs()
      view2 = open(ctx, cut)
      open_suggest(view2)

      assert has_element?(view2, "#runs-scope-rebuild[checked]")
      refute has_element?(view2, "#runs-scope-uncovered[checked]")
    end

    test "names the uncovered trips and the number new runs start from", ctx do
      w = world(ctx)
      view = open(ctx, w)

      uncovered = uncovered_trip_count(w)
      plural = if uncovered == 1, do: "", else: "s"

      open_suggest(view)

      # The fixture day has runs, so the uncovered scope has nothing to offer and
      # the drawer says so rather than promising an empty preview.
      refute has_element?(view, "#runs-scope-uncovered[disabled]")

      assert text(view, "#runs-suggest-drawer") =~
               "Plan the #{uncovered} trip#{plural} with no operator as new runs"
    end

    test "closes again without suggesting anything", ctx do
      w = world(ctx)
      view = open(ctx, w)
      before_saved = saved_run_ids(w)

      open_suggest(view)
      view |> element("#runs-suggest-drawer-close") |> render_click()

      refute has_element?(view, "#runs-suggest-drawer-overlay[data-open=\"true\"]")
      refute has_element?(view, "#runs-suggestion")
      assert saved_run_ids(w) == before_saved
    end
  end

  describe "previewing uncovered work" do
    test "draws the plan's own figures and saves nothing", ctx do
      w = world(ctx)
      view = open(ctx, w)
      before_saved = saved_run_ids(w)

      plan = uncovered_only(view, w)

      assert has_element?(view, "#runs-suggestion")

      # BEFORE → AFTER, both directions, for each of the four figures.
      for key <- ~w(runs paid uncovered share) do
        metric = "#runs-suggestion-#{key}"
        assert has_element?(view, metric)

        assert text(view, "#{metric} [data-role=metric-before]") == metric_before(plan, key)
        assert text(view, "#{metric} [data-role=metric-after]") == metric_after(plan, key)
      end

      # INDEPENDENT of the page: the suggestion wrote no rows.
      assert saved_run_ids(w) == before_saved
    end

    test "leaves trip_runs unchanged and adds the plan's new runs only to the page", ctx do
      w = world(ctx)
      view = open(ctx, w)
      before_saved = saved_run_ids(w)

      plan = uncovered_only(view, w)

      # The plan's own moves name the assignments it would write. None of them
      # are in the database, which is the claim in its most direct form.
      Enum.each(plan.moves, fn move ->
        refute move.to in before_saved,
               "a preview wrote #{move.to}, which it must not have"
      end)

      assert saved_run_ids(w) == before_saved
    end

    test "keeps current runs and their numbers", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)

      plan = uncovered_only(view, w)

      # The uncovered scope renumbers nothing: every saved run keeps its id and
      # is still on screen. The domain's own account is that the plan adds runs
      # without removing any.
      for run_id <- saved_run_ids(w) do
        assert has_element?(view, ~s(#runs-timeline-body tr[data-run="#{run_id}"]))
      end

      assert plan.moves != [], "the uncovered scope must plan something here"

      assert Enum.all?(plan.moves, fn move -> is_nil(move.from) end),
             "the uncovered scope only ADDS runs; it never moves an existing trip"

      assert text(view, "#runs-suggestion-scope") =~
               "Current runs keep their numbers"
    end
  end

  describe "while a suggestion is on screen" do
    test "the panel says it is not saved and offers Discard and Apply", ctx do
      w = world(ctx)
      view = open(ctx, w)

      uncovered_only(view, w)

      assert text(view, "#runs-suggestion-subtitle") =~ "not saved"
      assert has_element?(view, "#runs-discard")
      assert has_element?(view, "#runs-apply")
    end

    test "changed rows carry data-changed and a Changed label", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)

      plan = uncovered_only(view, w)

      changed = plan.changed_run_ids ++ plan.new_run_ids

      assert changed != [],
             "the fixture must change something for this case to mean anything"

      # BOTH views are checked, and against the same set. The timeline is a
      # gantt and the list is a table, so it is possible for one to mark rows and
      # the other not to; a reader who switches view mid-preview must not lose the
      # marking.
      for body <- ~w(runs-timeline-body runs-list-body) do
        view |> element("#runs-view-form") |> render_change(%{"view" => view_for(body)})

        for run_id <- changed do
          row = ~s(##{body} tr[data-run="#{run_id}"])

          assert has_element?(view, row), "#{body} is missing changed run #{run_id}"
          assert attribute(view, row, "data-changed") == "true"
          assert has_element?(view, "#{row} [data-role=changed-label]")
        end

        # And a row the plan did not touch is marked as NOT changed, so the flag
        # says something rather than being set on everything.
        for run_id <- saved_run_ids(w) -- changed do
          row = ~s(##{body} tr[data-run="#{run_id}"])

          assert attribute(view, row, "data-changed") == "false"
          refute has_element?(view, "#{row} [data-role=changed-label]")
        end
      end
    end

    test "run-drawer actions, Create run and Crew rules are refused with the reason", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)

      # BEFORE the preview, Create run is live: the lock has to be shown to
      # change something, or asserting "it is disabled" proves nothing.
      view |> element("#runs-tab-uncovered") |> render_click()
      assert has_element?(view, "[data-role=create-run]")
      refute has_element?(view, "[data-role=create-run][disabled]")

      uncovered_only(view, w)

      assert attribute(view, "#runs-crew-rules-button", "title") ==
               "Apply or discard the suggestion first."

      assert has_element?(view, "#runs-crew-rules-button[disabled]")

      # While previewing, the uncovered panel shows the SUGGESTION's uncovered
      # work. This suggestion covers the rest of the day, so there is no Create
      # run button to lock — which is itself the lockout working, since the
      # panel cannot offer an edit against rows the reader is not looking at.
      view |> element("#runs-tab-uncovered") |> render_click()

      case has_element?(view, "[data-role=create-run]") do
        false ->
          assert text(view, "#runs-tab-uncovered") =~ "Uncovered"

        true ->
          assert has_element?(view, "[data-role=create-run][disabled]")

          assert attribute(view, "[data-role=create-run]", "title") ==
                   "Apply or discard the suggestion first."
      end
    end

    test "the run drawer will not open, and says why", ctx do
      w = ctx |> world() |> with_runs()
      view = open(ctx, w)

      uncovered_only(view, w)

      # Read AFTER the preview: the claim is about a run drawn by the
      # suggestion, so the id has to come from the page as the reader sees it.
      run_id =
        view
        |> doc()
        |> LazyHTML.query("#runs-timeline-body tr[data-run]")
        |> LazyHTML.attribute("data-run")
        |> List.first()

      assert run_id, "the preview must draw rows to refuse a run drawer for"

      render_click(view, "open_run", %{"run" => run_id})

      refute has_element?(view, "#run-drawer[data-open=true]")
      assert has_element?(view, "#runs-toast[data-kind=refused]")

      assert text(view, "#runs-toast [data-role=toast-text]") =~
               "Apply or discard the suggestion first."
    end
  end

  describe "discarding" do
    test "restores the saved rows and figures", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before_saved = saved_run_ids(w)
      before_count = text(view, "#runs-count-strip-item-runs")

      uncovered_only(view, w)
      refute text(view, "#runs-count-strip-item-runs") == before_count

      view |> element("#runs-discard") |> render_click()

      refute has_element?(view, "#runs-suggestion")
      assert text(view, "#runs-count-strip-item-runs") == before_count

      for run_id <- before_saved do
        assert has_element?(view, ~s(#runs-timeline-body tr[data-run="#{run_id}"]))
      end

      assert saved_run_ids(w) == before_saved
    end

    test "reopening the drawer starts from the saved state again", ctx do
      w = world(ctx)
      view = open(ctx, w)

      uncovered_only(view, w)
      view |> element("#runs-discard") |> render_click()
      open_suggest(view)

      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open=\"true\"]")
      refute has_element?(view, "#runs-suggestion")
    end
  end

  describe "rebuilding the day" do
    test "shows the renumbering sentence", ctx do
      w = world(ctx)
      view = open(ctx, w)

      view |> open_suggest()
      view |> element("#runs-scope-rebuild") |> render_click()
      view |> preview()

      assert has_element?(view, "#runs-suggestion")
      assert attribute(view, "#runs-suggestion", "data-scope") == "replace_all"

      scope = text(view, "#runs-suggestion-scope")
      assert scope =~ "Every block is cut again"
      assert scope =~ "renumbered"
      assert scope =~ "sign-on order"
    end

    test "names every run it renumbers in the disclosure", ctx do
      # NOT `with_runs/1`. Those runs were produced BY a rebuild, so previewing
      # another rebuild is a no-op and the disclosure has nothing to name. This
      # day is cut by the Create run path instead, so a rebuild genuinely
      # renumbers it — which is the case the disclosure exists for.
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)

      view |> open_suggest()
      view |> element("#runs-scope-rebuild") |> render_click()
      view |> preview()

      plan = plan_for(w, :replace_all)
      changed = plan.changed_run_ids ++ plan.new_run_ids
      assert changed != []

      summary = text(view, "#runs-suggestion-changed summary")
      assert summary =~ "trips change" or summary =~ "trip changes"
      assert summary =~ "#{length(changed)} run"
      refute summary =~ "0 run"

      for run_id <- changed do
        assert has_element?(view, ~s(#runs-suggestion-changed-list [data-run="#{run_id}"]))
      end
    end

    test "a rebuild changes the runs on screen but still writes nothing", ctx do
      w = ctx |> world() |> with_runs()
      view = open(ctx, w)
      before_saved = saved_run_ids(w)

      view |> open_suggest()
      view |> element("#runs-scope-rebuild") |> render_click()
      view |> preview()

      assert saved_run_ids(w) == before_saved
    end
  end

  # The four figures, read from the plan's own before/after maps — deliberately
  # NOT from the rendered page, so the assertion is independent of the code that
  # rendered it.
  defp metric_before(plan, key), do: format(plan.before, key)
  defp metric_after(plan, key), do: format(plan.after, key)

  defp format(%{runs: runs}, "runs"), do: to_string(runs)
  defp format(%{paid_secs: secs}, "paid"), do: hours(secs)
  defp format(%{uncovered: %{trips: t}}, "uncovered"), do: to_string(t)
  defp format(%{straight_share: nil}, "share"), do: "—"
  defp format(%{straight_share: share}, "share"), do: "#{share}%"

  defp hours(secs) when is_integer(secs), do: :erlang.float_to_binary(secs / 3600, decimals: 1)

  defp hours(_), do: "—"
end
