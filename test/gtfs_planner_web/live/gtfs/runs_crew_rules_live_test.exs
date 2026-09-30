defmodule GtfsPlannerWeb.Gtfs.RunsCrewRulesLiveTest do
  @moduledoc """
  The Crew rules drawer.

  The claims worth proving here are about what a save does, not about what the
  form looks like. Three of them would pass against a drawer that rendered the
  rules and silently ignored every one of them:

  - a valid save stores the values, so the test re-reads them from the database
    rather than trusting the toast;
  - a refused save stores nothing, so the stored row is re-read after a bad
    submit and compared with what it was before;
  - a refused save keeps the entries, which is only observable if the box that
    was left alone still holds its value after the one that was rejected.

  The client-side blur check is a courtesy, not the validation, so there is a test
  that posts an out-of-range value straight at the server and asserts the domain
  still refuses it. Without that, "validates on blur" and "the server checks"
  would look like one thing.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Repo

  @moduletag :ev_32
  @moduletag timeout: 120_000

  @defaults %{
    report_pull_out_minutes: 15,
    report_relief_minutes: 5,
    sign_off_minutes: 5,
    paid_break_max_minutes: 30,
    max_spread_minutes: 720
  }

  setup do
    %{user: user_fixture()}
  end

  defp world(ctx) do
    w = runs_version_fixture()
    [first | _rest] = w.blocks["101"]

    trip_run_fixture(w.organization.id, w.version.id, %{
      trip: first,
      day_type_key: w.day_type_key,
      run_id: "1001"
    })

    Accounts.create_user_org_membership(%{
      user_id: ctx.user.id,
      organization_id: w.organization.id,
      roles: ["pathways_studio_editor"]
    })

    w
  end

  defp open(ctx, w) do
    conn = log_in_user(ctx.conn, ctx.user, organization: w.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{w.version.id}/runs")
    view
  end

  defp show_crew(view), do: view |> element("#runs-crew-rules-button") |> render_click()

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp text(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp attribute(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  # The STORED crew values, read from the settings row. `get_crew_settings/2`
  # answers with the researched defaults when there is no row, so this is also
  # how "nothing was written" is checked: no row means the defaults are still in
  # force.
  defp stored(w) do
    Gtfs.get_crew_settings(w.organization.id, w.version.id)
  end

  defp stored_row(w) do
    Repo.one(
      from(row in BlockingSetting,
        where:
          row.organization_id == ^w.organization.id and
            row.gtfs_version_id == ^w.version.id
      )
    )
  end

  # The run drawer's paid total in SECONDS, with the drawer opened to read it.
  defp run_paid_secs(view) do
    view |> element("#runs-run-1001") |> render_click()

    view
    |> doc()
    |> LazyHTML.query("[data-role=pay-total]")
    |> LazyHTML.attribute("data-secs")
    |> List.first()
    |> String.to_integer()
  end

  defp change(view, attrs) do
    view |> form("#crew-rules-form", crew: attrs) |> render_change()
  end

  defp submit(view, attrs) do
    view |> form("#crew-rules-form", crew: attrs) |> render_submit()
  end

  describe "the scope-bar button" do
    test "it reads the stored rules with the researched defaults", ctx do
      w = world(ctx)
      view = open(ctx, w)

      assert has_element?(
               view,
               "#runs-crew-rules-button",
               "Crew rules · 15 / 5 min report · 30 min paid break · 12 h spread"
             )
    end

    test "it reads the STORED rules, not the drawer's draft", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # A draft in the open drawer is a draft. The button is the page's own
      # statement of the rules in force, and an unsaved edit changing it would
      # make the page claim a rule the database does not hold.
      change(view, %{paid_break_max_minutes: "60"})

      assert has_element?(
               view,
               "#runs-crew-rules-button",
               "Crew rules · 15 / 5 min report · 30 min paid break · 12 h spread"
             )
    end

    test "it follows a saved report change, not only the break", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # The two reports are the FIRST half of the label. A test that only changed
      # the paid break and the spread would pass against a label that hardcoded
      # the report pair, since the defaults are 15 and 5.
      submit(view, %{report_pull_out_minutes: "22", report_relief_minutes: "9"})

      assert has_element?(
               view,
               "#runs-crew-rules-button",
               "Crew rules · 22 / 9 min report · 30 min paid break · 12 h spread"
             )
    end

    test "it follows a saved change", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      submit(view, %{paid_break_max_minutes: "60"})

      assert has_element?(
               view,
               "#runs-crew-rules-button",
               "Crew rules · 15 / 5 min report · 60 min paid break · 12 h spread"
             )
    end
  end

  describe "the drawer" do
    test "it opens from the button and closes again", ctx do
      w = world(ctx)
      view = open(ctx, w)

      assert attribute(view, "#runs-crew-rules-drawer-overlay", "data-open") == "false"
      show_crew(view)
      assert attribute(view, "#runs-crew-rules-drawer-overlay", "data-open") == "true"

      render_click(view, "close_crew")
      assert attribute(view, "#runs-crew-rules-drawer-overlay", "data-open") == "false"
    end

    test "it opens on the stored values", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      for {key, value} <- @defaults do
        assert attribute(view, "#crew-#{key}", "value") == to_string(value)
      end
    end

    test "each rule carries its label, its range and its help", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # The ranges are the DOMAIN's, so a client-side message and a changeset
      # message cannot disagree about what is acceptable.
      assert attribute(view, "#crew-report_pull_out_minutes", "min") == "0"
      assert attribute(view, "#crew-report_pull_out_minutes", "max") == "30"
      assert attribute(view, "#crew-report_relief_minutes", "max") == "15"
      assert attribute(view, "#crew-sign_off_minutes", "max") == "15"
      assert attribute(view, "#crew-paid_break_max_minutes", "max") == "90"
      assert attribute(view, "#crew-max_spread_minutes", "min") == "240"
      assert attribute(view, "#crew-max_spread_minutes", "max") == "1080"

      # `CoreComponents.input/1` wraps the control in a bare `<label>` with the
      # text in a `.label` span and no `for=`. Asserting `label[for=...]` would
      # be asserting markup this component does not use; what matters is that all
      # five rules are named and each help text is wired to its own input.
      for label <- [
            "Report before a pull-out (min)",
            "Report before a relief (min)",
            "Sign-off (min)",
            "Paid break up to (min)",
            "Longest spread (min)"
          ] do
        assert has_element?(view, "label", label)
      end

      describedby = attribute(view, "#crew-report_pull_out_minutes", "aria-describedby")
      assert describedby =~ "crew-report_pull_out_minutes-help"

      assert has_element?(
               view,
               "#crew-report_pull_out_minutes-help",
               "Charged before every piece"
             )

      # Each help text ends with its own range, which is what makes the range
      # readable without a submit.
      assert has_element?(view, "#crew-report_pull_out_minutes-help", "0-30.")
      assert has_element?(view, "#crew-max_spread_minutes-help", "240-1080.")

      # Every input is a number box with a step of one minute.
      for key <- Map.keys(@defaults) do
        assert attribute(view, "#crew-#{key}", "type") == "number"
        assert attribute(view, "#crew-#{key}", "step") == "1"
      end
    end

    test "it is not URL state", ctx do
      w = world(ctx)
      view = open(ctx, w)

      show_crew(view)
      assert attribute(view, "#runs-crew-rules-drawer-overlay", "data-open") == "true"

      # Not URL state means not RESTORABLE: a fresh mount of the same path opens
      # closed. Every other lens on this page survives a reload, so if this one
      # did too, the URL would carry a draft the reader never saved.
      fresh = open(ctx, w)
      assert attribute(fresh, "#runs-crew-rules-drawer-overlay", "data-open") == "false"
    end
  end

  describe "the paid-time rule in words" do
    test "it reads the defaults", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      assert text(view, "#crew-rule-text") =~
               "Paid time = report (15 min before each pull-out, 5 min before each relief)"

      assert text(view, "#crew-rule-text") =~ "a break of 30 minutes or less"
      assert text(view, "#crew-rule-text") =~ "sign-off (5 min)"
    end

    test "it recomputes on change", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # Raising the paid break rewrites the rule in words while the drawer is
      # open, before anything is saved.
      change(view, %{paid_break_max_minutes: "60"})

      assert text(view, "#crew-rule-text") =~ "a break of 60 minutes or less"
      refute text(view, "#crew-rule-text") =~ "30 minutes or less"
    end

    test "it recomputes from every field, not only the one typed into", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # A form posts every field on every change, so a rule sentence built from
      # the payload alone would be right; one built from a single field would
      # keep naming the old reports.
      change(view, %{
        report_pull_out_minutes: "20",
        report_relief_minutes: "10",
        sign_off_minutes: "8",
        paid_break_max_minutes: "45",
        max_spread_minutes: "600"
      })

      assert text(view, "#crew-rule-text") =~
               "report (20 min before each pull-out, 10 min before each relief)"

      assert text(view, "#crew-rule-text") =~ "a break of 45 minutes or less"
      assert text(view, "#crew-rule-text") =~ "sign-off (8 min)"
    end
  end

  describe "validation" do
    test "an out-of-range value is refused on blur, with the range named", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # 200 minutes of pull-out report.
      change(view, %{report_pull_out_minutes: "200"})

      assert has_element?(
               view,
               "#crew-report_pull_out_minutes-error",
               "Enter a whole number from 0 to 30."
             )

      assert attribute(view, "#crew-report_pull_out_minutes", "aria-invalid") == "true"
    end

    test "a field that was not touched is not marked", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      change(view, %{report_pull_out_minutes: "200"})

      # Re-validating all five on one blur would put an error under a field the
      # reader has not reached yet, and would mark a good value bad because the
      # payload carries it.
      assert attribute(view, "#crew-report_relief_minutes", "aria-invalid") == "false"
      refute has_element?(view, "#crew-report_relief_minutes-error")
    end

    test "a blank value asks for a number", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      change(view, %{sign_off_minutes: ""})

      assert has_element?(view, "#crew-sign_off_minutes-error", "Enter a number of minutes.")
    end

    test "a whole-number rule rejects a fraction", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      change(view, %{paid_break_max_minutes: "30.5"})

      assert has_element?(
               view,
               "#crew-paid_break_max_minutes-error",
               "Enter a whole number from 0 to 90."
             )
    end

    test "a corrected entry clears its own error", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      change(view, %{report_pull_out_minutes: "200"})
      assert has_element?(view, "#crew-report_pull_out_minutes-error")

      change(view, %{report_pull_out_minutes: "20"})
      refute has_element?(view, "#crew-report_pull_out_minutes-error")
      assert attribute(view, "#crew-report_pull_out_minutes", "aria-invalid") == "false"
    end

    test "the spread range is its own, and not the other four", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # 30 is fine for a break and out of range for a spread, so one test that
      # reused the first rule's range would pass here and fail on a real save.
      change(view, %{max_spread_minutes: "30"})
      assert has_element?(view, "#crew-max_spread_minutes-error", "from 240 to 1080")

      change(view, %{paid_break_max_minutes: "30"})
      refute has_element?(view, "#crew-paid_break_max_minutes-error")
    end
  end

  describe "saving" do
    test "a valid save stores the values, closes the drawer and says so", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      submit(view, %{
        report_pull_out_minutes: "20",
        report_relief_minutes: "10",
        sign_off_minutes: "8",
        paid_break_max_minutes: "60",
        max_spread_minutes: "600"
      })

      # Re-read from the database. The toast is the page's claim; the row is the
      # fact, and a save that reported success without writing would pass on the
      # first and fail here.
      assert stored(w) == %{
               report_pull_out_minutes: 20,
               report_relief_minutes: 10,
               sign_off_minutes: 8,
               paid_break_max_minutes: 60,
               max_spread_minutes: 600
             }

      assert text(view, "[data-role=toast-text]") == "Crew rules saved."
      assert attribute(view, "#runs-crew-rules-drawer-overlay", "data-open") == "false"
    end

    test "the saved values reach the page's paid cells", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # The rules feed every derivation, so a save reloads the day. ONE pull-out
      # in this world, so raising its report from 15 to 30 adds exactly 900 paid
      # seconds.
      #
      # SECONDS rather than the formatted string, and an exact amount rather than
      # "the text changed": the rule sentence moving would prove nothing about the
      # chart, and a text comparison would pass on a formatting difference.
      before_paid = run_paid_secs(view)

      show_crew(view)
      submit(view, %{report_pull_out_minutes: "30"})

      assert run_paid_secs(view) == before_paid + 900
    end

    test "a refused save keeps every entry and stores nothing", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      before = stored(w)

      submit(view, %{
        report_pull_out_minutes: "200",
        report_relief_minutes: "9",
        sign_off_minutes: "7",
        paid_break_max_minutes: "45",
        max_spread_minutes: "480"
      })

      # Four good values and one bad one: nothing is written at all, so a later
      # correction does not half-apply a save the reader was told had failed.
      assert has_element?(
               view,
               "#crew-report_pull_out_minutes-error",
               "Enter a whole number from 0 to 30."
             )

      assert stored(w) == before

      # The fixture already writes a settings row for its relief points, so
      # "stores nothing" is about the CREW columns, not about a row not existing.
      row = stored_row(w)
      assert row.report_pull_out_minutes == 15
      assert row.paid_break_max_minutes == 30
      assert row.max_spread_minutes == 720

      for {key, value} <- %{
            report_relief_minutes: "9",
            sign_off_minutes: "7",
            paid_break_max_minutes: "45",
            max_spread_minutes: "480"
          } do
        assert attribute(view, "#crew-#{key}", "value") == value
      end
    end

    test "a failed submit asks the page to focus the first error", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # The claim is an EVENT, not a class: the `FormErrorFocus` hook reads
      # `[aria-invalid="true"]` inside the named form and focuses the first one
      # it finds. Asserting the class would pass whether or not the page was ever
      # told to look.
      #
      # A BLUR deliberately does not push it: the field that was just left is the
      # one the reader was on, and yanking focus to the first invalid control
      # would move them off the box they are still editing. Only a SUBMIT has to
      # take the focus somewhere, because the reader is not on any field.
      change(view, %{report_pull_out_minutes: "200"})
      refute_push_event(view, "focus_form_error", %{form_id: "crew-rules-form"})

      submit(view, %{report_pull_out_minutes: "200"})
      render(view)

      assert_push_event(view, "focus_form_error", %{
        form_id: "crew-rules-form",
        fallback_id: "crew-rules-notice"
      })
    end

    test "a refused save leaves the drawer open with its errors", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      submit(view, %{report_pull_out_minutes: "200"})

      # Closing on a refusal would throw away the entries the reader typed.
      assert attribute(view, "#runs-crew-rules-drawer-overlay", "data-open") == "true"
      refute has_element?(view, "[data-role=toast-text]")
    end

    test "a corrected entry after a refusal saves cleanly", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      submit(view, %{report_pull_out_minutes: "200", report_relief_minutes: "9"})
      refute has_element?(view, "[data-role=toast-text]")

      submit(view, %{report_pull_out_minutes: "20"})

      assert stored(w).report_pull_out_minutes == 20
      assert stored(w).report_relief_minutes == 9
      assert text(view, "[data-role=toast-text]") == "Crew rules saved."
    end

    test "the server refuses an out-of-range value the client was not asked about", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      before = stored(w)

      # The blur check is a courtesy, not the validation. A crafted submit — or a
      # reader who never blurred the field — must still be refused by the domain.
      view
      |> element("#crew-rules-form")
      |> render_submit(%{
        "_target" => ["crew[report_pull_out_minutes]"],
        "crew[report_pull_out_minutes]" => "200",
        "crew[report_relief_minutes]" => "5",
        "crew[sign_off_minutes]" => "5",
        "crew[paid_break_max_minutes]" => "30",
        "crew[max_spread_minutes]" => "720"
      })

      assert stored(w) == before
      assert has_element?(view, "#crew-report_pull_out_minutes-error")
    end
  end

  describe "the piece limit" do
    test "it is text, not an input", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # NO input, rather than an input with no `value` attribute: asserting
      # `value == nil` on the `<p>` passed whatever the element was, because a
      # paragraph never has a `value`. The claim is that the form posts no piece
      # limit at all, so the server test below is the one that carries it.
      assert LazyHTML.query(doc(view), "input[name*=max_piece_minutes]") |> Enum.count() == 0
      assert text(view, "#crew-piece-limit") =~ "set with the relief points in Blocks"
    end

    test "it shows the stored limit", ctx do
      w = world(ctx)

      {:ok, _} =
        Gtfs.update_blocking_settings(w.organization.id, w.version.id, %{max_piece_minutes: 240})

      view = open(ctx, w)
      show_crew(view)

      assert text(view, "#crew-piece-limit") =~ "4 h"
    end

    test "it links to Blocks' Operator changes", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      href = attribute(view, "#crew-piece-limit-link", "href")
      assert href =~ "/gtfs/#{w.version.id}/blocks"
      assert has_element?(view, "#crew-piece-limit-link", "Edit in Blocks")
    end

    test "a save does not write it", ctx do
      w = world(ctx)

      {:ok, _} =
        Gtfs.update_blocking_settings(w.organization.id, w.version.id, %{max_piece_minutes: 240})

      before = stored_row(w)
      view = open(ctx, w)
      show_crew(view)
      submit(view, %{paid_break_max_minutes: "45"})

      # `max_piece_minutes` belongs to the BLOCK rules. A crew save that touched
      # it would edit a setting the drawer shows as read-only.
      assert stored_row(w).max_piece_minutes == before.max_piece_minutes

      # And a POSTED value is ignored, not merely absent from the form: the
      # drawer's field list is the only thing standing between a crafted event
      # and a write to a column this drawer tells the reader it cannot change.
      show_crew(view)

      view
      |> element("#crew-rules-form")
      |> render_submit(%{
        "_target" => ["crew[max_spread_minutes]"],
        "crew[max_piece_minutes]" => "600",
        "crew[report_pull_out_minutes]" => "15",
        "crew[report_relief_minutes]" => "5",
        "crew[sign_off_minutes]" => "5",
        "crew[paid_break_max_minutes]" => "30",
        "crew[max_spread_minutes]" => "720"
      })

      assert Repo.one(
               from(row in BlockingSetting,
                 where:
                   row.organization_id == ^w.organization.id and
                     row.gtfs_version_id == ^w.version.id
               )
             ).max_piece_minutes == 240
    end
  end

  describe "an unpublished version" do
    test "saving keeps the entries and says the version is gone", ctx do
      w = world(ctx)
      view = open(ctx, w)
      show_crew(view)

      # The version the page is showing goes unpublished BETWEEN the drawer
      # opening and the save, which is the race this case is about.
      #
      # `published_at` has to move with the status: a check constraint pairs the
      # two, so setting `publication_status` alone is refused by the table. The
      # status string is read off a staging version rather than invented here.
      {:ok, staging} =
        GtfsPlanner.Versions.create_staging_gtfs_version(w.organization.id, %{
          name: "Unpublished #{System.unique_integer([:positive])}"
        })

      assert Repo.update_all(
               from(v in GtfsPlanner.Versions.GtfsVersion, where: v.id == ^w.version.id),
               set: [publication_status: staging.publication_status, published_at: nil]
             ) == {1, nil}

      submit(view, %{paid_break_max_minutes: "45"})

      assert has_element?(view, "#runs-crew-rules-notice", "no longer published")
      assert attribute(view, "#crew-paid_break_max_minutes", "value") == "45"
      assert attribute(view, "#runs-crew-rules-drawer-overlay", "data-open") == "true"
      refute has_element?(view, "[data-role=toast-text]")
    end
  end
end
