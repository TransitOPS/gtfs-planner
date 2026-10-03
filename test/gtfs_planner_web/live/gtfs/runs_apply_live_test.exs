defmodule GtfsPlannerWeb.Gtfs.RunsApplyLiveTest do
  @moduledoc """
  Applying a previewed suggestion.

  `runs_suggest_live_test.exs` shows a preview is drawn and never saved. These
  cases show the other half: that applying it does exactly what the preview said,
  once, and that every way it can go wrong leaves the reader's saved runs
  untouched and a way forward.

  So the two things asserted throughout are what the page says and what the
  database holds, and they are read from different places: the messages and dialog
  copy come from the rendered page, and the rows come from `trip_runs` through the
  schema. An assertion that only checked the toast would pass on a write that
  never happened.

  The stale case is made by a real writer — a crew-rules save — because the
  domain's staleness is a fingerprint check, and a stubbed fingerprint would be
  testing the stub.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Repo

  @moduletag :ev_35
  @moduletag timeout: 120_000

  setup do
    %{conn: build_conn(), user: user_fixture()}
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

  defp text(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp attribute(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  # The saved assignments, read DIRECTLY from the table rather than from the page.
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

  # The plan's own undo reverses its moves, so its trip count is what the Undo
  # button should name.
  defp undo_trips(plan) do
    plan.moves |> Enum.map(& &1.trip_id) |> Enum.uniq() |> length()
  end

  # A day with runs AND uncovered work: the only state in which an uncovered
  # suggestion both has something to add and leaves existing runs alone.
  defp partly_covered(w) do
    {:ok, day} = Gtfs.load_runs(w.organization.id, w.version.id, w.day_type_key)
    [segment | _rest] = day.derived.uncovered

    moves = Enum.map(segment.trips, fn trip -> %{trip_id: trip.id, from: nil, to: :new} end)
    {:ok, _result} = Gtfs.apply_run_moves(w.audit, w.day_type_key, moves)

    w
  end

  defp preview_uncovered(view) do
    view |> element("#runs-suggest") |> render_click()
    view |> element("#runs-scope-uncovered") |> render_click()
    view |> element("#runs-preview") |> render_click()
    view
  end

  defp preview_rebuild(view) do
    view |> element("#runs-suggest") |> render_click()
    view |> element("#runs-scope-rebuild") |> render_click()
    view |> element("#runs-preview") |> render_click()
    view
  end

  describe "applying uncovered work" do
    test "applies at once with no dialog, leaves the preview and says so", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_uncovered(view)
      assert has_element?(view, "#runs-suggestion")

      view |> element("#runs-apply") |> render_click()

      # No dialog, for this scope: an uncovered preview only ADDS runs, so the
      # diff the reader was shown is the whole change.
      refute has_element?(view, "#runs-rebuild-confirm[data-open=true]")

      refute has_element?(view, "#runs-suggestion")
      assert has_element?(view, "#runs-toast[data-kind=done]")
      assert text(view, "#runs-toast [data-role=toast-text]") =~ "Suggestion applied."
    end

    test "writes the plan's runs and arms an Undo", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      {:ok, plan} =
        Gtfs.suggest_runs(w.organization.id, w.version.id, w.day_type_key, :uncovered_only)

      assert plan.moves != []

      preview_uncovered(view)
      view |> element("#runs-apply") |> render_click()

      after_ids = saved_run_ids(w)
      assert after_ids != before, "Apply must write the plan's runs"

      for move <- plan.moves do
        assert move.to in after_ids,
               "run #{move.to} was in the plan but not saved after Apply"
      end

      assert has_element?(view, "[data-role=undo]")

      assert attribute(view, "[data-role=undo]", "data-trips") ==
               Integer.to_string(undo_trips(plan))
    end

    test "the page shows the applied runs, not the preview", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)

      preview_uncovered(view)
      view |> element("#runs-apply") |> render_click()

      for run_id <- saved_run_ids(w) do
        assert has_element?(view, ~s(#runs-timeline-body tr[data-run="#{run_id}"]))
      end
    end
  end

  describe "applying a rebuild" do
    test "asks first, naming the trip count and the renumbering", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_rebuild(view)
      view |> element("#runs-apply") |> render_click()

      assert has_element?(view, "#runs-rebuild-confirm[data-open=true]")

      {:ok, plan} =
        Gtfs.suggest_runs(w.organization.id, w.version.id, w.day_type_key, :replace_all)

      body = text(view, "#runs-rebuild-confirm")

      # Whitespace-tolerant, because the formatter may wrap between the count and
      # its noun and a literal match would then fail on layout rather than on
      # content. This is the "number assertions need boundaries" rule applied to a
      # sentence instead of an attribute.
      assert Regex.match?(~r/#{length(plan.moves)}\s+trip/, body),
             "the dialog must name the trip count; got: #{body}"

      assert body =~ "renumbered"
      assert body =~ "sign-on order"

      # Asking has not written anything.
      assert saved_run_ids(w) == before
    end

    test "Rebuild runs applies it", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_rebuild(view)
      view |> element("#runs-apply") |> render_click()
      view |> element("#runs-rebuild-confirm-confirm") |> render_click()

      refute has_element?(view, "#runs-rebuild-confirm[data-open=true]")
      refute has_element?(view, "#runs-suggestion")
      assert has_element?(view, "#runs-toast[data-kind=done]")
      assert text(view, "#runs-toast [data-role=toast-text]") =~ "Suggestion applied."
      assert saved_run_ids(w) != before
    end

    test "Keep current runs closes the dialog with nothing written", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_rebuild(view)
      view |> element("#runs-apply") |> render_click()
      view |> element("#runs-rebuild-confirm-cancel") |> render_click()

      refute has_element?(view, "#runs-rebuild-confirm[data-open=true]")

      # The preview STAYS, because the reader asked a question and has not
      # answered it yet.
      assert has_element?(view, "#runs-suggestion")
      assert saved_run_ids(w) == before
    end

    test "a confirm with no dialog open applies nothing", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_rebuild(view)

      # The event is reachable without the dialog — a stale page, or a click that
      # lands after it closed. It must not write.
      render_click(view, "confirm_rebuild", %{})

      assert saved_run_ids(w) == before
    end
  end

  describe "a suggestion that went stale" do
    test "a crew-rules save between preview and apply blocks it and writes nothing", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_uncovered(view)

      # A REAL writer, from a different process, as a colleague would.
      {:ok, _settings} =
        Gtfs.update_crew_settings(w.audit, %{paid_break_max_minutes: 42})

      view |> element("#runs-apply") |> render_click()

      assert has_element?(view, "#runs-stale")
      assert attribute(view, "#runs-stale", "data-state") == "stale"

      assert has_element?(view, "#runs-suggestion"),
             "the reader can still see what they nearly wrote"

      assert has_element?(view, "#runs-suggest-again")

      # Apply is disabled, so it cannot be pressed again into the same refusal.
      assert has_element?(view, "#runs-apply[disabled]")
      assert attribute(view, "#runs-apply", "title") == "This suggestion is out of date"

      assert saved_run_ids(w) == before
    end

    test "a second Apply after a stale is ignored", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_uncovered(view)

      {:ok, _} =
        Gtfs.update_crew_settings(w.audit, %{paid_break_max_minutes: 42})

      view |> element("#runs-apply") |> render_click()
      render_click(view, "apply_suggestion", %{})

      assert has_element?(view, "#runs-stale")
      assert saved_run_ids(w) == before
    end

    test "Suggest again previews from the saved runs and can be applied", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)

      preview_uncovered(view)

      {:ok, _} =
        Gtfs.update_crew_settings(w.audit, %{paid_break_max_minutes: 42})

      view |> element("#runs-apply") |> render_click()
      assert has_element?(view, "#runs-stale")

      view |> element("#runs-suggest-again") |> render_click()

      # A fresh plan: no stale notice, and Apply works again.
      refute has_element?(view, "#runs-stale")
      refute has_element?(view, "#runs-apply[disabled]")
      assert has_element?(view, "#runs-suggestion")

      view |> element("#runs-apply") |> render_click()
      refute has_element?(view, "#runs-suggestion")
      assert text(view, "#runs-toast [data-role=toast-text]") =~ "Suggestion applied."
    end
  end

  describe "a failure that is not staleness" do
    test "a version unpublished between preview and apply keeps the preview and offers a retry",
         ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_uncovered(view)

      # A REAL writer: the version stops being published while the reader is
      # looking at a suggestion built from it. `apply_run_plan/3` reloads the day
      # inside its own transaction and gets `:not_found`, which is a failure and
      # NOT staleness — the reader's saved runs are intact and retrying may work.
      import Ecto.Query

      GtfsPlanner.Versions.GtfsVersion
      |> where([v], v.id == ^w.version.id)
      |> Repo.update_all(set: [publication_status: "staging", published_at: nil])

      view |> element("#runs-apply") |> render_click()

      assert has_element?(view, "#runs-apply-failed")
      assert attribute(view, "#runs-apply-failed", "data-state") == "failed"
      assert text(view, "#runs-apply-failed") =~ "saved runs are unchanged"

      # The preview STAYS: a failure is retryable, so the reader keeps the work
      # they were looking at.
      assert has_element?(view, "#runs-suggestion")
      assert has_element?(view, "#runs-try-again")
      assert has_element?(view, "#runs-apply-failed #runs-suggest-again")

      # And nothing was written.
      assert saved_run_ids(w) == before
    end

    test "Discard after a failure still restores the saved page", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_uncovered(view)

      import Ecto.Query

      GtfsPlanner.Versions.GtfsVersion
      |> where([v], v.id == ^w.version.id)
      |> Repo.update_all(set: [publication_status: "staging", published_at: nil])

      view |> element("#runs-apply") |> render_click()
      assert has_element?(view, "#runs-apply-failed")

      view |> element("#runs-discard") |> render_click()

      refute has_element?(view, "#runs-apply-failed")
      refute has_element?(view, "#runs-suggestion")
      assert saved_run_ids(w) == before
    end
  end

  describe "a pending apply" do
    test "a second click while one is in flight is ignored", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)

      preview_uncovered(view)

      # Sent directly rather than clicked, because a disabled button cannot be
      # clicked — and the guard has to hold for an event that arrives anyway.
      render_click(view, "apply_suggestion", %{})
      render_click(view, "apply_suggestion", %{})

      # ONE apply, not two. The second click finds no suggestion — the first
      # cleared it — and says so, which is the proof it did not apply again.
      refute has_element?(view, "#runs-suggestion")
      assert has_element?(view, "#runs-toast[data-kind=refused]")

      assert text(view, "#runs-toast [data-role=toast-text]") =~
               "There is no suggestion to apply."
    end

    test "Apply with no preview is refused", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      render_click(view, "apply_suggestion", %{})

      assert has_element?(view, "#runs-toast[data-kind=refused]")
      assert saved_run_ids(w) == before
    end
  end

  describe "undo" do
    test "restores the rows that were there before the apply", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_uncovered(view)
      view |> element("#runs-apply") |> render_click()
      assert saved_run_ids(w) != before

      view |> element("[data-role=undo]") |> render_click()

      assert saved_run_ids(w) == before
      assert text(view, "#runs-toast [data-role=toast-text]") =~ "Undone."
    end

    test "rebuilding and undoing also restores", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_rebuild(view)
      view |> element("#runs-apply") |> render_click()
      view |> element("#runs-rebuild-confirm-confirm") |> render_click()
      assert saved_run_ids(w) != before

      view |> element("[data-role=undo]") |> render_click()

      assert saved_run_ids(w) == before
    end
  end

  describe "discarding" do
    test "clears the preview and writes nothing", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_uncovered(view)
      view |> element("#runs-discard") |> render_click()

      refute has_element?(view, "#runs-suggestion")
      assert saved_run_ids(w) == before
    end

    test "is still offered after a stale, and clears the stale notice", ctx do
      w = ctx |> world() |> partly_covered()
      view = open(ctx, w)
      before = saved_run_ids(w)

      preview_uncovered(view)

      {:ok, _} =
        Gtfs.update_crew_settings(w.audit, %{paid_break_max_minutes: 42})

      view |> element("#runs-apply") |> render_click()
      assert has_element?(view, "#runs-stale")

      view |> element("#runs-discard") |> render_click()

      # A stale suggestion must not be a dead end: Discard is the way back to a
      # usable page, and it writes nothing.
      refute has_element?(view, "#runs-stale")
      refute has_element?(view, "#runs-suggestion")
      assert saved_run_ids(w) == before
    end
  end
end
