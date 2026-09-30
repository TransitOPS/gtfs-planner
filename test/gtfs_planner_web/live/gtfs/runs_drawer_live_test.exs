defmodule GtfsPlannerWeb.Gtfs.RunsDrawerLiveTest do
  @moduledoc """
  EV-27: the run drawer.

  The card's independence field is "sum of rendered lines against the Paid
  cell", and that is the shape of this gate. The drawer's whole claim is that a
  reader can see where the Paid figure in a run's ROW came from, so the central
  assertion is **not** that the table says the right total — it is that the
  individual lines, parsed back out of the rendered DOM, add up to the total
  printed in the same table AND to the Paid cell of that run's row in the list.

  Three numbers that must agree, computed in three different places: the run's
  `work.paid_secs`, the drawer's own Paid row, and the list's cell. A test that
  asserted the drawer against `work.paid_secs` would pass on a table that
  printed a total and no lines at all.

  The **unpaid break** is the other claim worth making hard. A break of several
  hours that is not paid has two true numbers and one cell, so the length goes in
  the label and the value cell is EMPTY — and an empty value cell is precisely
  what a rendering fault looks like, so its emptiness is asserted as a fact about
  this break rather than left to a count.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlannerWeb.Gtfs.RunsComponents

  @moduletag :ev_27
  @moduletag timeout: 120_000

  setup do
    %{user: user_fixture()}
  end

  # One run over the head of block 101 and the tail of block 102. The two blocks'
  # first trips are left unassigned, so the run has a gap between its pieces, and
  # the gap becomes an UNPAID break — which is the case the card's pay table is
  # really about, because it is the one line with no value.
  #
  # This is steps 27 and 28's world unchanged, so a change to the fixture shows up
  # in all three gates.
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

  # A SECOND run: the whole of block 101 in one run, which is one piece longer
  # than the version's piece limit and therefore carries the card's
  # "Piece too long" finding.
  defp long_piece_world(ctx) do
    user = ctx.user
    w = runs_version_fixture()

    for trip <- w.blocks["101"] do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: "2001"
      })
    end

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: w.organization.id,
      roles: ["pathways_studio_editor"]
    })

    w
  end

  defp open(ctx, w, query) do
    conn = log_in_user(ctx.conn, ctx.user, organization: w.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{w.version.id}/runs?#{query}")
    view
  end

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
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  defp attributes(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp count(view, selector), do: view |> doc() |> LazyHTML.query(selector) |> Enum.count()

  # "7 h 30 min" or "45 min" or "8 h" into seconds.
  #
  # The parser is the load-bearing half of this gate. Asserting that two strings
  # are EQUAL would only ever check that the drawer's total and the list's cell
  # were formatted the same way; adding the lines up is a claim about arithmetic,
  # and it is the one the card asks for.
  defp parse_duration(nil), do: nil

  defp parse_duration(text) do
    text = String.trim(text)

    # "8:57" — the COMPACT form. The list's Paid cell prints hours and minutes as
    # a clock, and the drawer prints the same quantity as "8 h 57 min". Two
    # spellings of one number is a real difference between the two surfaces, not
    # a rounding: a cell that read "8:57" where the drawer reads "8 h 57 min" is
    # the same duration, and this gate is about the SUM rather than the spelling.
    # The parser accepts both so the comparison is of values.
    case Regex.run(~r/\A(\d+):(\d{2})\z/, text) do
      [_, hours, minutes] ->
        String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60

      nil ->
        parse_long_duration(text)
    end
  end

  defp parse_long_duration(text) do
    {hours, rest} =
      case Regex.run(~r/(\d+)\s*h/, text) do
        [_, hours] -> {String.to_integer(hours), Regex.replace(~r/(\d+)\s*h/, text, "")}
        nil -> {0, text}
      end

    case Regex.run(~r/(\d+)\s*min/, rest) do
      [_, minutes] -> hours * 3600 + String.to_integer(minutes) * 60
      nil -> hours * 3600
    end
  end

  defp run_ids(w) do
    {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
    Enum.map(day.derived.runs, & &1.run_id)
  end

  describe "opening" do
    test "?run=<id> opens the drawer for that run", ctx do
      w = world(ctx)
      [run_id | _] = run_ids(w)

      view = open(ctx, w, "run=#{run_id}")

      assert has_element?(view, "#run-drawer")
      assert has_element?(view, "#run-drawer-summary")
      assert text(view, "#run-drawer h2, #run-drawer [role=heading]") =~ run_id
    end

    test "the Run button opens it, and is not inert", ctx do
      w = world(ctx)
      [run_id | _] = run_ids(w)

      view = open(ctx, w, "view=list")

      # Step 23 shipped this button carrying `aria-disabled` and step 25 recorded
      # that pressing it must not silently do nothing. This is the step that stops
      # the caveat, so the button is pressed here rather than inspected.
      assert attribute(view, "#runs-run-#{run_id}", "phx-click") == "open_run"
      refute has_element?(view, "#runs-run-#{run_id}[aria-disabled]")

      view |> element("#runs-run-#{run_id}") |> render_click()

      assert has_element?(view, "#run-drawer")
    end

    test "an unknown run opens nothing rather than an empty drawer", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=9999")

      # A drawer of zeroes is worse than no drawer: a reader cannot tell a run
      # that does not exist from one that is merely empty.
      refute has_element?(view, "#run-drawer")
    end

    test "Close removes the run param", ctx do
      w = world(ctx)
      [run_id | _] = run_ids(w)

      view = open(ctx, w, "run=#{run_id}")
      assert has_element?(view, "#run-drawer")

      view |> element("#run-drawer button[phx-click=close_drawer]") |> render_click()

      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}")
      refute has_element?(view, "#run-drawer")
    end

    test "closing one drawer does not close the summary drawer for another", ctx do
      w = world(ctx)
      [run_id | _] = run_ids(w)

      view = open(ctx, w, "run=#{run_id}")
      view |> element("#run-drawer button[phx-click=close_drawer]") |> render_click()

      # The two drawers share one `:drawer` assign, so this asserts the shape of
      # that assign rather than a rendering accident: a summary drawer still open
      # behind a closed run drawer would be two states at once.
      view
      |> element("[data-role=count-strip-item][id=runs-count-strip-item-runs]")
      |> render_click()

      assert has_element?(view, "#runs-summary-drawer")
    end
  end

  describe "the pieces" do
    test "the split run lists two pieces", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      assert count(view, "#run-drawer-pieces-table [data-role=run-piece]") == 2

      assert attributes(view, "#run-drawer-pieces-table [data-role=run-piece]", "data-piece") == [
               "1",
               "2"
             ]
    end

    test "each piece links to that block in Blocks, carrying the day type", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      hrefs = attributes(view, "[data-role=piece-block-link]", "href")

      assert hrefs == [
               "/gtfs/#{w.version.id}/blocks?day=#{w.day_type_key}&block=101",
               "/gtfs/#{w.version.id}/blocks?day=#{w.day_type_key}&block=102"
             ]

      # The day type is in the link because the block is a property of a DAY, not
      # of a version: a link without it opens the wrong day and shows a block
      # that appears not to exist.
      for href <- hrefs, do: assert(href =~ "day=")
    end

    test "each piece shows its own times, places and start kind", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      assert text(view, "#run-drawer-pieces-table tr[data-piece='1'] [data-role=piece-time]") =~
               ~r/\d{2}:\d{2}.*\d{2}:\d{2}/s

      places = text(view, "#run-drawer-pieces-table tr[data-piece='1'] [data-role=piece-places]")
      assert places =~ "→"
      refute places =~ "Unknown stop"

      # Piece 1 starts at a block start and piece 2 at a relief. The drawer says
      # so, because that is where a run may be interrupted and the reader is
      # being shown the place to interrupt it.
      assert text(view, "#run-drawer-pieces-table tr[data-piece='1'] [data-role=piece-places]") =~
               "Bay A"

      assert text(view, "#run-drawer-pieces-table tr[data-piece='2'] [data-role=piece-places]") =~
               "(relief point)"
    end

    test "the piece times are the piece's own, in its data attributes", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs

      for {piece, index} <- Enum.with_index(run.pieces, 1) do
        assert attributes(view, "tr[data-piece='#{index}']", "data-block") == [piece.block_id]

        assert attributes(view, "tr[data-piece='#{index}']", "data-start") == [
                 to_string(piece.start_secs)
               ]

        assert attributes(view, "tr[data-piece='#{index}']", "data-end") == [
                 to_string(piece.end_secs)
               ]
      end
    end
  end

  describe "the paid-time table" do
    test "it has a report line for each piece, and says which kind of report", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      labels = view |> doc() |> LazyHTML.query("[data-role=pay-label]") |> Enum.map(&trim/1)

      # The card's own words for the first report. The second is a RELIEF report,
      # not a pull-out: the crew rules give 15 minutes before a pull-out and 5
      # before a change of operator, and a table that called both "pull-out"
      # would overstate the second by 10 minutes a day for every split run.
      assert Enum.any?(labels, &(&1 =~ "Report before piece 1 (pull-out)"))
      assert Enum.any?(labels, &(&1 =~ "Report before piece 2 (relief)"))

      refute Enum.any?(labels, &(&1 =~ "Report before piece 2 (pull-out)"))
    end

    test "the first report is 15 min and the relief report is 5", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs

      reports = Enum.filter(run.work.segments, &(&1.kind == :report))

      for report <- reports do
        row = "tr[data-index='#{index_of(view, :report, report)}']"

        assert parse_duration(text(view, row <> " [data-role=pay-value]")) ==
                 report.end_secs - report.start_secs
      end

      # And the fixture's own numbers, so a change to the crew rules moves the
      # expectation rather than silently falsifying it.
      assert Enum.map(reports, &div(&1.end_secs - &1.start_secs, 60)) == [15, 5]
    end

    test "an unpaid break is listed with its length in the LABEL and no value", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs
      [unpaid | _] = Enum.filter(run.work.breaks, &(not &1.paid?))

      index = index_of(view, :break, %{end_secs: unpaid.secs + 24600, start_secs: 24600})
      label = text(view, "tr[data-index='#{index}'] [data-role=pay-label]")
      value = text(view, "tr[data-index='#{index}'] [data-role=pay-value]")

      assert label =~ "Break"
      # The real length is on screen — a reader planning a duty needs to know the
      # gap is five and a half hours, not that it is unpaid.
      assert label =~ "5 h 35 min"
      # And the value cell is EMPTY. This is the assertion that would fail on a
      # table printing "0 min" (a claim the break did not happen) or the raw
      # length (a claim the run was paid for it). An empty cell is also what a
      # rendering fault looks like, which is why the label is asserted at the
      # same time.
      assert value == ""
      refute value =~ "min"
    end

    test "the rendered line values sum to the drawer's own Paid row", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      summed = view |> doc() |> LazyHTML.query("[data-role=pay-value][data-paid=true]")

      total =
        summed
        |> Enum.map(fn cell -> cell |> LazyHTML.text() |> parse_duration() end)
        |> Enum.sum()

      assert total == parse_duration(text(view, "[data-role=pay-total]"))

      # The row's own `data-secs` is the third statement of the same number — the
      # rendered text, the attribute, and the sum of the lines. A mutation that
      # inflated only the attribute passed everything until this was added.
      assert attributes(view, "[data-role=pay-total]", "data-secs") == [to_string(total)]
    end

    test "the rendered line values sum to the PAID CELL of that run's row", ctx do
      w = world(ctx)
      view = open(ctx, w, "view=list&run=1001")

      # The card's independence field, and the whole reason this gate parses
      # durations instead of comparing strings: the drawer's lines and the LIST's
      # cell are rendered by different code from different assigns, and a reader
      # comparing the two has to find them equal.
      summed =
        view
        |> doc()
        |> LazyHTML.query("[data-role=pay-value][data-paid=true]")
        |> Enum.map(&(&1 |> LazyHTML.text() |> parse_duration()))
        |> Enum.sum()

      cell = text(view, "#runs-list tr[data-run='1001'] [data-role=run-paid]")

      # The two surfaces spell the same number differently — "8:57" in the list,
      # "8 h 57 min" in the drawer — and both are asserted so the difference is a
      # stated fact of this gate rather than something a reader discovers by
      # comparing two panels and wondering whether one is rounding.
      assert cell =~ ~r/\A\d+:\d{2}\z/
      assert text(view, "[data-role=pay-total]") =~ ~r/\A\d+ h \d+ min\z/

      assert summed == parse_duration(cell)
    end

    test "the sum equals the run's own work.paid_secs", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs

      summed =
        view
        |> doc()
        |> LazyHTML.query("[data-role=pay-value][data-paid=true]")
        |> Enum.map(&(&1 |> LazyHTML.text() |> parse_duration()))
        |> Enum.sum()

      assert summed == run.work.paid_secs
    end

    test "a line the reader cannot account for would break the sum", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      # Every line is either paid (and carries a value that counts) or not (and
      # carries none). A third kind of line — a value that is neither in the total
      # nor empty — is what would make the table lie quietly, so the counts are
      # pinned: every line is one or the other, and the unpaid ones are exactly the
      # run's unpaid breaks.
      lines = view |> doc() |> LazyHTML.query("[data-role=pay-line]")

      paid =
        Enum.filter(lines, &(&1 |> LazyHTML.attribute("data-paid") |> List.first() == "true"))

      unpaid =
        Enum.filter(lines, &(&1 |> LazyHTML.attribute("data-paid") |> List.first() == "false"))

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs

      assert length(unpaid) == Enum.count(run.work.breaks, &(not &1.paid?))
      assert length(paid) + length(unpaid) == length(run.work.segments)

      for cell <- unpaid do
        assert String.trim(LazyHTML.text(cell)) != ""
      end
    end

    test "the rule sentence carries the version's own crew numbers", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      rule = text(view, "#run-drawer-rule")

      # The WHOLE sentence, not four substrings. Asserting `=~ "5 min before each
      # relief"` passes on "15 min before each relief" — a mutation that swapped
      # the relief number for the pull-out number was caught by nothing, because
      # the five is a substring of the fifteen. A rule sentence is a sentence;
      # asserting it whole is also the only way to catch two numbers in the wrong
      # order, which no substring check can see.
      assert rule ==
               "Paid time = report (15 min before each pull-out, 5 min before each relief) " <>
                 "+ time on vehicles + travel + a break of 30 minutes or less + sign-off (5 min)."
    end
  end

  describe "the findings" do
    test "the long-piece run shows its Piece too long finding", ctx do
      w = long_piece_world(ctx)
      view = open(ctx, w, "run=2001")

      assert has_element?(
               view,
               "#run-drawer-findings [data-role=run-finding][data-code=piece_too_long]"
             )

      # Icon AND words, step 24's rule: a coloured dot alone is a colour a reader
      # may not be able to name.
      assert text(view, "[data-role=run-finding][data-code=piece_too_long]") =~ "Piece too long"
      # The icon is a heroicon span in this app, not an <svg> element — the same
      # convention step 24's Status cell uses.
      assert has_element?(
               view,
               "[data-role=run-finding][data-code=piece_too_long] span[class*=hero-]"
             )

      # The DETAIL sentence, which is the part that says what to do about it. A
      # finding with only its label is "Piece too long" and nothing else: the
      # reader is told there is a problem and not how far past the limit it is.
      # This assertion was MISSING and a mutation that deleted the detail clause
      # passed everything.
      detail =
        text(view, "[data-role=run-finding][data-code=piece_too_long] p:nth-of-type(2)")

      assert detail =~ ~r/\d+ h \d+ min against a limit of \d+ h \d+ min/
    end

    test "a run with no findings says so rather than showing an empty list", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      # Asserted against the run's OWN findings rather than against a fixture
      # belief: the shared world's run 1001 does carry a finding (its spread is
      # over the limit), so a test that assumed a clean run would be asserting
      # about the fixture and not about the drawer.
      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs

      if run.findings == [] do
        assert has_element?(view, "[data-role=run-no-problems]", "No problems")
        refute has_element?(view, "[data-role=run-finding]")
      else
        # The other branch is the one this fixture takes, and it is asserted
        # anyway below, so nothing is left unasserted by the branch.
        assert has_element?(view, "[data-role=run-finding]")
      end
    end

    test "a clean run renders the no-problems line through the component", ctx do
      # Rendered directly, because this world has no clean run: the finding list
      # and the no-problems line are two branches of one conditional, and a gate
      # that only ever exercises one of them has not checked the other.
      run = %{
        run_id: "3001",
        pieces: [
          %{
            block_id: "1",
            route_id: "R",
            start_secs: 0,
            end_secs: 600,
            start_kind: :block_start,
            end_kind: :block_end,
            start_stop: nil,
            end_stop: nil,
            trips: []
          }
        ],
        work: %{segments: [], paid_secs: 0, spread_secs: 600, type: :one_piece},
        findings: []
      }

      html =
        render_component(&RunsComponents.run_drawer/1,
          run: run,
          day_type_key: "weekday",
          version_id: "v1",
          crew: %{
            report_pull_out_minutes: 15,
            report_relief_minutes: 5,
            paid_break_max_minutes: 30,
            sign_off_minutes: 5
          },
          stop_names: %{},
          open?: true,
          # Step 30 added the rename form INSIDE the drawer, so this hand-built
          # assign set has to carry the form too. Rendering the component
          # directly is worth the extra fields: it is the only way to reach the
          # clean-run branch, which no fixture in this file produces.
          rename_form: Phoenix.Component.to_form(%{"run_id" => ""}, as: :run),
          rename_errors: [],
          # Step 31 added the per-piece move forms inside the drawer, so this
          # hand-built assign set carries them too. This run has no pieces, so
          # `move_runs` is empty and no move form is rendered.
          move_form: Phoenix.Component.to_form(%{"to" => ""}, as: :move),
          move_runs: [],
          next_run_id: "1"
        )

      assert html =~ "No problems"
      refute html =~ "data-role=\"run-finding\""
    end

    test "the split run shows the finding the day actually raised about it", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs

      assert [finding] = run.findings

      assert has_element?(
               view,
               "[data-role=run-finding][data-code=#{finding.code}][data-severity=#{finding.severity}]"
             )
    end
  end

  # The rendered index of the first line of `kind` whose span is `span`, so a test
  # can name a line by the work it represents rather than by a position that
  # changes whenever a kind is added.
  defp index_of(view, kind, %{start_secs: start, end_secs: ending}) do
    view
    |> doc()
    |> LazyHTML.query("[data-role=pay-line][data-kind=#{kind}]")
    |> Enum.find_value(fn line ->
      attrs = line |> LazyHTML.attribute("data-secs") |> List.first()

      if attrs && to_integer(attrs) == ending - start,
        do: line |> LazyHTML.attribute("data-index") |> List.first()
    end)
  end

  defp to_integer(value), do: String.to_integer(value)

  defp trim(cell), do: cell |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()
end
