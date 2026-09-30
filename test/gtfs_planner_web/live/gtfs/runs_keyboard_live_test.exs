defmodule GtfsPlannerWeb.Gtfs.RunsKeyboardLiveTest do
  @moduledoc """
  The server's half of the duty chart's roving row: the `tabindex` it renders,
  the hook that moves focus, and the hint that explains both.

  ## Why half of this gate is not here

  EV-23 is a Playwright gate and is **blocked**: `bin/test-browser` is absent
  from this base branch, so Chromium never runs. The spec is written and
  committed at `assets/e2e/runs_keyboard.spec.js` against the seeded Browser
  Runs Version, and it is the only place the focus MOVEMENT is proved.

  What is proved here is the half that is the server's to get right, and it is
  the half that is easy to get wrong silently: a client that computed the
  `tabindex` itself would ship a chart with no tab stop in it at all until
  JavaScript arrived, and nothing in a rendered page would look broken. These
  assertions read the `tabindex` in the initial HTML and after a LiveView patch,
  which is where that failure would live.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  @moduletag :ev_24
  @moduletag timeout: 120_000

  # Only the user is built here. `runs_version_fixture/1` creates its OWN
  # organization, so the membership goes on THAT one — the step 21 learning's
  # standing trap.
  setup do
    %{user: user_fixture()}
  end

  # One run over both blocks and one over the second block's last trip, so one
  # row carries two pieces and the other carries one. A roving row that only
  # ever held one piece would pass every assertion below.
  defp world(%{user: user}) do
    w = runs_version_fixture()
    [first, second] = w.blocks["102"]

    for trip <- w.blocks["101"] ++ [first] do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: "1001"
      })
    end

    trip_run_fixture(w.organization.id, w.version.id, %{
      trip: second,
      day_type_key: w.day_type_key,
      run_id: "1002"
    })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: w.organization.id,
      roles: ["pathways_studio_editor"]
    })

    w
  end

  defp open_runs(ctx, w) do
    conn = log_in_user(ctx.conn, ctx.user, organization: w.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{w.version.id}/runs")
    view
  end

  # The roving state, read from the rendered DOM as a reader's browser would
  # find it: which piece of which row is in the tab order.
  defp tabindexes(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#runs-timeline .runs-row")
    |> Enum.flat_map(fn row ->
      run = row |> LazyHTML.attribute("data-run") |> hd()

      row
      |> LazyHTML.query(".runs-piece")
      |> Enum.map(fn bar ->
        %{
          run: run,
          piece: bar |> LazyHTML.attribute("data-piece") |> hd(),
          block: bar |> LazyHTML.attribute("data-block") |> hd(),
          tabindex: bar |> LazyHTML.attribute("tabindex") |> hd()
        }
      end)
    end)
  end

  defp bars_for(bars, run_id), do: Enum.filter(bars, &(&1.run == run_id))

  # The roving invariant is PER ROW, never per page: two rows are two stops, and
  # a page-level count cannot tell "each row has one" from "one row has two and
  # the rest have none".
  defp each_row_roving?(bars) do
    bars
    |> Enum.group_by(& &1.run)
    |> Enum.all?(fn {_run, row} -> Enum.count(row, &(&1.tabindex == "0")) == 1 end)
  end

  defp squish(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "the server owns the tabindex" do
    test "each row's first piece is the row's only tab stop", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)
      bars = tabindexes(render(view))

      # Two rows: one with two pieces, one with one. Every row contributes
      # exactly one `0`, so a reader tabs past twenty runs in twenty presses
      # rather than stopping on every bar.
      assert length(bars) == 3
      assert Enum.map(bars, & &1.tabindex) == ["0", "-1", "0"]
      assert bars |> Enum.filter(&(&1.tabindex == "0")) |> Enum.map(& &1.piece) == ["1", "1"]
    end

    test "the tab stop is the FIRST piece, not any piece", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)
      [first, second | _] = tabindexes(render(view))

      # The bar closest to the start of the day is where a reader arriving at
      # the row expects to be. This is a claim about ORDER, not about
      # "some bar is focusable", which a `has_element?` would also pass.
      assert first.piece == "1"
      assert second.piece == "2"
      assert first.tabindex == "0"
      assert second.tabindex == "-1"
    end

    test "a one-piece row is still one tab stop and never zero", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)
      bars = tabindexes(render(view))

      two = bars_for(bars, "1001")
      one = bars_for(bars, "1002")

      assert [bar] = one
      assert bar.tabindex == "0"
      assert length(two) == 2

      # The one-piece row must still be reachable. A roving row that dropped its
      # only bar out of the tab order would be a row no keyboard can enter, and
      # it would look identical to a row that was simply not rendered.
      assert Enum.count(two, &(&1.tabindex == "0")) == 1
      assert each_row_roving?(bars)
    end

    test "the tabindex is on the rendered HTML, not added by the hook", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)
      html = render(view)

      # `has_element?` reads the live DOM, which a mounted hook could have
      # changed. The raw HTML is what a reader's browser parses BEFORE any
      # JavaScript runs, and that is the surface this step owns.
      assert html =~ ~s(tabindex="0")
      assert html =~ ~s(tabindex="-1")

      # And the row's first bar is the `0` one in document order, which is the
      # only ordering a browser uses to build the tab sequence.
      row = Regex.run(~r/<tr[^>]*data-run="1001".*?<\/tr>/s, html) |> hd()

      # `scan/2` and not `run/2`: with one capture group `run/2` returns
      # [full, group] — a flat pair, so mapping `hd/1` over it walks into the
      # full match. `scan/2` returns one pair PER match, which is what "the
      # first bar then the second" needs.
      assert row
             |> then(&Regex.scan(~r/tabindex="(-?\d)"/, &1))
             |> Enum.map(fn [_full, value] -> value end) == ["0", "-1"]
    end
  end

  describe "the hook" do
    test "the scroll container that holds every piece carries the roving hook", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)

      # The hook is namespaced by the compiler, the same way `UserMenu` and
      # `OverlayDialog` are. It hangs off the scroll container rather than the
      # table because a `<script>` cannot be a child of a `<table>`, and inside
      # the streamed `<tbody>` it would be replaced on every row patch and never
      # re-attach.
      assert has_element?(
               view,
               ~s(#runs-timeline-scroll[phx-hook$="RunsRovingRow"])
             )
    end

    test "the hook's element contains every piece bar on the page", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)
      html = render(view)

      total = length(Regex.scan(~r/data-role="piece"/, html))

      # The hook looks up `.runs-piece` inside `this.el`. A bar outside it would
      # be a bar the arrow keys never reach, and nothing else would say so:
      # every bar here is between the hook's div and the end of its table.
      scroll = String.split(html, ~s(<div id="runs-timeline-scroll"), parts: 2) |> List.last()
      inside = String.split(scroll, "</table>", parts: 2) |> hd()
      in_hook = length(Regex.scan(~r/data-role="piece"/, inside))

      assert total == 3
      assert in_hook == total
    end
  end

  describe "the hint" do
    test "says, in words, that a row is one Tab stop and which keys move", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)

      assert has_element?(view, "#runs-timeline-foot #roving-hint")

      hint = view |> element("#roving-hint") |> render() |> squish()

      # The reference's own copy. "one Tab stop" is the claim a reader needs and
      # the one they cannot work out by looking; the four keys and Enter are the
      # whole contract.
      assert hint =~ "Each row’s pieces are one Tab stop"
      assert hint =~ "Left and Right move between pieces"
      assert hint =~ "Home and End jump to the first and last"
      assert hint =~ "Enter opens the run"
    end

    test "quotes the version's own paid-break limit, not a design default", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)

      # The break hatching on the track already says what counts as a paid
      # break, from the same number. A sentence quoting a DIFFERENT one would be
      # a caption contradicting its own figure, and asserting only that the note
      # exists would pass exactly that: this reads the version's own limit back
      # out and requires the footnote to name it.
      assert has_element?(view, "#paid-time-note")

      {:ok, day} =
        Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)

      minutes = day.crew.paid_break_max_minutes
      assert is_integer(minutes)

      note = view |> element("#paid-time-note") |> render() |> squish()

      assert note =~ "breaks of #{minutes} min or less"
    end

    test "the hint is under the table, not above it", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)
      html = render(view)

      # It describes the chart, so it reads after it. A hint above the table is
      # read before the reader knows what it is about.
      assert :binary.match(html, "runs-timeline-scroll") < :binary.match(html, "roving-hint")
    end
  end

  describe "a LiveView patch keeps the roving state" do
    test "sorting re-streams the rows and each row's first bar is still the stop", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)

      # This is the case a client-owned tabindex fails. The hook re-points the
      # row it is in, so after a sort the row a reader was standing on has been
      # re-rendered with a tabindex the server computed, and the rows they were
      # NOT in were never touched. If the tabindex were the client's to keep,
      # the focused row would come back with whichever piece happened to be
      # first in the NEW order, and a reader who had walked to the second piece
      # of a run would silently jump.
      view |> element(~s(#runs-timeline th button[phx-value-key=paid])) |> render_click()

      bars = tabindexes(render(view))

      assert bars != []
      assert Enum.all?(bars, &(&1.tabindex in ["0", "-1"]))
      assert each_row_roving?(bars)

      # Every row still contributes exactly one stop, and it is that row's own
      # first piece.
      assert bars |> Enum.map(& &1.run) |> Enum.uniq() |> Enum.sort() == ["1001", "1002"]

      for run_id <- ["1001", "1002"] do
        row = bars_for(bars, run_id)

        assert row != []
        assert Enum.count(row, &(&1.tabindex == "0")) == 1
        assert Enum.find(row, &(&1.tabindex == "0")).piece == "1"
      end
    end

    test "zooming the track keeps every row's tab stop", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)

      # Zoom doubles the track's width, not the piece list, so the roving
      # sequence must be identical before and after. A change here would mean
      # the bar count moved with the scale.
      before = tabindexes(render(view))

      view |> element("#runs-scale-form") |> render_change(%{"scale" => "zoom"})

      assert has_element?(view, "#runs-timeline[data-scale=zoom]")
      assert tabindexes(render(view)) == before
    end
  end

  describe "what this step cannot prove" do
    test "a piece bar is a real button, so Enter is native activation", ctx do
      w = world(ctx)
      view = open_runs(ctx, w)

      # The card's own case is "Enter on a focused piece opens #run-drawer", and
      # that drawer is step 29's surface — it does not exist yet, and
      # `phx-click="open_run"` has no handler until then. What this step owns is
      # the half that makes Enter work at all: a real `<button>`, which the
      # browser activates on Enter with no key handler of our own. A `<div>`
      # with a click listener would need JS to open the drawer on Enter, and the
      # roving hook deliberately does not handle Enter.
      html = render(view)

      assert html =~ ~s(<button type="button" data-role="piece")

      refute html =~ ~s(<div data-role="piece")
      refute html =~ ~s(<div class="runs-piece")
    end
  end
end
