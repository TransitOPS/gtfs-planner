defmodule GtfsPlannerWeb.Gtfs.RunsMarksLiveTest do
  @moduledoc """
  EV-22: the run marks, the chart key and the status text.

  The surface under test is a chart, so the assertions are about the marks a
  reader can see and the words beside them, not about arithmetic: every number
  here is read out of the run's own `WorkTime` or `findings` rather than
  recomputed, because recomputing it would only prove the test agrees with
  itself.

  Where a case cannot be built from `RunsFixtures`, the component is rendered
  directly with a synthetic run. That is a real render of the real branch, and
  the gap it leaves — no fixture produces these conditions — is recorded in
  step 24's learning rather than papered over.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlannerWeb.Gtfs.RunsComponents

  @moduletag :ev_22
  @moduletag timeout: 120_000

  # Only the user is built here. `runs_version_fixture/1` creates its OWN
  # organization, so the membership goes on THAT one — the step 21 learning's
  # standing trap.
  setup do
    %{user: user_fixture()}
  end

  # One run over both blocks and one over the second block's last trip, so a row
  # carries two pieces and a break between them, and the second run starts where
  # the first one stopped.
  defp split_world(%{user: user}) do
    world = runs_version_fixture()
    [first, second] = world.blocks["102"]

    for trip <- world.blocks["101"] ++ [first] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1001"
      })
    end

    trip_run_fixture(world.organization.id, world.version.id, %{
      trip: second,
      day_type_key: world.day_type_key,
      run_id: "1002"
    })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: world.organization.id,
      roles: ["pathways_studio_editor"]
    })

    world
  end

  defp open_runs(context, world) do
    conn = log_in_user(context.conn, context.user, organization: world.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs")
    view
  end

  # Block 101's four trips in run 1001 and block 102's two in run 1002. Both are
  # one-piece runs, so neither carries an inter-piece break and no finding about
  # a change: whatever is wrong with them is wrong on their own terms.
  defp one_piece_world(%{user: user}) do
    world = runs_version_fixture()

    for {block, run_id} <- [{"101", "1001"}, {"102", "1002"}], trip <- world.blocks[block] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: run_id
      })
    end

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: world.organization.id,
      roles: ["pathways_studio_editor"]
    })

    world
  end

  defp derived(world) do
    {:ok, runs_day} = Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)
    runs_day
  end

  defp run(day, run_id), do: Enum.find(day.derived.runs, &(&1.run_id == run_id))

  defp segment(run, kind), do: Enum.find(run.work.segments, &(&1.kind == kind))

  defp status_html(view, run_id) do
    view
    |> element("#runs-timeline .runs-row[data-run='#{run_id}'] [data-role=run-status]")
    |> render()
  end

  describe "segments on the track" do
    test "a split run's break between its two pieces is drawn", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      run = run(derived(world), "1001")
      break = segment(run, :break)

      # The domain has one `:break` and the chart has two names for it, so the
      # assertion is the pair of classes rather than one: naming only
      # "break-unpaid" would pass a chart that drew every break as unpaid,
      # including one it cannot draw.
      assert has_element?(
               view,
               "#runs-timeline .runs-row[data-run='1001'] [data-role=mark][data-kind='break-unpaid']," <>
                 "#runs-timeline .runs-row[data-run='1001'] [data-role=mark][data-kind='cant-reach']"
             )

      assert %{start_secs: from, end_secs: to} = break
      assert from != to, "the break is a real span, not a zero-width no-op"

      assert render(view) =~
               if(to < from, do: ~s(data-kind="cant-reach"), else: ~s(data-kind="break-unpaid"))
    end

    test "the fixture's break is a cannot-reach and says so", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      run = run(derived(world), "1001")
      break = segment(run, :break)

      # This fixture's two blocks overlap in the day, so the second piece starts
      # before the first one ends. The mark takes the shortfall's real width
      # rather than being hidden, which is why the class is cant-reach and not
      # unpaid — a chart that drew this as "unpaid" would be telling a reader
      # the operator chose a break they were not paid for.
      assert break.end_secs < break.start_secs

      assert has_element?(
               view,
               "#runs-timeline .runs-row[data-run='1001'] [data-role=mark][data-kind='cant-reach']"
             )
    end

    test "a relief-start run draws its estimated travel, then its report, then its piece",
         ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      run = run(derived(world), "1002")
      kinds = Enum.map(run.work.segments, & &1.kind)

      # The order is the domain's, not the template's: the reader sees a drive,
      # then a report, then the bar. Asserting on the order is the point.
      assert kinds == [:travel, :report, :piece, :sign_off]
      assert segment(run, :travel).source == :estimated

      row = ~s|#runs-timeline .runs-row[data-run='1002']|

      assert has_element?(
               view,
               row <> " [data-role=mark][data-kind=travel][data-source=estimated]"
             )

      assert has_element?(view, row <> " [data-role=mark][data-kind=report][data-seg=report]")
      assert has_element?(view, row <> " [data-role=mark][data-kind=report][data-seg=sign_off]")

      # The estimate is labelled on the mark, and the mark says so in words.
      assert view
             |> element(row <> " [data-role=mark][data-kind=travel] .runs-mark-label")
             |> render() =~ "est."

      assert view
             |> element(row <> " [data-role=mark][data-kind=travel]")
             |> render() =~ "Travel"
    end

    test "every mark carries a title in words", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      html = render(view)

      marks =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#runs-timeline [data-role=mark]")
        |> LazyHTML.attribute("title")

      assert marks != [], "the split world's rows carry marks"
      assert Enum.all?(marks, &(is_binary(&1) and &1 != "")), "no mark is hover-only"
    end

    test "a mark sits where the day's axis puts it, not at the row's left edge", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      day = derived(world)
      run = run(day, "1002")
      report = segment(run, :report)

      {axis_start, axis_span} =
        {day.derived.axis.start_secs, day.derived.axis.end_secs - day.derived.axis.start_secs}

      left =
        view
        |> element(
          "#runs-timeline .runs-row[data-run='1002'] [data-kind=report][data-seg=report]"
        )
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("style")
        |> List.first()

      # The report begins well after the day starts, so it cannot be at 0%. The
      # expected position is recomputed from the run's own seconds against the
      # run's own axis rather than hard-coded, so the claim is "the mark uses
      # the axis" and not "the mark sits at this many percent".
      assert left =~ ~r/left: [\d.]+%/

      expected =
        :erlang.float_to_binary((report.start_secs - axis_start) * 100 / axis_span * 1.0,
          decimals: 2
        )

      assert left =~ "left: #{expected}%"
    end
  end

  describe "boundary marks" do
    test "a change at a relief point draws ⇄ on both pieces that meet there", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      handover = run(derived(world), "1001").pieces |> Enum.at(1)

      assert handover.end_kind == :relief
      assert handover.end_boundary.at_relief?

      # The two runs that meet here each carry their own side of the change, and
      # each is marked in and out respectively.
      assert has_element?(
               view,
               "#runs-timeline .runs-row[data-run='1001'] [data-role=boundary][data-side=out][data-at-relief=true]"
             )

      assert has_element?(
               view,
               "#runs-timeline .runs-row[data-run='1002'] [data-role=boundary][data-side=in][data-at-relief=true]"
             )

      assert view
             |> element(
               "#runs-timeline .runs-row[data-run='1001'] [data-role=boundary][data-side=out]"
             )
             |> render() =~ "⇄"
    end

    test "a piece that starts and ends at its block's ends carries no boundary mark", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      first_piece = run(derived(world), "1001").pieces |> hd()

      assert first_piece.start_boundary == nil
      assert first_piece.end_boundary == nil

      # A mark on every bar would be a mark that means nothing. The run's own
      # data has no change at this piece's edges, so the chart draws none.
      assert first_piece.block_id == "101"

      refute has_element?(
               view,
               "#runs-timeline .runs-row[data-run='1001'] .runs-piece[data-block='101'] [data-role=boundary]"
             )
    end
  end

  describe "the chart key" do
    test "names all eight marks in words", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      html = render(view)

      assert has_element?(view, "#chart-key")

      # LazyHTML is Enumerable over its matched nodes, so each label is read on
      # its own rather than as one concatenated strip: eight labels read as
      # eight words is what the key promises, and a strip would pass with one.
      labels =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#chart-key [data-role=chart-key-label]")
        |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))

      assert length(labels) == 8

      for expected <- [
            "Piece of vehicle work",
            "Report or sign-off",
            "Travel, estimated",
            "Paid break",
            "Unpaid break",
            "Change at a relief point",
            "Change away from a relief point",
            "Can’t reach the next piece"
          ] do
        assert Enum.any?(labels, &String.starts_with?(&1, expected)),
               "the key names #{expected}, and has #{inspect(labels)}"
      end
    end

    test "paints a swatch for every mark it names, so the key cannot drift", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      html = render(view)

      swatches =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#chart-key [data-role=chart-key-swatch]")
        |> LazyHTML.attribute("data-kind")

      # The order is the reference's, and it is the order a reader scans in.
      assert swatches == [
               "piece",
               "report",
               "travel",
               "paid",
               "unpaid",
               "relief",
               "bad",
               "reach"
             ]
    end

    test "the key is on the chart, not on a page with no chart", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)

      # A key above a chart that failed to load explains marks that are not
      # there. The page owns both; the key follows the chart's state.
      assert has_element?(view, "#runs-timeline")
    end
  end

  describe "the status cell" do
    test "a run with no findings reads No problems with a check", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      clean = run(derived(world), "1002")

      assert clean.findings == []

      status = status_html(view, "1002")

      assert status =~ "No problems"
      assert status =~ ~s(data-status="ok")
      assert status =~ "hero-check-mini"
    end

    test "a long piece reads Piece too long with a warning icon, not a bare count",
         ctx do
      world = one_piece_world(ctx)
      view = open_runs(ctx, world)
      run = run(derived(world), "1001")
      codes = Enum.map(run.findings, & &1.code)

      assert :piece_too_long in codes
      # The LEAD is the long piece, so this asserts the wording is chosen for the
      # finding that leads — not that the word "Piece too long" appears
      # somewhere in the cell, which it would not if a spread warning came first.
      assert List.first(codes) == :piece_too_long

      status = status_html(view, "1001")

      assert status =~ "Piece too long"
      assert status =~ ~s(data-status="piece_too_long")
      assert status =~ "hero-exclamation-triangle-mini"

      # This run raises exactly one finding, so there is nothing to count. `+N`
      # counts the findings the cell does NOT name, and a lone finding shows no
      # count at all rather than "+0" — a count of zero is a thing to notice
      # about a cell that otherwise has nothing to say.
      assert length(run.findings) == 1
      refute status =~ "+"
      refute status =~ ~s(data-role="run-status-more")
    end

    test "the worst finding leads, so an error is never hidden behind a warning",
         ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      codes = run(derived(world), "1001").findings |> Enum.map(& &1.code)

      # This run raises an error AND two warnings. `Runs.Checks` returns errors
      # first and the cell leads with the first, so the one finding that stops a
      # plan being published is the one the reader sees.
      assert :cannot_reach_piece in codes
      assert length(codes) == 3

      status = status_html(view, "1001")

      assert status =~ "Can’t reach piece"
      assert status =~ "hero-x-circle-mini"
      assert status =~ "+2"
    end

    test "status is never colour alone", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)

      # Every status cell carries readable text. This is the obligation INV-11
      # names and it is cheap to prove here and impossible to prove visually:
      # each cell is rendered on its own, so a blank cell on one row cannot hide
      # behind a worded cell on the next.
      for run_id <- ["1001", "1002"] do
        status = status_html(view, run_id)
        assert status =~ ~s(data-role="run-status-label")
        assert String.trim(status) != ""
      end

      # And the cell's meaning is in the words, not only in a class name: the
      # tone class is present, but the label is what carries the finding.
      assert status_html(view, "1001") =~ "text-error"
      assert status_html(view, "1001") =~ "Can’t reach piece"
    end
  end

  describe "pieces carrying findings" do
    test "a piece with only a warning finding is outlined in warning", ctx do
      world = one_piece_world(ctx)
      view = open_runs(ctx, world)
      run = run(derived(world), "1001")

      # One piece, one warning: nothing competes for the outline.
      assert Enum.map(run.findings, & &1.severity) == [:warning]

      assert has_element?(
               view,
               "#runs-timeline .runs-row[data-run='1001'] .runs-piece-warning[data-block='101']"
             )
    end

    test "the worst finding on a piece wins the outline", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)
      run = run(derived(world), "1001")

      # This piece carries BOTH a cannot-reach error and a too-long warning, and
      # it wears the error. Painting it amber would understate the one finding
      # that stops a plan being published — the outline is a severity, not a
      # decoration.
      severities =
        run.findings
        |> Enum.filter(&(&1.code in [:cannot_reach_piece, :piece_too_long]))
        |> Enum.map(& &1.severity)

      assert :error in severities
      assert :warning in severities

      assert has_element?(
               view,
               "#runs-timeline .runs-row[data-run='1001'] .runs-piece-error[data-block='101']"
             )

      refute has_element?(
               view,
               "#runs-timeline .runs-row[data-run='1001'] .runs-piece-warning"
             )
    end

    test "a piece with no piece-scoped finding is not outlined", ctx do
      world = split_world(ctx)
      view = open_runs(ctx, world)

      # Run 1002 is clean. An outline here would mean the mapping from a finding
      # to a piece is too wide — and a false outline is worse than a missing
      # one, because it sends a reader looking for a problem that is not there.
      refute has_element?(
               view,
               "#runs-timeline .runs-row[data-run='1002'] .runs-piece-error, #runs-timeline .runs-row[data-run='1002'] .runs-piece-warning"
             )
    end
  end

  describe "marks the fixtures cannot build" do
    # `runs_version_fixture/1` cannot produce a positive break, a change away
    # from a relief point, or a `not_at_relief` finding: its two blocks overlap,
    # and every cut it can make lands on a marked stop. These render the
    # component directly with a synthetic run, which exercises the same branch
    # the real page takes. The gap is recorded in step 24's learning.

    defp render_marks(segments, pieces \\ []) do
      run = %{run_id: "9999", pieces: pieces, work: synthetic_work(segments), findings: []}
      axis = %{start_secs: 0, end_secs: 86_400}

      render_component(&RunsComponents.run_row/1, %{
        dom: "row-9999",
        run: run,
        axis: axis,
        routes: %{},
        sort: :sign_on,
        dir: :asc,
        scale: :day
      })
    end

    # A `WorkTime` map complete enough for the row's fact cells. The figures are
    # all zero on purpose: this path is about which MARK is drawn, and a row
    # that also had to satisfy the cell arithmetic would be testing two things
    # and proving neither cleanly.
    defp synthetic_work(segments) do
      %{
        type: :split,
        segments: segments,
        sign_on_secs: 0,
        sign_off_secs: 86_400,
        spread_secs: 86_400,
        paid_secs: 0
      }
    end

    test "a straight run's paid break is hatched" do
      html =
        render_marks([
          %{kind: :break, start_secs: 3600, end_secs: 3900, source: nil, paid?: true}
        ])

      assert html =~ ~s(data-kind="break-paid")
      assert html =~ "Paid break"
    end

    test "a split run's unpaid break is a thin line" do
      html =
        render_marks([
          %{kind: :break, start_secs: 3600, end_secs: 6000, source: nil, paid?: false}
        ])

      assert html =~ ~s(data-kind="break-unpaid")
      assert html =~ "Unpaid break"
    end

    test "a paid break and an unpaid break are different marks" do
      paid =
        render_marks([%{kind: :break, start_secs: 0, end_secs: 1800, source: nil, paid?: true}])

      unpaid =
        render_marks([%{kind: :break, start_secs: 0, end_secs: 1800, source: nil, paid?: false}])

      # One `:break` in the domain, two in the chart. The break the operator is
      # paid for changes what the day costs; the one they eat does not, and the
      # chart must not draw them the same way.
      refute paid == unpaid
    end

    test "a change away from a relief point draws !, not ⇄" do
      piece = %{
        block_id: "101",
        route_id: "1",
        start_secs: 3600,
        end_secs: 7200,
        trips: [],
        start_kind: :relief,
        end_kind: :block_end,
        start_boundary: %{at_relief?: false, side: :origin, stop: nil},
        end_boundary: nil
      }

      html = render_marks([], [piece])

      assert html =~ ~s(data-at-relief="false")
      assert html =~ "!"
      refute html =~ "⇄"
    end

    test "a not-at-relief finding reads Not at a relief point with an error icon" do
      findings = [
        %{
          code: :not_at_relief,
          severity: :error,
          run_ids: ["9999"],
          block_id: "101",
          trip_ids: [],
          detail: %{stop_id: "X", stop_name: "Somewhere"}
        }
      ]

      status = render_component(&RunsComponents.status_cell/1, %{findings: findings})

      assert status =~ "Not at a relief point"
      assert status =~ "hero-x-circle-mini"
    end

    test "a travel leg the version could not answer is marked ?, not drawn as known" do
      html =
        render_marks([
          %{kind: :travel, start_secs: 0, end_secs: 2400, source: :unknown, paid?: true}
        ])

      assert html =~ "?"
      assert html =~ "could not answer"
    end

    test "a sign-off is drawn as a report mark but titled as a sign-off" do
      html =
        render_marks([
          %{kind: :sign_off, start_secs: 54_000, end_secs: 54_300, source: nil, paid?: true}
        ])

      # Same shape, different words: the key says "Report or sign-off" because
      # the mark is the same, but the title says which one this is.
      assert html =~ ~s(data-kind="report")
      assert html =~ "Sign-off"
    end
  end
end
