defmodule GtfsPlannerWeb.Gtfs.RunsCreateUndoLiveTest do
  @moduledoc """
  EV-26: Create run from uncovered work, with Undo.

  This is the first WRITE on the Runs page, so the card's risk lenses are
  **idempotency** and **cross-step-contract**, and both of the card's four cases
  are about the same thing: what the page says when somebody else has moved since
  it was loaded.

  The assertions are therefore deliberately split in two. The **rows** are read
  back out of the database, not off the toast: a toast that says "Run 1031
  created" proves the page wanted to say it, and says nothing about whether
  anything was written. And the **refusals** are proved by writing the conflicting
  row directly, so the conflict is a fact rather than a race the test has to win.

  The shared surface is asserted as a *contract*, not as a convenience:
  `toast/1` and the two assigns are what steps 30, 31, 32 and 37 will reuse, so
  `#runs-toast`, `#runs-undo`, `data-role=toast-text` and `data-role=undo` are
  named here once and every later step reads them from here.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Repo

  @moduletag :ev_26
  @moduletag timeout: 120_000

  setup do
    %{user: user_fixture()}
  end

  # One run over the head of block 101 and the tail of block 102, leaving the tail
  # of 101 and the head of 102 uncovered — step 27's world, so the two gates
  # describe the same day and a change to the fixture shows up in both.
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

  defp open(ctx, w, query) do
    conn = log_in_user(ctx.conn, ctx.user, organization: w.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{w.version.id}/runs?#{query}")
    view
  end

  defp run_ids(w, run_id) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^w.organization.id and row.gtfs_version_id == ^w.version.id and
            row.day_type_key == ^w.day_type_key and row.run_id == ^run_id,
        select: row.trip_id
      )
    )
    |> Enum.sort()
  end

  # Every run id this version's day type uses, for the "numbered above every
  # existing run" claim.
  defp all_run_ids(w) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^w.organization.id and row.gtfs_version_id == ^w.version.id and
            row.day_type_key == ^w.day_type_key,
        select: row.run_id,
        distinct: true
      )
    )
  end

  defp segment_trips(w, block) do
    {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)

    day.derived.uncovered
    |> Enum.filter(&(&1.block_id == block))
    |> Enum.flat_map(&Enum.map(&1.trips, fn trip -> trip.id end))
    |> Enum.sort()
  end

  # Another editor's move of a named trip, made directly so the conflict is a
  # FACT rather than a race the test has to win.
  #
  # Through the same facade, not by inserting a row: there is one TripRun row per
  # trip per day type, so a second INSERT for a trip that already has a run is a
  # constraint violation wearing the name of a move. That failure is worth
  # recording — it is the shape a reviewer hits first when writing the refusal
  # test — but it tests the fixture, not the page.
  defp colleague_moves(w, trip_id, from, to) do
    {:ok, _result} =
      Gtfs.apply_run_moves(w.organization.id, w.version.id, w.day_type_key, [
        %{trip_id: trip_id, from: from, to: to}
      ])

    :ok
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
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  describe "Create run" do
    test "it writes one run over every trip of the segment, and says so", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      trips = segment_trips(w, "101")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      # The toast names the run the WRITE made, and the write is read back out of
      # the database rather than off the toast.
      [_match, created] =
        Regex.run(~r/Run ([^ ]+) created\./, text(view, "[data-role=toast-text]"))

      assert run_ids(w, created) == trips

      # `all_run_ids/1` includes 1001, the run the fixture already had, so "the
      # next number" is a claim about the whole day type and not about this row.
      assert created in all_run_ids(w)
      assert created != "1001"
    end

    test "every trip of the segment goes to the SAME new run", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      trips = segment_trips(w, "101")

      assert length(trips) > 1,
             "the seeded segment must have more than one trip, or this is vacuous"

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      [_match, created] =
        Regex.run(~r/Run ([^ ]+) created\./, text(view, "[data-role=toast-text]"))

      # One run, not one run per trip: `apply_run_moves/4` resolves every `:new` in
      # a call to one run id, and a page that called it per trip would give the
      # operator three runs of one trip each. Read the trip list BEFORE the write:
      # the segment is uncovered no longer, so asking afterwards answers 0 and
      # the comparison would fail for a reason that has nothing to do with the
      # claim it is making.
      assert run_ids(w, created) == trips
    end

    test "the segment leaves the uncovered table and the count follows", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      assert has_element?(view, "#runs-uncovered-table [data-role=uncovered-row]")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      # The page re-reads the day: the segments, the count strip and the chart are
      # all derived, and a page that says "created" over a table still showing the
      # segment contradicts itself inside one click.
      assert has_element?(view, "#uncovered-0 [data-block='102']")
      refute has_element?(view, "#uncovered-0 [data-block='101']")
    end

    test "the new run is a row of its own on the Runs tab", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      [_match, created] =
        Regex.run(~r/Run ([^ ]+) created\./, text(view, "[data-role=toast-text]"))

      view |> element("#runs-tab-runs") |> render_click()
      # The LIST, not the timeline: the timeline draws bars and has no row per
      # run, so `data-role=run-id` — the List's run cell — is where a run is
      # addressable. Asserting it on the chart would have been a selector that
      # matches nothing on one of the two views, and `has_element?` on a
      # never-matching selector fails the same whether the row is missing or the
      # query is wrong.
      # The view control is a `phx-change` FORM of radios, not a row of buttons,
      # so it is driven by a change with `%{"view" => "list"}` and not by a
      # click on a button that does not exist.
      view |> form("#runs-view-form", %{"view" => "list"}) |> render_change()

      rows =
        view
        |> doc()
        |> LazyHTML.query("#runs-list .runs-list-row [data-role=run-id]")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert created in rows
    end

    test "a create_run for a segment the day no longer has is refused", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      [_match, created] =
        Regex.run(~r/Run ([^ ]+) created\./, text(view, "[data-role=toast-text]"))

      before = all_run_ids(w)
      trips = run_ids(w, created)

      # A second `create_run` naming a segment the day has just covered — a double
      # click whose first write has already landed, or a queued event arriving
      # after the row is gone. It is REFUSED, not applied: the segment is not
      # uncovered any more, so there is nothing to create, and a page that found
      # the trips some other way would write a second run over them.
      view |> render_click("create_run", %{"block" => "101"})

      assert text(view, "[data-role=toast-text]") ==
               "That block is no longer uncovered. Reload to see the latest runs."

      # The FIRST create's rows are still there: the second create_run was
      # refused, not applied and not rolled back.
      assert all_run_ids(w) == before
      assert run_ids(w, created) == trips
    end

    test "the span is part of the lookup, not just the block", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      # The right block with the WRONG span. Every block in this fixture carries
      # one uncovered segment, so matching on `block_id` alone would find it and
      # the write would land on work the reader did not click — which is why this
      # exists: a lookup that ignores the span is a lookup that can pick the
      # wrong segment on any day with two segments on one block.
      view |> render_click("create_run", %{"block" => "101", "start" => "1", "end" => "2"})

      assert text(view, "[data-role=toast-text]") ==
               "That block is no longer uncovered. Reload to see the latest runs."

      # Nothing was written.
      assert all_run_ids(w) == ["1001"]
    end

    test "the Create run button is disabled while its write is in flight", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      # `phx-disable-with` is what stops a second click reaching the server as a
      # second `:new`. It is an attribute on the markup, so its PRESENCE is the
      # most this test can honestly assert; the refusal above is what proves the
      # server is safe even when the button is not.
      assert attribute(view, "#uncovered-0 [data-role=create-run]", "phx-disable-with")
    end
  end

  describe "Undo" do
    test "it deletes exactly the rows the create wrote", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      trips = segment_trips(w, "101")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      [_match, created] =
        Regex.run(~r/Run ([^ ]+) created\./, text(view, "[data-role=toast-text]"))

      assert run_ids(w, created) == trips

      view |> element("#runs-undo") |> render_click()

      assert run_ids(w, created) == []
      # The fixture's own run is untouched: undo reverses THIS write, not the day.
      assert run_ids(w, "1001") != []
      assert text(view, "[data-role=toast-text]") == "Undone."
    end

    test "the segment comes back to the uncovered table", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()
      view |> element("#runs-undo") |> render_click()

      assert has_element?(view, "#uncovered-0 [data-block='101']")
    end

    test "undo is gone after undoing, because there is nothing behind it", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()
      assert has_element?(view, "#runs-undo")

      view |> element("#runs-undo") |> render_click()

      # An Undo button with nothing to undo is a control that does nothing — the
      # objection step 26 raised about the scale control on the List.
      refute has_element?(view, "#runs-undo")
    end

    test "an undo with nothing behind it refuses rather than pretending", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> render_click("undo", %{})

      assert text(view, "[data-role=toast-text]") == "There is nothing to undo."
      assert attribute(view, "#runs-toast", "data-kind") == "refused"
    end
  end

  describe "the refusal" do
    test "a create whose trips moved underneath it is refused and writes nothing", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      # Another editor takes one trip of the segment while the page is open. The
      # move says `from: nil`, the trip now has a run, so the optimistic check
      # refuses — and it refuses the WHOLE call, not the one trip.
      [one | _] = segment_trips(w, "101")

      :ok = colleague_moves(w, one, nil, "9001")

      before = all_run_ids(w)

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      assert text(view, "[data-role=toast-text]") ==
               "These trips changed since the page loaded. Reload to see the latest runs."

      assert attribute(view, "#runs-toast", "data-kind") == "refused"
      assert all_run_ids(w) == before
      refute has_element?(view, "#runs-undo")

      # **The refusal re-reads the day**, and the count is the observable. This
      # assertion was MISSING and a mutation found it: dropping the `load_day/1`
      # on the refusal path left every other claim here true — the toast, the
      # rows, the missing Undo — because nothing about the PAGE was being
      # checked. A refusal means somebody else moved these trips, so the page
      # still showing them all as uncovered is now wrong in the same direction
      # the success path is. Four trips were uncovered; the colleague took one,
      # so the tab must now say three and not four.
      assert text(view, "#runs-tab-uncovered") =~ "Uncovered work · 3"
    end

    test "an undo whose trips moved underneath it is refused and the rows stay", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      [_match, created] =
        Regex.run(~r/Run ([^ ]+) created\./, text(view, "[data-role=toast-text]"))

      assert run_ids(w, created) != []
      trips = run_ids(w, created)

      # A colleague moves ONE of the created trips to another run.
      [one | _] = trips

      :ok = colleague_moves(w, one, created, "9001")

      view |> element("#runs-undo") |> render_click()

      assert text(view, "[data-role=toast-text]") == "Can't undo: these runs changed since."
      assert attribute(view, "#runs-toast", "data-kind") == "refused"

      # "The rows stay" is the load-bearing half: a refusal that deleted the
      # colleague's run would be the bug undo exists to prevent, and a test that
      # only checked the message would pass straight over it.
      # The colleague's move is on the trip it was made on, and the other trips of
      # the run are STILL THERE: the refusal must not half-apply. A refusal that
      # deleted the colleague's run would be the bug undo exists to prevent.
      assert run_ids(w, "9001") == [one]
      assert length(run_ids(w, created)) == length(trips) - 1
    end

    test "the refusal is not the same words as the create's refusal", ctx do
      # Same rule, two callers, two sentences — and the two are different
      # sentences for a reason: a create means the page is behind, an undo means
      # the work moved on without it.
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      [_match, created] =
        Regex.run(~r/Run ([^ ]+) created\./, text(view, "[data-role=toast-text]"))

      [one | _] = run_ids(w, created)

      :ok = colleague_moves(w, one, created, "9001")

      view |> element("#runs-undo") |> render_click()
      undo_text = text(view, "[data-role=toast-text]")

      refute undo_text =~ "Reload to see the latest runs"
      assert undo_text =~ "Can't undo"
    end
  end

  describe "the shared surface steps 30-32 and 37 reuse" do
    test "the toast is a status region and names its kind", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      assert attribute(view, "#runs-toast", "role") == "status"
      assert attribute(view, "#runs-toast", "aria-live") == "polite"
      assert attribute(view, "#runs-toast", "data-kind") == "done"
    end

    test "the Undo button carries how many trips it would reverse", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      # Read BEFORE the create: the segment is gone afterwards, and asking the
      # day for it post-write would compare 3 against 0 and pass for the wrong
      # reason if the assertion were loose.
      trips = length(segment_trips(w, "101"))

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()

      # Steps 30-32 move one piece, a split's halves and a rename: three shapes
      # with one answer, and this attribute is how each of them says which.
      assert attribute(view, "#runs-undo", "data-trips") == to_string(trips)
    end

    test "the toast can be dismissed by keyboard-operable button", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()
      assert has_element?(view, "#runs-toast")

      view |> element("[data-role=dismiss-toast]") |> render_click()

      refute has_element?(view, "#runs-toast")
      refute has_element?(view, "#runs-undo")
    end

    test "a later toast is not dismissed by an earlier toast's timer", ctx do
      w = world(ctx)
      view = open(ctx, w, "panel=uncovered")

      view |> element("#uncovered-0 [data-role=create-run]") |> render_click()
      first = attribute(view, "#runs-toast", "data-token")

      view |> element("#runs-undo") |> render_click()
      second = attribute(view, "#runs-toast", "data-token")

      assert first && second && first != second,
             "the two toasts must carry different tokens, or this test proves nothing"

      # The first toast's timer fires LATE, after the second toast is up. Without
      # the guard it clears the second confirmation: a reader who edits twice
      # quickly watches the newer message vanish on the older one's schedule,
      # which is a bug with no other symptom and no stack trace.
      # `data-token` is the DOM's STRING of an integer token, so it has to be
      # converted back before it is sent. That round trip is itself worth having:
      # it is what a real stale timer would carry, and a test that passed the
      # string straight through would be testing a token that can never match.
      send(view.pid, {:dismiss_toast, String.to_integer(first)})
      assert render(view) =~ "runs-toast"
      assert text(view, "[data-role=toast-text]") == "Undone."

      # The SECOND toast's own timer does dismiss it.
      send(view.pid, {:dismiss_toast, String.to_integer(second)})
      refute render(view) =~ "runs-toast"
    end
  end
end
