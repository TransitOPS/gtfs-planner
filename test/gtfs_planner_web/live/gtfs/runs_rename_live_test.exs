defmodule GtfsPlannerWeb.Gtfs.RunsRenameLiveTest do
  @moduledoc """
  EV-28: Rename a run from the drawer.

  The card's independence field is "rows re-read", and that is the shape of this
  gate: **the rows are read back out of the database, never off the toast.** A
  toast that says "Renamed to 2005" proves the page wanted to say it, and says
  nothing about whether a single row moved.

  The third case is the one this step is really about. Step 28 established ONE
  undo surface, and a rename is the first write that is not a move — so the gate
  has to show that `rename_run/5`'s own undo reaches that surface unchanged,
  rather than that a rename happens to be reversible by some other route.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  @moduletag :ev_28
  @moduletag timeout: 120_000

  setup do
    %{user: user_fixture()}
  end

  # Step 27's world: one run, 1001, over the head of block 101 and the tail of
  # block 102. Unchanged across four gates so a fixture change shows up in all of
  # them.
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

  # The same day plus a SECOND run, so there is an ID to collide with. A one-run
  # world cannot produce a duplicate at all, and the card's second case would then
  # be asserting against a fixture that makes it impossible.
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

    for trip <- [second_101] do
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
    import Ecto.Query
    alias GtfsPlanner.Gtfs.TripRun
    alias GtfsPlanner.Repo

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
    import Ecto.Query
    alias GtfsPlanner.Gtfs.TripRun
    alias GtfsPlanner.Repo

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

  # `to_form(%{}, as: :run)` namespaces the one field as `run[run_id]`, so the
  # submit carries the nesting. Reading a flat `%{"run_id" => id}` here would
  # silently match nothing and the form would appear to do nothing at all.
  defp submit(view, new_id) do
    view
    |> form("#run-rename-form", %{"run" => %{"run_id" => new_id}})
    |> render_submit()
  end

  describe "the form" do
    test "it is in the drawer, with one labelled input and a submit", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      assert has_element?(view, "#run-rename-form")
      assert has_element?(view, "#run-name")
      assert has_element?(view, "#run-rename-form button[type=submit]", "Rename run")

      # A visible label, not a placeholder. The reader is renaming a run other
      # people refer to by its number, and "what is this box for" is a question
      # the markup should not make them answer by guessing.
      #
      # The app's `input/1` WRAPS its input in a `<label>` rather than pointing at
      # it with `for`, so there is no `label[for=run-name]` to find — implicit
      # labelling, which is equally valid and needs no id to match. Asserting the
      # `for` selector would have failed on a correct implementation.
      assert has_element?(view, "#run-rename-form label span", "New run ID")
      assert has_element?(view, "#run-name-help")
    end

    test "the drawer it is in is the run's own", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      assert has_element?(view, "#run-drawer #run-rename-form")
      assert text(view, "#run-drawer h2, #run-drawer [role=heading]") =~ "1001"
    end
  end

  describe "a valid rename" do
    test "it moves the rows, patches the run param and offers Undo", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      trips = trip_ids(w, "1001")
      assert trips != []

      submit(view, "2005")

      # The rows, read back out of the database.
      assert trip_ids(w, "2005") == trips
      assert trip_ids(w, "1001") == []
      assert all_run_ids(w) == ["2005"]

      # The URL, because the drawer is addressed by it: left at 1001, the next
      # patch would re-open a run that no longer exists.
      assert_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&run=2005")

      assert has_element?(view, "#runs-toast", "Renamed to 2005.")
      assert has_element?(view, "#runs-undo")
    end

    test "the drawer still shows a run, and it is the renamed one", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      submit(view, "2005")

      # A rename that closed the drawer would leave the reader with a toast and
      # no run, having asked a question about a run.
      assert has_element?(view, "#run-drawer")
      assert has_element?(view, "#runs-run-2005")
      refute has_element?(view, "#runs-run-1001")
    end

    test "the form is emptied for the next rename", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      submit(view, "2005")

      # Showing the just-used ID would make the next submit a no-op rename onto
      # itself, which reads as the button being broken.
      assert attribute(view, "#run-name", "value") in [nil, ""]
    end
  end

  describe "a refused rename" do
    test "a duplicate ID is refused under the field, and the entry is kept", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      before = all_run_ids(w)

      submit(view, "1002")

      assert text(view, "#run-rename-form") =~ "is already used in this day type"

      # The ENTRY, because the reader's next move is to fix the ID and submit
      # again. A form that clears itself makes them retype it from memory.
      assert attribute(view, "#run-name", "value") == "1002"

      assert all_run_ids(w) == before
    end

    test "the error is under the field, not in a toast", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      submit(view, "1002")

      # The card's rule and the app's form rules agree: a field's problem belongs
      # at the field. A toast would name the failure while the reader is looking
      # at an input.
      refute has_element?(view, "#runs-toast")
    end

    test "the field is marked invalid and the error is wired to it", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      submit(view, "1002")

      # A visible error a screen reader never reaches is not a visible error.
      assert attribute(view, "#run-name", "aria-invalid") == "true"
      describedby = attribute(view, "#run-name", "aria-describedby") || ""
      assert describedby =~ "help"

      errors =
        view |> doc() |> LazyHTML.query("#run-rename-form [id*=error]") |> Enum.map(&text_of/1)

      assert Enum.any?(errors, &(&1 =~ "is already used in this day type"))
    end

    test "a malformed ID is refused the same way", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      submit(view, "way too long to be a run id")

      # The DOMAIN's wording, from `TripRun.validate_run_id_format/1`. Asserting a
      # plausible "at most 8 characters" instead failed against a correct
      # implementation: a page that invented its own phrasing would have passed,
      # which is exactly the drift the domain owning the message rules out.
      assert text(view, "#run-rename-form") =~ "must be one to eight letters"
      assert attribute(view, "#run-name", "value") == "way too long to be a run id"
      assert all_run_ids(w) == ["1001"]
    end

    test "renaming a run to its own ID is allowed and changes nothing", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      before = trip_ids(w, "1001")
      submit(view, "1001")

      # The domain deliberately allows this (`&1 != old_id` in the availability
      # check), so a page that refused it would be refusing something the domain
      # permits. What matters is that the rows are unchanged.
      assert trip_ids(w, "1001") == before
    end
  end

  describe "the form and the drawer" do
    test "a refused entry is not carried to a different run", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      # Refused, so the entry is KEPT - against run 1001.
      submit(view, "1002")
      assert attribute(view, "#run-name", "value") == "1002"

      # Now open a different run. The kept entry was an answer to a question about
      # 1001; showing it against 1002 invites submitting 1002's rename as 1002's
      # ID, which the domain reads as a no-op that appears to succeed.
      view |> element("#runs-run-1002") |> render_click()

      assert attribute(view, "#run-name", "value") in [nil, ""]
    end

    test "a form for a run opened straight from the URL is empty", ctx do
      w = world(ctx)
      # Restored from `?run=` rather than reached by clicking, which is the path a
      # shared link takes.
      view = open(ctx, w, "run=1001")

      assert attribute(view, "#run-name", "value") in [nil, ""]
    end

    test "a refused entry is not carried to a run opened by the URL", ctx do
      w = two_run_world(ctx)
      view = open(ctx, w, "run=1001")

      submit(view, "1002")
      assert attribute(view, "#run-name", "value") == "1002"

      # The OTHER way a drawer opens: the URL changes, which is what a back
      # button, a bookmark or a shared link does. The click path and the URL
      # path are separate code, and only testing the click path leaves one of
      # them unchecked - a mutation that removed the URL branch's reset survived
      # every other test in this file.
      render_patch(view, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&run=1002")

      assert attribute(view, "#run-name", "value") in [nil, ""]
    end
  end

  describe "a run that went away" do
    test "renaming it is refused, and says so", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      # A colleague deleted this run between the drawer opening and the reader
      # submitting. The page is holding a run that is no longer there, and the
      # happy path's "moved the rows" answer is not available.
      import Ecto.Query
      alias GtfsPlanner.Gtfs.TripRun
      alias GtfsPlanner.Repo

      Repo.delete_all(
        from(row in TripRun,
          where:
            row.organization_id == ^w.organization.id and
              row.gtfs_version_id == ^w.version.id and
              row.day_type_key == ^w.day_type_key and row.run_id == "1001"
        )
      )

      submit(view, "2005")

      # Without this clause the event raises `CaseClauseError` on an unmatched
      # `{:error, :unknown_run}` and takes the whole LiveView down - for a race a
      # colleague can cause in the browser at any time.
      assert text(view, "[data-role=toast-text]") =~ "no longer here"
      assert all_run_ids(w) == []
    end
  end

  describe "Undo" do
    test "it restores the old ID", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      trips = trip_ids(w, "1001")

      submit(view, "2005")
      assert trip_ids(w, "2005") == trips

      view |> element("#runs-undo") |> render_click()

      # Re-read from the database again: the toast saying "Undone." is step 28's
      # claim, not this step's.
      assert trip_ids(w, "1001") == trips
      assert trip_ids(w, "2005") == []
      assert all_run_ids(w) == ["1001"]
      assert text(view, "[data-role=toast-text]") == "Undone."
    end

    test "a rename's undo travels the same surface as a move's", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      submit(view, "2005")

      # Step 28's one shared Undo: no rename-specific button, no second undo
      # assign. The count is the trips the rename moved, which is what a reader
      # wants to know about an Undo that is about to move every trip on a run.
      assert attribute(view, "#runs-undo", "data-trips") == to_string(length(trip_ids(w, "2005")))
    end

    test "an undo whose runs moved underneath it is refused", ctx do
      w = world(ctx)
      view = open(ctx, w, "run=1001")

      submit(view, "2005")

      # A colleague renames the same run again in the meantime. The undo's moves
      # say `from: 2005`, and it is now called something else, so the optimistic
      # check refuses and the colleague's name stands.
      {:ok, _} =
        Gtfs.rename_run(w.organization.id, w.version.id, w.day_type_key, "2005", "3007")

      view |> element("#runs-undo") |> render_click()

      assert text(view, "[data-role=toast-text]") == "Can't undo: these runs changed since."
      assert trip_ids(w, "3007") != []
      assert trip_ids(w, "1001") == []
    end
  end

  defp text_of(cell), do: cell |> LazyHTML.text() |> String.trim()
end
