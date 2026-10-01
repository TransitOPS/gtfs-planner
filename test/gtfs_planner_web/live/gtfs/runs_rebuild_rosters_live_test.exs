defmodule GtfsPlannerWeb.Gtfs.RunsRebuildRostersLiveTest do
  @moduledoc """
  What the Runs rebuild confirmation says about the roster.

  A rebuild renumbers the day type's runs, and the roster's slots name those run
  numbers, so a rebuild is the one apply that quietly invalidates work done on
  another page. The confirmation therefore names how many of these runs the
  roster is using and on how many lines — and says nothing at all when the
  roster holds none of them, because a warning nobody can act on is noise.

  The counts come from the stored roster rows, written through the same writers
  the Rosters page uses, so the sentence cannot drift from the rows it claims
  about: the test reads `roster_line_days` back as well as reading the dialog.
  The runs are the page's own derivation input, so nothing here inserts the count
  itself.

  Rows are created inside the SQL Sandbox transaction and rolled back.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Repo

  @moduletag :ev_39
  @moduletag timeout: 120_000

  @weekdays [1, 2, 3, 4, 5]

  setup do
    %{conn: build_conn(), user: user_fixture()}
  end

  test "names the slots and lines the roster holds of the day type", ctx do
    w = ctx |> world() |> rostered()

    view = open(ctx, w)
    before = saved_run_ids(w)

    view |> element("#runs-suggest") |> render_click()
    view |> element("#runs-scope-rebuild") |> render_click()
    view |> element("#runs-preview") |> render_click()
    view |> element("#runs-apply") |> render_click()

    assert has_element?(view, "#runs-rebuild-confirm[data-open=true]")

    body = text(view, "#runs-rebuild-confirm-rosters")

    # Whitespace-tolerant, because the formatter may wrap between a figure and
    # its noun and a literal match would then fail on layout rather than on
    # content. `squish/1` collapses the rendered line breaks, so the sentence is
    # compared as a reader reads it rather than as the formatter laid it out.
    assert squish(body) ==
             "Roster lines use 10 of these runs on 2 lines. " <>
               "After the rebuild their slots show as changed or removed until you set them again."

    # The figure is the roster's own rows, not a number typed into the dialog.
    assert stored_slot_count(w) == 10
    assert stored_line_count(w) == 2

    # Asking has not written anything.
    assert saved_run_ids(w) == before
  end

  test "says nothing about the roster when the day type has no slots", ctx do
    w = ctx |> world() |> partly_covered()

    view = open(ctx, w)

    view |> element("#runs-suggest") |> render_click()
    view |> element("#runs-scope-rebuild") |> render_click()
    view |> element("#runs-preview") |> render_click()
    view |> element("#runs-apply") |> render_click()

    assert has_element?(view, "#runs-rebuild-confirm[data-open=true]")

    refute has_element?(view, "#runs-rebuild-confirm-rosters")
    refute text(view, "#runs-rebuild-confirm") =~ "Roster lines use"

    # The rest of the confirmation is unchanged: the roster sentence is additive.
    assert text(view, "#runs-rebuild-confirm-summary") =~ "renumbered"
  end

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
    # A FRESH conn per open: `live/2` consumes the conn it is given.
    conn = log_in_user(ctx.conn, ctx.user, organization: w.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{w.version.id}/runs")
    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp text(view, selector), do: view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text()

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # A day with runs AND uncovered work, so the rebuild scope has something to do
  # and the page offers it.
  defp partly_covered(w) do
    {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
    [segment | _rest] = day.derived.uncovered

    moves = Enum.map(segment.trips, fn trip -> %{trip_id: trip.id, from: nil, to: :new} end)
    {:ok, _result} = Gtfs.apply_run_moves(w.audit, w.day_type_key, moves)

    w
  end

  # Two lines working the day type's two runs Monday to Friday: ten slots on two
  # lines. The runs are saved rows first, because a slot stores the run's times
  # at the moment it is set and has to be set against a run that exists.
  defp rostered(w) do
    for {block_id, run_id} <- [{"101", "2001"}, {"102", "2002"}],
        trip <- w.blocks[block_id] do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: run_id
      })
    end

    for run_id <- ["2001", "2002"] do
      line = new_line(w)

      for weekday <- @weekdays do
        assert {:ok, %{short_rests: _rest}} = set(w, line, weekday, run_id)
      end
    end

    w
  end

  defp new_line(w) do
    assert {:ok, %{id: id, line_number: _number}} =
             Gtfs.create_roster_line(w.organization.id, w.version.id)

    id
  end

  defp set(w, line_id, weekday, run_id),
    do: Gtfs.set_roster_slot(w.organization.id, w.version.id, line_id, weekday, run_id)

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

  defp stored_slot_count(w) do
    import Ecto.Query

    Repo.one(
      from(d in RosterLineDay,
        where:
          d.organization_id == ^w.organization.id and
            d.gtfs_version_id == ^w.version.id and d.day_type_key == ^w.day_type_key,
        select: count(d.id)
      )
    )
  end

  defp stored_line_count(w) do
    import Ecto.Query

    Repo.one(
      from(d in RosterLineDay,
        where:
          d.organization_id == ^w.organization.id and
            d.gtfs_version_id == ^w.version.id and d.day_type_key == ^w.day_type_key,
        select: count(d.roster_line_id, :distinct)
      )
    )
  end
end
