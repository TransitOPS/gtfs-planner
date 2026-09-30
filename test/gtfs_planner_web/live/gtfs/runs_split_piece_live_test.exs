defmodule GtfsPlannerWeb.Gtfs.RunsSplitPieceLiveTest do
  @moduledoc """
  Split a piece at a relief handover from the drawer.

  A split moves the trips after a chosen gap, so the set that stayed and the set
  that went are both the result. A test that reads back "the new run has some
  trips" would pass if the split at gap 1 moved every trip, or the wrong ones, so
  every case here pins both sides exactly.

  The second fact under test is that a piece can only be split where an operator
  can actually change over. A gap with no relief window is not offered, and its
  absence is stated rather than left as a missing control.
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

  @moduletag :ev_30
  @moduletag timeout: 120_000

  setup do
    %{user: user_fixture()}
  end

  # Run 2001 over all four trips of block 101. Block 101's three gaps carry
  # windows on gaps 0 and 1 only, so this piece has exactly TWO relief points and
  # a third gap that must not be offered.
  defp split_world(ctx) do
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

  # Run 2002 over ONE trip of block 101. A single-trip piece has no internal gap
  # at all, and therefore no internal relief window to split at.
  #
  # A two-trip piece over the block's later trips was tried first and is NOT such
  # a piece: the piece's own `gaps` also carries the gap that forms its START
  # boundary, and that one is marked, so it does have a relief point and does get
  # a split control. The domain is right and the fixture was wrong.
  defp no_relief_world(ctx) do
    user = ctx.user
    w = runs_version_fixture()

    [first | _] = w.blocks["101"]

    trip_run_fixture(w.organization.id, w.version.id, %{
      trip: first,
      day_type_key: w.day_type_key,
      run_id: "2002"
    })

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

  defp trip_ids(w, run_id) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^w.organization.id and row.gtfs_version_id == ^w.version.id and
            row.day_type_key == ^w.day_type_key and row.run_id == ^run_id,
        select: row.trip_id,
        order_by: [asc: row.trip_id]
      )
    )
  end

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
    |> Enum.sort()
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

  # The same `<h>:<mm>` the drawer's clock component renders. The HOUR is
  # padded too: unpadded it gives "6:50" where the page says "06:50", and the
  # comparison silently fails against a correct implementation.
  defp pad(mins) do
    hour = mins |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    minute = mins |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{hour}:#{minute}"
  end

  defp texts(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> Enum.map(&text_of/1)
  end

  defp text_of(cell), do: cell |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp split_options(view, index) do
    view
    |> doc()
    |> LazyHTML.query("#run-split-at-#{index} option")
    |> LazyHTML.attribute("value")
    |> Enum.reject(&(&1 == ""))
  end

  defp split_submit(view, index, gap, to) do
    render_submit(
      view,
      "split_piece",
      %{"piece" => to_string(index), "split" => %{"gap" => gap, "to" => to}}
    )
  end

  # The piece and its trips, read from the DOMAIN rather than assumed, so a
  # fixture change cannot quietly turn a split case into a different split.
  defp piece_of(w, run_id) do
    {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
    run = Enum.find(day.derived.runs, &(&1.run_id == run_id))
    [piece | _] = run.pieces
    # In PIECE order, not sorted: "the trips after the first handover" is about
    # sequence, and sorting first would make `List.first` the alphabetically
    # first ID and quietly compare the wrong two trips.
    {piece, Enum.map(piece.trips, & &1.id)}
  end

  defp sorted(ids), do: Enum.sort(ids)

  describe "the relief points" do
    test "the select lists each internal handover as time, stop and trip", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      labels = texts(view, "#run-split-at-1 option")

      # Asserted against the fixture's OWN windows, not a written-out label.
      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      block = Enum.find(day.day.blocks, &(&1.summary.block_id == "101"))
      assert length(block.windows) == 2

      for window <- block.windows do
        assert Enum.any?(labels, &(&1 =~ ~r/^\d\d:\d\d at .+ \(after .+\)$/)),
               "no option shaped as <time> at <stop> (after <trip>) in #{inspect(labels)}"

        clock = window.start_secs |> Integer.mod(24 * 3600) |> div(60)
        assert Enum.any?(labels, &String.starts_with?(&1, "#{pad(clock)} "))
      end
    end

    test "a gap with no relief window is not offered", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      {piece, _trips} = piece_of(w, "2001")

      # Three gaps, two windows. Offering the windowless third would let a
      # reader split where no operator can change over.
      assert length(piece.gaps) == 3
      assert length(split_options(view, 1)) == 2
    end

    test "each option names the trip it splits after", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      {_piece, trips} = piece_of(w, "2001")
      labels = texts(view, "#run-split-at-1 option")

      # Option 1 splits after the first trip, option 2 after the second.
      assert Enum.any?(labels, &(&1 =~ "(after #{List.first(trips)})"))
      assert Enum.any?(labels, &(&1 =~ "(after #{Enum.at(trips, 1)})"))
    end

    test "nothing is chosen until the reader chooses", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      # A split has two choices and re-routes vehicle work, so neither defaults
      # to its first option. With a prompt the browser selects the prompt's
      # EMPTY option, not the first relief point — otherwise a stray press
      # splits a run at whichever handover happened to be listed first.
      refute has_element?(view, "#run-split-at-1 option[value='1'][selected]")
      refute has_element?(view, "#run-split-to-1 option[value=__new][selected]")
    end
  end

  describe "a piece with no relief point" do
    test "it says so and offers no split control", ctx do
      w = no_relief_world(ctx)
      view = open(ctx, w, "run=2002")

      # Asserted from the domain, so this case cannot pass against a fixture
      # that stopped having a windowless gap.
      # The DOMAIN precondition: this piece has no internal gap, so it has no
      # internal relief window. Asserting on the rendered select alone would pass
      # for a piece that had simply lost its controls.
      # The DOMAIN precondition, in the form the component uses: a piece with
      # fewer than two trips has no gap BETWEEN two of its trips, so it has no
      # internal relief point. (A piece's `gaps` is not empty here — it carries
      # the gap that forms its own start boundary, which is not a split point.)
      {piece, _trips} = piece_of(w, "2002")
      assert length(piece.trips) == 1
      assert piece.gaps != []

      assert has_element?(view, "#run-drawer", "No relief point inside this piece.")
      refute has_element?(view, "#run-split-at-1")
      refute has_element?(view, "#run-split-piece-form-1")
    end

    test "it still offers the move control", ctx do
      w = no_relief_world(ctx)
      view = open(ctx, w, "run=2002")

      # No split is a fact about RELIEF, not about the piece being uneditable.
      # A piece that cannot be split must still be movable.
      assert has_element?(view, "#run-move-piece-form-1")
      assert has_element?(view, "#run-move-to-1")
    end
  end

  describe "splitting into a new run" do
    test "it moves exactly the trips after the chosen gap", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      {_piece, trips} = piece_of(w, "2001")
      assert trip_ids(w, "2001") == sorted(trips)

      # Splitting AT the first handover keeps the first trip and moves the rest.
      split_submit(view, 1, "1", "__new")

      assert trip_ids(w, "2001") == sorted([List.first(trips)])
      assert trip_ids(w, "2002") == sorted(Enum.drop(trips, 1))
      assert all_run_ids(w) == ["2001", "2002"]
    end

    test "splitting later moves fewer trips", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      {_piece, trips} = piece_of(w, "2001")

      # The second handover: only the last trip changes run. A split that moved
      # the same set as the first would pass the first case and fail this one.
      split_submit(view, 1, "2", "__new")

      assert trip_ids(w, "2001") == sorted(Enum.take(trips, 2))
      assert trip_ids(w, "2002") == sorted(Enum.drop(trips, 2))
    end

    test "the new piece starts at a relief point", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      split_submit(view, 1, "1", "__new")

      # The boundary is a HANDOVER, and the drawer already marks a relief start
      # with the words "(relief point)". The prototype draws a `⇄` glyph here;
      # the app's own wording is used instead, and the drift is recorded.
      assert text(view, "#run-drawer") =~ "(relief point)"
    end

    test "the drawer follows the run the trips went to", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      split_submit(view, 1, "1", "__new")

      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&run=2002")
      assert has_element?(view, "#runs-run-2002")
    end

    test "it says how many trips moved, and offers Undo", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      split_submit(view, 1, "1", "__new")

      assert text(view, "[data-role=toast-text]") == "3 trips from block 101 moved to run 2002."
      assert has_element?(view, "#runs-undo")
    end
  end

  describe "splitting into a run that exists" do
    test "it names the run the reader chose", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      # Run 2002 is the next number, so it is created by the first split; a
      # second run gives the "already existed" path something to say.
      split_submit(view, 1, "1", "__new")
      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&run=2002")

      split_submit(view, 1, "1", "2003")

      # `new_run_id` is nil for a move into an existing run, so a text that
      # branched on that alone would go blank here.
      assert text(view, "[data-role=toast-text]") =~ "moved to run 2003."
    end
  end

  describe "Undo" do
    test "it restores the single piece", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      {_piece, trips} = piece_of(w, "2001")

      split_submit(view, 1, "1", "__new")
      view |> element("#runs-undo") |> render_click()

      # Re-read from the database: the toast saying "Undone." is the create-run
      # tests' subject, not this one's.
      assert trip_ids(w, "2001") == sorted(trips)
      assert trip_ids(w, "2002") == []
      assert all_run_ids(w) == ["2001"]
      assert text(view, "[data-role=toast-text]") == "Undone."

      # And the run is ONE piece again, read from the domain.
      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      run = Enum.find(day.derived.runs, &(&1.run_id == "2001"))
      assert [piece] = run.pieces
      assert sorted(Enum.map(piece.trips, & &1.id)) == sorted(trips)
    end
  end

  describe "refusals" do
    test "nothing chosen writes nothing", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      before = trip_ids(w, "2001")
      split_submit(view, 1, "", "")

      assert trip_ids(w, "2001") == before
      assert all_run_ids(w) == ["2001"]
      assert text(view, "[data-role=toast-text]") =~ "Choose a relief point"
    end

    test "a gap the page never offered is refused", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      before = trip_ids(w, "2001")

      # Block 101's third gap has no window and is deliberately not offered.
      # Posting it anyway would split where no operator can change over.
      split_submit(view, 1, "3", "__new")

      assert trip_ids(w, "2001") == before
      assert all_run_ids(w) == ["2001"]
    end

    test "a piece that is not there writes nothing", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      before = trip_ids(w, "2001")
      split_submit(view, 9, "1", "__new")

      assert trip_ids(w, "2001") == before
      assert text(view, "[data-role=toast-text]") =~ "no longer here"
    end

    test "a split whose piece changed hands is refused", ctx do
      w = split_world(ctx)
      view = open(ctx, w, "run=2001")

      # A colleague takes one of the trips that would move. The moves carry
      # `from: 2001`, and it is now elsewhere, so the shared optimistic check
      # refuses.
      {_piece, trips} = piece_of(w, "2001")
      [stale | _] = Enum.drop(trips, 1)

      {:ok, _} =
        Gtfs.apply_run_moves(w.organization.id, w.version.id, w.day_type_key, [
          %{trip_id: stale, from: "2001", to: nil}
        ])

      after_colleague = trip_ids(w, "2001")
      split_submit(view, 1, "1", "__new")

      assert text(view, "[data-role=toast-text]") =~ "changed since the page loaded"
      assert trip_ids(w, "2001") == after_colleague
    end
  end
end
