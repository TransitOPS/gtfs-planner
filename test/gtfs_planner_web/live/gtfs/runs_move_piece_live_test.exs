defmodule GtfsPlannerWeb.Gtfs.RunsMovePieceLiveTest do
  @moduledoc """
  Move a piece to another run from the drawer.

  Rows are re-read, and here that is the whole point rather than a formality. A
  move writes rows for one piece's trips, so a test that reads back "some run has
  this trip" proves almost nothing — the move could be moving the wrong piece's
  trips, or both pieces', and still look right. Every case here reads back the
  exact trip sets on both sides of the move, because the set that did not move is
  as much of the result as the set that did.
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

  @moduletag :ev_29
  @moduletag timeout: 120_000

  setup do
    %{user: user_fixture()}
  end

  # The shared world: run 1001 over the head of block 101 and the tail of block
  # 102, so it is a TWO-piece run, plus run 1002 over one trip of block 101.
  # Moving a piece needs a destination that already exists, and a one-piece run
  # for the "the source disappears" case needs its own world below.
  defp two_run_world(ctx) do
    user = ctx.user
    w = runs_version_fixture()

    [first_101, second_101 | _tail_101] = w.blocks["101"]
    [_first_102, second_102] = w.blocks["102"]

    for trip <- [first_101, second_102] do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: "1001"
      })
    end

    trip_run_fixture(w.organization.id, w.version.id, %{
      trip: second_101,
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

  # Run 1001 holds exactly one trip, so it derives as a ONE-piece run and a move
  # of its only piece leaves nothing behind.
  defp one_piece_world(ctx) do
    user = ctx.user
    w = runs_version_fixture()

    [first_101, second_101 | _tail_101] = w.blocks["101"]
    [_first_102, second_102] = w.blocks["102"]

    trip_run_fixture(w.organization.id, w.version.id, %{
      trip: first_101,
      day_type_key: w.day_type_key,
      run_id: "1001"
    })

    for trip <- [second_101, second_102] do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: "1002"
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

  defp attribute(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp text_of(cell), do: cell |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp submit_piece(view, index, to) do
    view
    |> form("#run-move-piece-form-#{index}", %{
      "piece" => to_string(index),
      "move" => %{"to" => to}
    })
    |> render_submit()
  end

  defp option_values(view, index) do
    view
    |> doc()
    |> LazyHTML.query("#run-move-to-#{index} option")
    |> LazyHTML.attribute("value")
    |> Enum.reject(&(&1 == ""))
  end

  describe "the form" do
    test "there is one per piece, named by the piece", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs
      assert length(run.pieces) == 2

      for index <- 1..2 do
        assert has_element?(view, "#run-move-piece-form-#{index}")
        assert has_element?(view, "#run-move-to-#{index}")

        assert has_element?(
                 view,
                 "#run-move-piece-form-#{index} button[type=submit]",
                 "Move piece"
               )
      end
    end

    test "the current run is not offered as a destination", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      # Moving a piece to the run it is already on is not a move, and offering
      # it puts a choice in the list that cannot mean anything.
      refute "1001" in option_values(view, 1)
      assert "1002" in option_values(view, 1)
    end

    test "the other run's option says which run it is", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      labels =
        view
        |> doc()
        |> LazyHTML.query("#run-move-to-1 option")
        |> Enum.map(&text_of/1)

      # ID, shape and time: the three things that let a reader tell two runs
      # apart without opening either.
      # ID, shape and time: the three things that let a reader tell two runs
      # apart without opening either. Asserted in parts, because the separators
      # are a middot and an en dash and a regex that spells them out fails
      # against the exact label the page is supposed to show.
      option_label = Enum.find(labels, &(&1 =~ "Run 1002"))
      assert option_label =~ "One piece"
      assert option_label =~ ~r/\d\d:\d\d.*\d\d:\d\d/
    end

    test "the first option is a new run, numbered above every run in use", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      [first | _] = option_values(view, 1)
      assert first == "__new"

      assert has_element?(view, "#run-move-to-1 option[value=__new]", "New run (1003)")
    end

    test "nothing is chosen until the reader chooses", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      # The prototype lists "New run" first, so with no prompt the FIRST option
      # would be selected and a stray press of a button labelled "Move piece"
      # would create a run. A move has to be chosen.
      assert attribute(view, "#run-move-to-1", "value") in [nil, ""]
    end
  end

  describe "moving to a run that exists" do
    test "it writes exactly that piece's trips and the drawer follows", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs
      [piece | _] = run.pieces

      source_before = trip_ids(w, "1001")
      target_before = trip_ids(w, "1002")
      piece_trips = piece.trips |> Enum.map(& &1.id) |> Enum.sort()

      submit_piece(view, 1, "1002")

      # The piece's trips moved...
      assert trip_ids(w, "1002") == Enum.sort(target_before ++ piece_trips)
      # ...and the other piece's did NOT. A move of both pieces would satisfy
      # the first assertion and fail this one, which is the whole point of
      # re-reading the set that stayed.
      assert trip_ids(w, "1001") == source_before -- piece_trips
      assert length(trip_ids(w, "1001")) == 1
    end

    test "the drawer shows the destination run", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      submit_piece(view, 1, "1002")

      # The reader chose where the piece went; leaving the drawer on the run they
      # moved it FROM shows a run that no longer holds what they just moved.
      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&run=1002")
      assert has_element?(view, "#runs-run-1002")

      # 1001 is STILL on the page, because it kept its other piece. Asserting
      # its absence would be asserting a move removes the source run, which is
      # the one-piece case's job and not this one's.
      assert has_element?(view, "#runs-run-1001")
      assert text(view, "#run-drawer") =~ "Run 1002"
    end

    test "it says which run the piece joined, and offers Undo", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      submit_piece(view, 1, "1002")

      # `apply_run_moves/4` returns `new_run_id: nil` for a move that made no
      # run, so the text names the run it joined rather than inventing a number.
      assert text(view, "[data-role=toast-text]") == "Piece moved to run 1002."
      assert has_element?(view, "#runs-undo")
    end
  end

  describe "moving to a new run" do
    test "it creates the next number", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs
      [piece | _] = run.pieces
      piece_trips = piece.trips |> Enum.map(& &1.id) |> Enum.sort()
      source_before = trip_ids(w, "1001")

      submit_piece(view, 1, "__new")

      # The number the option PROMISED is the number the write used. Asserting
      # only that some new run appeared would pass if the page showed one number
      # and the domain chose another.
      assert trip_ids(w, "1003") == piece_trips
      assert trip_ids(w, "1001") == source_before -- piece_trips
      assert all_run_ids(w) == ["1001", "1002", "1003"]
    end

    test "the drawer follows the new run, not the source", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      submit_piece(view, 1, "__new")

      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&run=1003")
      assert has_element?(view, "#runs-run-1003")
    end

    test "it names the run it made", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      submit_piece(view, 1, "__new")

      assert text(view, "[data-role=toast-text]") == "Piece moved to run 1003."
    end
  end

  describe "a source run that no longer has a piece" do
    test "a one-piece run disappears once its piece moves", ctx do
      w = one_piece_world(ctx)
      view = open(ctx, w, "run=1001")

      # Asserted from the domain rather than assumed, so this case cannot pass
      # against a fixture that stopped being a one-piece run.
      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      {one_piece, _} = Enum.split_with(day.derived.runs, &(&1.run_id == "1001"))
      assert [run] = one_piece
      assert length(run.pieces) == 1

      submit_piece(view, 1, "1002")

      assert trip_ids(w, "1001") == []
      refute "1001" in all_run_ids(w)
      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&run=1002")
    end
  end

  describe "Undo" do
    test "it puts the piece back and restores both runs", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs
      [piece | _] = run.pieces
      piece_trips = piece.trips |> Enum.map(& &1.id) |> Enum.sort()
      source_before = trip_ids(w, "1001")
      target_before = trip_ids(w, "1002")

      submit_piece(view, 1, "1002")
      view |> element("#runs-undo") |> render_click()

      # Re-read from the database: the toast saying "Undone." is the create-run
      # tests' subject, not this one's.
      assert trip_ids(w, "1001") == source_before
      assert trip_ids(w, "1002") == target_before
      assert piece_trips -- source_before == []
      assert text(view, "[data-role=toast-text]") == "Undone."
    end

    test "it restores a new run out of existence", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      submit_piece(view, 1, "__new")
      assert "1003" in all_run_ids(w)

      view |> element("#runs-undo") |> render_click()

      # A run created by the move goes away with it, or the undo is only half
      # an undo: the piece is back but a run the reader never wanted remains.
      assert all_run_ids(w) == ["1001", "1002"]
      assert trip_ids(w, "1003") == []
    end

    test "an undo whose piece moved again is refused", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      submit_piece(view, 1, "1002")

      # A colleague moves one of the same trips onward. The undo's moves say
      # `from: 1002`, and that trip is now on 1003, so the shared optimistic
      # check refuses and the colleague's move stands.
      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs
      [piece | _] = run.pieces
      [trip | _] = piece.trips

      {:ok, _} =
        Gtfs.apply_run_moves(w.organization.id, w.version.id, w.day_type_key, [
          %{trip_id: trip.id, from: "1002", to: "1003"}
        ])

      view |> element("#runs-undo") |> render_click()

      assert text(view, "[data-role=toast-text]") == "Can't undo: these runs changed since."
      assert trip_ids(w, "1003") != []
    end
  end

  describe "refusals" do
    test "nothing chosen writes nothing", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      before = {trip_ids(w, "1001"), trip_ids(w, "1002")}

      submit_piece(view, 1, "")

      assert {trip_ids(w, "1001"), trip_ids(w, "1002")} == before
      assert text(view, "[data-role=toast-text]") =~ "Choose a run"
    end

    test "a piece that is not there writes nothing", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      before = trip_ids(w, "1001")

      # A form that posted a position rather than trips can be posted with a
      # position the page never showed. Refusing is the only safe answer:
      # clamping to piece 2 would move the WRONG vehicle work.
      render_submit(view, "move_piece", %{"piece" => "9", "move" => %{"to" => "1002"}})

      assert trip_ids(w, "1001") == before
      assert text(view, "[data-role=toast-text]") =~ "no longer here"
    end

    test "piece 0 writes nothing, rather than moving the last piece", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      before = trip_ids(w, "1001")

      render_submit(view, "move_piece", %{"piece" => "0", "move" => %{"to" => "1002"}})

      assert trip_ids(w, "1001") == before
      assert text(view, "[data-role=toast-text]") =~ "no longer here"
    end

    test "a piece whose run changed underneath the page is refused", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      # A colleague takes run 1001's piece out from under the reader. The moves
      # carry `from: 1001`, and it is now 1002, so the shared optimistic check
      # refuses. There is no separate "is this still the right piece" test,
      # because the moves themselves carry it.
      {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
      [run | _] = day.derived.runs
      [piece | _] = run.pieces
      [trip | _] = piece.trips

      {:ok, _} =
        Gtfs.apply_run_moves(w.organization.id, w.version.id, w.day_type_key, [
          %{trip_id: trip.id, from: "1001", to: "1002"}
        ])

      # Taken AFTER the colleague's move: the question is whether the PAGE wrote
      # anything, not what the colleague did to the same rows.
      before = trip_ids(w, "1001")
      target_before = trip_ids(w, "1002")

      submit_piece(view, 1, "1002")

      assert text(view, "[data-role=toast-text]") =~ "changed since the page loaded"
      assert {trip_ids(w, "1001"), trip_ids(w, "1002")} == {before, target_before}
    end
  end
end
