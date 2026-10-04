defmodule GtfsPlannerWeb.Gtfs.TodsGeneratorLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.TodsGeneration
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Repo
  alias GtfsPlanner.TodsGeneratorFixtures
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Gtfs.TodsGeneratorLive

  # The version-scoped route the account menu opens.
  @generator_path "/tods-generator"

  # One fixed service window every case shares: Wednesday 7 October 2026 through
  # Tuesday 20 October, weekdays only. Its first active date is 7 October, so the
  # owner's `Input.first_active_week/1` defaults the range to Monday 5 – Sunday 11
  # October and the representative week to 5 October. Those literal dates are what
  # the page must show; fixing the window is the only reason they are not relative.
  @service_start ~D[2026-10-07]
  @service_end ~D[2026-10-20]
  @first_week_start "2026-10-05"
  @first_week_end "2026-10-11"

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    calendar_fixture(organization.id, version.id, %{
      service_id: "WKDY",
      start_date: @service_start,
      end_date: @service_end
    })

    %{organization: organization, user: user, version: version}
  end

  defp open_generator(conn, context) do
    conn = log_in_user(conn, context.user, organization: context.organization)
    live(conn, "/gtfs/#{context.version.id}#{@generator_path}")
  end

  # The world the preview and save cases read: `tods_world_fixture/1`'s published
  # version with its own small schedule, one garage and one unblocked trip, so the
  # generator has a new block, derived runs and single-slot roster lines to preview
  # and write. It is the same fixture the generator's own domain cases compose, so
  # the page is proven against the real composition rather than a page-shaped
  # stand-in.
  defp generator_world do
    TodsGeneratorFixtures.tods_world_fixture(
      extra_trips: [{"gen-a", "WK", "RIV", "RIV", "04:00:00", "04:30:00"}]
    )
  end

  defp editor_in(world) do
    user = user_fixture()

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: world.organization.id,
        roles: ["pathways_studio_editor"]
      })

    {user, membership}
  end

  defp open_world_generator(conn, context) do
    conn = log_in_user(conn, context.editor, organization: context.world.organization)
    live(conn, "/gtfs/#{context.world.version.id}#{@generator_path}")
  end

  # Submits the form the way a person does — the values the page rendered, with no
  # injected assigns — and waits for the preview read that follows.
  defp preview_generation(view) do
    view |> form("#tods-generator-form", input: %{}) |> render_submit()
    render_async(view, 15_000)
  end

  # Waits for the supervised save task and then for the page that applied its
  # answer, with no sleeps: the task process is monitored, its DOWN message is
  # asserted, and the page is read until it has cleared the task it waited on.
  defp await_save(view) do
    for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
    end

    await_save_settled(view, 200)
  end

  defp await_save_settled(view, 0), do: render(view)

  defp await_save_settled(view, tries) do
    if :sys.get_state(view.pid).socket.assigns.save_task do
      await_save_settled(view, tries - 1)
    else
      render(view)
    end
  end

  # The exact text the result panel shows for one committed count.
  defp figure(receipt, key, noun) do
    count = Map.fetch!(receipt.summary, key)
    "#{count} #{Wording.noun(count, noun)}"
  end

  defp document(html), do: LazyHTML.from_fragment(html)

  defp text_in(html, selector) do
    html |> document() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp selected_garage(html) do
    html |> document() |> LazyHTML.query("#tods-garage-select option[selected]")
  end

  describe "entry" do
    test "an editor opens the generator and reads its purpose before any control", context do
      {:ok, view, _html} = open_generator(context.conn, context)

      assert has_element?(view, "#tods-generator-page")
      assert has_element?(view, "#tods-generator-purpose")
      assert has_element?(view, "#tods-generator-form")

      purpose = text_in(render(view), "#tods-generator-purpose")

      # AC-2's consequences, each its own sentence: internal test data, made-up
      # assignments, the version's screens, organization-wide fictional operators,
      # preserved existing work, later exports, and no publication.
      assert purpose =~ "internal testing and demonstrations"
      assert purpose =~ "made-up operating assignments"
      assert purpose =~ "Blocks, Runs and Rosters"
      assert purpose =~ "saved for the organization"
      assert purpose =~ "Existing assignments are kept"
      assert purpose =~ "TODS exports"
      assert purpose =~ "does not publish a feed"

      # The recurring-date consequence is stated in full: a weekday slot reaches
      # matching dates outside the selected range, and differing exception dates
      # do not become staffed.
      assert purpose =~ "affects every matching date"
      assert purpose =~ "after the range you select"
      assert purpose =~ "holidays"

      scope = text_in(render(view), "#tods-generator-scope")
      assert scope =~ context.version.name
      assert scope =~ context.organization.name

      assert has_element?(view, "#tods-preview-button")
      assert String.trim(text_in(render(view), "#tods-preview-button")) == "Preview generation"
    end

    test "the range defaults to the feed's first active calendar week", context do
      {:ok, view, _html} = open_generator(context.conn, context)

      assert has_element?(view, ~s(#tods-start-date[value="#{@first_week_start}"]))
      assert has_element?(view, ~s(#tods-end-date[value="#{@first_week_end}"]))
      assert has_element?(view, ~s(#tods-representative-week[value="#{@first_week_start}"]))
    end

    test "the rules in force are the version's stored crew rules, read-only", context do
      audit = editor_audit_fixture(context.organization, context.version)

      {:ok, _settings} =
        Runs.update_crew_settings(audit, %{
          report_pull_out_minutes: 20,
          report_relief_minutes: 8,
          sign_off_minutes: 12,
          paid_break_max_minutes: 35,
          max_spread_minutes: 660
        })

      {:ok, view, _html} = open_generator(context.conn, context)

      rules = text_in(render(view), "#tods-generator-rules")

      assert rules =~ "20 min before each pull-out"
      assert rules =~ "8 min before each relief"
      assert rules =~ "35 minutes or less"
      assert rules =~ "sign-off (12 min)"

      assert text_in(render(view), "#tods-generator-rules-spread") =~ "11 h"

      assert has_element?(
               view,
               ~s(#tods-generator-rules-link[href="/gtfs/#{context.version.id}/runs"])
             )
    end
  end

  describe "garage prerequisite" do
    test "one garage is preselected, because one garage is not a choice", context do
      garage = garage_fixture(context.organization.id, %{"name" => "Depot A"})

      {:ok, view, _html} = open_generator(context.conn, context)

      assert LazyHTML.attribute(selected_garage(render(view)), "value") == [garage.id]
      refute has_element?(view, "#tods-preview-button[disabled][data-unavailable]")

      options = document(render(view)) |> LazyHTML.query("#tods-garage-select option")
      assert LazyHTML.attribute(options, "value") == ["", garage.id]
    end

    test "several garages require an explicit choice", context do
      garage_fixture(context.organization.id, %{"name" => "Depot A"})
      garage_fixture(context.organization.id, %{"name" => "Depot B"})

      {:ok, view, _html} = open_generator(context.conn, context)

      assert Enum.empty?(selected_garage(render(view)))
      assert has_element?(view, ~s(#tods-garage-select option[value=""]), "Choose a garage")
    end

    test "no garage names the prerequisite, links to Garages and blocks the preview", context do
      {:ok, view, _html} = open_generator(context.conn, context)

      assert has_element?(view, "#tods-generator-missing-garages")
      assert has_element?(view, "#tods-preview-blocked")

      assert has_element?(
               view,
               ~s(#tods-generator-missing-garages a[href="/gtfs/#{context.version.id}/settings/garages"])
             )

      # The control is disabled and reads as unavailable through the design
      # system's own mark, and the event is refused anyway: a disabled button is
      # the browser's state, never the server's authorization.
      assert has_element?(view, "#tods-preview-button[disabled][data-unavailable]")

      html =
        view
        |> form("#tods-generator-form", input: %{"start_date" => @first_week_start})
        |> render_submit()

      assert html =~ "Add a garage first"
      refute html =~ "Request ready"
    end

    test "a garage this organization does not own is not accepted as a choice", context do
      own = garage_fixture(context.organization.id, %{"name" => "Depot A"})
      other_organization = organization_fixture()
      foreign = garage_fixture(other_organization.id, %{"name" => "Foreign Depot"})

      {:ok, view, _html} = open_generator(context.conn, context)

      # The browser cannot send this value, so the event is sent directly: the
      # same shape as a garage deleted in another tab while the form was open.
      html = render_submit(view, "preview_generation", %{"input" => %{"garage_id" => foreign.id}})

      assert Enum.empty?(selected_garage(html))
      refute html =~ foreign.id
      refute html =~ "Foreign Depot"
      assert text_in(html, "#tods-generator-form-error") =~ "Fallback garage"

      # The organization's own garage is still the only garage the control offers.
      options = html |> document() |> LazyHTML.query("#tods-garage-select option")
      assert LazyHTML.attribute(options, "value") == ["", own.id]
    end
  end

  describe "request validation" do
    test "a submit without a chosen garage reveals the field error and keeps the dates",
         context do
      garage_fixture(context.organization.id, %{"name" => "Depot A"})
      garage_fixture(context.organization.id, %{"name" => "Depot B"})

      {:ok, view, _html} = open_generator(context.conn, context)

      html =
        view
        |> form("#tods-generator-form",
          input: %{"start_date" => "2026-10-12", "end_date" => "2026-10-18"}
        )
        |> render_submit()

      assert has_element?(view, "#tods-generator-form-error")
      assert text_in(html, "#tods-generator-form-error") =~ "Fallback garage"
      assert Enum.empty?(selected_garage(html))

      # The submitted drafts stay on the form, and the primary control is not
      # disabled for an invalid value: submitting is how the errors appear.
      assert has_element?(view, ~s(#tods-start-date[value="2026-10-12"]))
      assert has_element?(view, ~s(#tods-end-date[value="2026-10-18"]))
      refute has_element?(view, "#tods-preview-button[disabled]")
      refute render(view) =~ "Request ready"
    end

    test "an end date before the start date is revealed on the end date", context do
      garage = garage_fixture(context.organization.id, %{"name" => "Depot A"})

      {:ok, view, _html} = open_generator(context.conn, context)

      html =
        view
        |> form("#tods-generator-form",
          input: %{
            "start_date" => "2026-10-18",
            "end_date" => "2026-10-12",
            "garage_id" => garage.id
          }
        )
        |> render_submit()

      assert text_in(html, "#tods-generator-form-error") =~ "Last date"
      assert has_element?(view, ~s(#tods-end-date[value="2026-10-12"]))
      refute render(view) =~ "Request ready"
    end

    test "a representative week that is not a Monday is revealed", context do
      garage = garage_fixture(context.organization.id, %{"name" => "Depot A"})

      {:ok, view, _html} = open_generator(context.conn, context)

      html =
        view
        |> form("#tods-generator-form",
          input: %{
            "start_date" => @first_week_start,
            "end_date" => @first_week_end,
            "representative_week" => "2026-10-06",
            "garage_id" => garage.id
          }
        )
        |> render_submit()

      assert text_in(html, "#tods-generator-form-error") =~ "Representative week"
      refute html =~ "Request ready"
    end

    test "a valid request starts the real preview read", context do
      garage = garage_fixture(context.organization.id, %{"name" => "Depot A"})
      garage_fixture(context.organization.id, %{"name" => "Depot B"})

      {:ok, view, _html} = open_generator(context.conn, context)

      html =
        view
        |> form("#tods-generator-form",
          input: %{
            "start_date" => "2026-10-12",
            "end_date" => "2026-10-25",
            "representative_week" => "2026-10-19",
            "garage_id" => garage.id,
            "terminal_relief?" => "true"
          }
        )
        |> render_submit()

      # The submit is the real read, not an acknowledgement: the page says it is
      # reading the schedule and then renders the candidate the generator answers.
      assert has_element?(view, "#tods-preview-running")
      refute html =~ "Request checked."
      assert has_element?(view, "#tods-terminal-relief[checked]")

      html = render_async(view, 15_000)

      assert has_element?(view, "#tods-generation-preview")
      assert text_in(html, "#tods-preview-range") =~ "Oct 12, 2026 to Oct 25, 2026"
      assert text_in(html, "#tods-preview-range") =~ "from Oct 19, 2026"

      # This version holds no trip, so there is nothing to staff in those dates
      # and the page says so instead of offering a save.
      assert has_element?(view, "#tods-preview-no-work")
      assert has_element?(view, "#tods-save-button[disabled]")
    end
  end

  describe "preview of a stored schedule" do
    setup do
      world = generator_world()
      {editor, membership} = editor_in(world)
      %{world: world, editor: editor, membership: membership}
    end

    test "an ordinary mount previews the schedule and writes nothing", context do
      {:ok, view, _html} = open_world_generator(context.conn, context)

      html = preview_generation(view)

      assert has_element?(view, "#tods-generation-preview")

      # One new block, because the fixture's own 101 and 102 are preserved and the
      # one unblocked trip becomes block 103.
      assert text_in(html, "#tods-preview-count-blocks") == "1 new block"
      assert text_in(html, "#tods-preview-count-open") =~ "run-day"
      assert text_in(html, "#tods-preview-kept") =~ "2 existing blocks"

      # The preview is a read: no domain row and no receipt exists after it.
      assert Repo.aggregate(TodsGeneration, :count) == 0
      assert Repo.aggregate(RosterLine, :count) == 0
      assert Repo.aggregate(TripRun, :count) == 0
      assert Repo.aggregate(Operator, :count) == 0
    end

    test "the preview names the recurring effect, the dates and its assumptions", context do
      {:ok, view, _html} = open_world_generator(context.conn, context)

      html = preview_generation(view)

      staffed = text_in(html, "#tods-preview-staffed")
      assert staffed =~ "repeats by weekday"
      assert staffed =~ "of them outside the dates you selected"

      assert has_element?(view, "#tods-preview-assumption-one_operator_per_run_day")

      assert text_in(html, "#tods-preview-assumption-one_operator_per_run_day") =~
               "One fictional operator is created per run and weekday"

      assert has_element?(view, "#tods-preview-assumption-recurring_beyond_range")
      assert text_in(html, "#tods-preview-open") =~ "selected date"
      assert text_in(html, "#tods-preview-other-service") =~ "different service"
      assert text_in(html, "#tods-preview-exclusions") =~ "Left out of this generation"

      assert text_in(html, "#tods-preview-exclusion-exceeds_relief_limit") =~
               "1 trip beyond the relief limit."
    end

    test "an altered actor, organization, plan or request id is not authority", context do
      other_organization = organization_fixture()
      forged_request_id = Ecto.UUID.generate()
      {:ok, view, _html} = open_world_generator(context.conn, context)

      params =
        context.world
        |> TodsGeneratorFixtures.tods_inputs()
        |> Map.merge(%{
          "organization_id" => other_organization.id,
          "actor_id" => Ecto.UUID.generate(),
          "gtfs_version_id" => Ecto.UUID.generate(),
          "plan" => %{"blocks" => [%{"block_id" => "999"}]},
          "request_id" => forged_request_id
        })

      render_submit(view, "preview_generation", %{"input" => params})
      html = render_async(view, 15_000)

      # The candidate is the mount's own scope: the submitted dates and garage, and
      # the fixture's own candidate rather than the forged plan.
      monday = TodsGeneratorFixtures.first_active_week(context.world)
      assert text_in(html, "#tods-preview-range") =~ Wording.date(monday)
      assert text_in(html, "#tods-preview-count-blocks") == "1 new block"

      # The forged request id names nothing: the page mints its own token, so a
      # browser cannot choose which request a save is keyed by.
      view |> element("#tods-save-button") |> render_click()
      request_path = assert_patch(view)
      refute request_path =~ forged_request_id
      await_save(view)

      assert Repo.one(TodsGeneration).request_id != forged_request_id
    end

    test "a preview answer for replaced input cannot overwrite the page", context do
      {:ok, view, _html} = open_world_generator(context.conn, context)

      # Start the real read, then replace the request before its answer lands.
      view |> form("#tods-generator-form", input: %{}) |> render_submit()

      view
      |> form("#tods-generator-form", input: %{"end_date" => "2025-12-01"})
      |> render_submit()

      assert has_element?(view, "#tods-generator-form-error")
      refute has_element?(view, "#tods-generation-preview")

      # The replaced read's answer is discarded when it arrives.
      render_async(view, 15_000)

      refute has_element?(view, "#tods-generation-preview")
      assert text_in(render(view), "#tods-generator-form-error") =~ "Last date"
    end

    test "a superseded or failed preview answer cannot replace the page", context do
      {:ok, view, _html} = open_world_generator(context.conn, context)
      preview_generation(view)

      socket = :sys.get_state(view.pid).socket
      superseded = socket.assigns.preview_revision - 1

      # A controlled completion for an input the page has already replaced, and a
      # controlled exit for the read on screen.
      assert {:noreply, unchanged} =
               TodsGeneratorLive.handle_async(
                 {:preview, superseded},
                 {:ok, {:error, :forbidden}},
                 socket
               )

      assert unchanged.assigns.preview == socket.assigns.preview
      assert unchanged.assigns.preview_error == socket.assigns.preview_error

      assert {:noreply, exited} =
               TodsGeneratorLive.handle_async(
                 {:preview, socket.assigns.preview_revision},
                 {:exit, :boom},
                 socket
               )

      assert exited.assigns.preview_error.title =~ "could not be built"
    end

    test "a read that passes its deadline answers a message instead of crashing", context do
      {:ok, view, _html} = open_world_generator(context.conn, context)
      preview_generation(view)

      socket = :sys.get_state(view.pid).socket

      # The read boundary's own refusals, not the plan's: the answer to the request
      # on screen is `Export.with_read_snapshot/1`'s `{:error, :snapshot_timeout}`
      # past its deadline, or its `{:error, :rollback}` when the read's snapshot
      # rolled back. Neither is a refusal the page names, so mapping them to a
      # message is what keeps `handle_async/3` from raising away the reader's request.
      assert {:noreply, timed_out} =
               TodsGeneratorLive.handle_async(
                 {:preview, socket.assigns.preview_revision},
                 {:ok, {:error, :snapshot_timeout}},
                 socket
               )

      assert timed_out.assigns.preview_error.title =~ "could not be read in time"

      assert {:noreply, rolled_back} =
               TodsGeneratorLive.handle_async(
                 {:preview, socket.assigns.preview_revision},
                 {:ok, {:error, :rollback}},
                 socket
               )

      assert rolled_back.assigns.preview_error.title =~ "rolled back"

      # A refusal this page has no clause for is a message too, never a crash.
      assert {:noreply, unknown} =
               TodsGeneratorLive.handle_async(
                 {:preview, socket.assigns.preview_revision},
                 {:ok, {:error, :refused_later}},
                 socket
               )

      assert unknown.assigns.preview_error.title =~ "could not be built"
    end
  end

  describe "saving a preview" do
    setup do
      world = generator_world()
      {editor, membership} = editor_in(world)
      %{world: world, editor: editor, membership: membership}
    end

    test "one save writes the generation and shows the receipt it stored", context do
      {:ok, view, _html} = open_world_generator(context.conn, context)
      preview_generation(view)

      view |> element("#tods-save-button") |> render_click()

      # The save is a committing transaction with no cancellation: the page reports
      # it as busy and disables the control it came from.
      assert has_element?(view, "#tods-save-running")
      assert has_element?(view, "#tods-save-button[disabled]")

      request_path = assert_patch(view)
      version_id = context.world.version.id

      html = await_save(view)

      assert has_element?(view, "#tods-generation-result")
      refute has_element?(view, "#tods-save-button")
      refute has_element?(view, "#tods-generation-preview")

      receipt = Repo.one(TodsGeneration)

      # The result's identifier is the receipt's own request.
      assert text_in(html, "#tods-result-identifier") =~
               String.slice(receipt.request_id, 0, 8)

      # The figures the page shows are the committed counts.
      assert text_in(html, "#tods-result-count-blocks") == "1 block"
      assert text_in(html, "#tods-result-count-lines") == figure(receipt, "lines", "roster line")

      assert text_in(html, "#tods-result-count-operators") ==
               figure(receipt, "operators", "fictional operator")

      assert receipt.created_ids["block_ids"] == ["103"]
      assert Repo.aggregate(RosterLine, :count) == receipt.summary["lines"]
      assert Repo.aggregate(Operator, :count) == receipt.summary["operators"]
      assert Repo.aggregate(TripRun, :count) > 0

      # The receipt's request is the token the URL carries.
      assert request_path =~ receipt.request_id

      assert has_element?(view, ~s(#tods-result-blocks[href="/gtfs/#{version_id}/blocks"]))
      assert has_element?(view, ~s(#tods-result-runs[href="/gtfs/#{version_id}/runs"]))
      assert has_element?(view, ~s(#tods-result-rosters[href="/gtfs/#{version_id}/rosters"]))
      assert has_element?(view, ~s(#tods-result-operators[href="/gtfs/#{version_id}/rosters"]))

      assert has_element?(
               view,
               ~s(#tods-result-export[href="/gtfs/#{version_id}/export?type=operations"])
             )

      assert text_in(html, "#tods-result-operators-note") =~ "Operators ·"
    end

    test "a repeated save event cannot start a second generation", context do
      {:ok, view, _html} = open_world_generator(context.conn, context)
      preview_generation(view)

      view |> element("#tods-save-button") |> render_click()
      assert_patch(view)

      # The event arrives again while the first save is committing.
      render_click(view, "save_generation", %{})

      await_save(view)

      assert Repo.aggregate(TodsGeneration, :count) == 1
      assert has_element?(view, "#tods-generation-result")
    end

    test "a stale refusal keeps the request and a new preview can save", context do
      {:ok, view, _html} = open_world_generator(context.conn, context)
      preview_generation(view)

      # The schedule changes under the reviewed preview.
      assert {:ok, _garage} =
               Operations.update_garage(
                 context.world.organization.id,
                 %{id: context.world.audit.actor_id},
                 context.world.garage.id,
                 %{"lat" => "41.0000"}
               )

      view |> element("#tods-save-button") |> render_click()
      html = await_save(view)

      assert text_in(html, "#tods-save-status") =~ "The schedule changed since this preview"
      refute has_element?(view, "#tods-generation-preview")
      assert Repo.aggregate(TodsGeneration, :count) == 0

      # The request stays on the form, and a fresh preview of it is saveable.
      assert LazyHTML.attribute(selected_garage(render(view)), "value") == [
               context.world.garage.id
             ]

      html = preview_generation(view)
      assert has_element?(view, "#tods-generation-preview")
      assert text_in(html, "#tods-preview-count-blocks") == "1 new block"

      view |> element("#tods-save-button") |> render_click()
      await_save(view)

      assert Repo.aggregate(TodsGeneration, :count) == 1
      assert has_element?(view, "#tods-generation-result")
    end

    test "a reload of the request URL recovers the one receipt", context do
      conn = log_in_user(context.conn, context.editor, organization: context.world.organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{context.world.version.id}#{@generator_path}")

      preview_generation(view)
      view |> element("#tods-save-button") |> render_click()
      request_path = assert_patch(view)
      await_save(view)

      receipt = Repo.one(TodsGeneration)
      lines = receipt.summary["lines"]

      # The lost reply is recovered from the durable receipt, not written again.
      {:ok, reloaded, html} = live(conn, request_path)

      assert has_element?(reloaded, "#tods-generation-result")
      refute has_element?(reloaded, "#tods-save-button")
      assert text_in(html, "#tods-result-count-lines") == "#{lines} roster lines"
      assert Repo.aggregate(TodsGeneration, :count) == 1
      assert Repo.aggregate(RosterLine, :count) == lines
    end

    test "an unknown completion is explained and Retry save reuses the request", context do
      request_id = Ecto.UUID.generate()
      conn = log_in_user(context.conn, context.editor, organization: context.world.organization)

      {:ok, view, html} =
        live(conn, "/gtfs/#{context.world.version.id}#{@generator_path}?request=#{request_id}")

      # Nothing is reported as cancelled: the request has no receipt yet.
      assert text_in(html, "#tods-save-status") =~ "no completed generation"
      assert text_in(html, "#tods-save-status") =~ "reported as cancelled"
      refute has_element?(view, "#tods-save-button")

      # The fresh preview is what makes the retained request saveable again.
      preview_generation(view)
      assert text_in(render(view), "#tods-save-button") |> String.trim() == "Retry save"

      view |> element("#tods-save-button") |> render_click()
      request_path = assert_patch(view)
      await_save(view)

      assert Repo.aggregate(TodsGeneration, :count) == 1
      assert Repo.one(TodsGeneration).request_id == request_id
      assert request_path =~ request_id
      assert has_element?(view, "#tods-generation-result")
    end

    test "a revoked editor cannot save, and nothing is written", context do
      {:ok, view, _html} = open_world_generator(context.conn, context)
      preview_generation(view)

      deactivate_membership_fixture(context.membership)

      view |> element("#tods-save-button") |> render_click()
      html = await_save(view)

      assert text_in(html, "#tods-save-status") =~ "no longer have permission to save"
      assert Repo.aggregate(TodsGeneration, :count) == 0
      assert Repo.aggregate(RosterLine, :count) == 0
      assert Repo.aggregate(TripRun, :count) == 0
    end
  end

  describe "access" do
    test "a member without the editor role is refused on the direct route", context do
      member = user_fixture()
      conn = log_in_user(context.conn, member, organization: context.organization)

      assert {:error, {:redirect, %{to: "/admin/organizations", flash: %{"error" => flash}}}} =
               live(conn, "/gtfs/#{context.version.id}#{@generator_path}")

      assert flash =~ "not authorized"
    end

    test "another organization's version is not a trusted assign", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id, %{name: "Other Org Version"})

      conn = log_in_user(context.conn, context.user, organization: context.organization)

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, "/gtfs/#{other_version.id}#{@generator_path}")
    end
  end
end
