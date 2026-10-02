defmodule GtfsPlannerWeb.Gtfs.FeedPublishLiveTest do
  @moduledoc """
  Step 18: the static publication review on the Export page (AC-2, AC-3, AC-7,
  AC-22; CL-1, CL-2, CL-6, CL-8).

  Every case drives the real page. `ExportLive`'s own events call
  `FeedPublishing.preview_static/3` and `FeedPublishing.publish_static/4` over the
  real export run, the real artifact pin and the real catalog reader; the reviewed
  report is a seeded completed `mobility_data_artifact` row bound to the run's own
  artifact hash, so no validator process is started and the file is the only
  variable. The events carry no run, slot or tenant, so the forged-event cases can
  only ask for a review the page was already allowed to ask for.

  The focused gate command is
  `MIX_TEST_PARTITION=_feedpub mix test test/gtfs_planner_web/live/gtfs/feed_publish_live_test.exs`.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Alerts.Publication, as: AlertPublication
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.HTTPBoundary
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  @config %Config{
    bucket: "gtfs-planner-loopback",
    endpoint: URI.parse("https://storage.loopback.invalid"),
    region: "us-east-1",
    access_key_id: "loopback-access-key",
    secret_access_key: "loopback-secret-access-key",
    public_base_url: URI.parse("https://feeds.loopback.invalid")
  }

  @full_members [
    {"agency.txt",
     "agency_id,agency_name,agency_url,agency_timezone\n" <>
       "MTA,Metro Transit,https://metro.example,America/New_York\n"},
    {"routes.txt",
     "route_id,agency_id,route_short_name,route_type\n" <> "R1,MTA,One,3\nR2,MTA,Two,1\n"},
    {"trips.txt", "trip_id,route_id,service_id\nT1,R1,S1\nT2,R2,S2\n"},
    {"stops.txt", "stop_id,stop_name\nA1,Alpha\nB1,Bravo\n"},
    {"stop_times.txt",
     "trip_id,arrival_time,departure_time,stop_id\n" <>
       "T1,06:00:00,06:00:00,A1\nT1,06:10:00,06:10:00,B1\nT2,07:00:00,07:00:00,A1\n"},
    {"route_patterns.txt", "route_pattern_id,route_id\nRP1,R1\n"}
  ]

  # A selector the emitted archive cannot answer, which is what a mismatch notice
  # is: the alert names route R99 and the file carries R1 and R2 only.
  @echo_scope %{
    "shape" => "routes",
    "agencies" => [],
    "routes" => ["R99"],
    "stops" => [],
    "route_stops" => [],
    "trips" => []
  }

  setup do
    root = Path.join(System.tmp_dir!(), "feed-publish-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    previous_config = Application.get_env(:gtfs_planner, :feed_publishing_config)
    Application.put_env(:gtfs_planner, :feed_publishing_config, {:enabled, @config})
    HTTPBoundary.reset()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, previous_root)
      restore_env(:feed_publishing_config, previous_config)
    end)

    %{organization: organization, version: version, user: user}
  end

  describe "an installation without publishing" do
    test "keeps Download and offers no Publish, and a forged event opens nothing", context do
      Application.put_env(:gtfs_planner, :feed_publishing_config, :disabled)
      _run = ready_run(context)

      {:ok, view, _html} = live(conn(context), export_path(context))

      assert has_element?(view, "#export-download-link")
      refute has_element?(view, "#feed-publish-open")
      refute has_element?(view, "#feed-publish")

      # A forged event cannot open a review the page never offered, and it does
      # not take the page down.
      render_click(view, "preview_publication", %{})

      refute has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#export-page")
    end
  end

  describe "an operations export" do
    test "keeps Download and never exposes the action, and a forged event opens nothing",
         context do
      _run = ready_run(context, export_type: :operations)

      {:ok, view, _html} = live(conn(context), export_path(context, type: "operations"))

      assert has_element?(view, "#export-download-link")
      refute has_element?(view, "#feed-publish-open")
      refute has_element?(view, "#feed-publish")

      render_click(view, "preview_publication", %{})

      refute has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#export-page")
      assert Repo.aggregate(Publication, :count) == 0
    end
  end

  describe "the review" do
    test "shows the file, the report and the inventory behind one Publish action", context do
      run = ready_run(context)
      report = seed_report(context, run)

      {:ok, view, _html} = live(conn(context), export_path(context))

      refute has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#feed-publish-status", "Not published yet")

      view |> element("#feed-publish-open") |> render_click()

      assert has_element?(view, "#feed-publish-review")

      # The public URL, the profile and the reviewed hash come from the server's
      # own preview, never from anything the browser sent.
      assert has_element?(view, "#feed-publish-url", "https://feeds.loopback.invalid/")
      assert has_element?(view, "#feed-publish-profile", "GTFS feed")
      assert has_element?(view, "#feed-publish-hash", String.slice(run.artifact_sha256, 0, 16))
      assert has_element?(view, "#feed-publish-report", "0 errors")
      assert has_element?(view, "#feed-publish-report", String.slice(report.id, 0, 8))

      # The inventory is the disclosed archive, before any consent.
      assert has_element?(view, "#feed-publish-inventory", "routes.txt")
      assert has_element?(view, "#feed-publish-inventory", "route_patterns.txt")
      assert has_element?(view, "#feed-publish-inventory-title", "6 entries")

      # A clean report asks for no error confirmation, and there is one primary action.
      refute has_element?(view, "#feed-publish-confirm-errors")
      assert has_element?(view, "#feed-publish-confirm", "Publish feed")
    end

    test "publishes the reviewed file and reports the durable queued state", context do
      run = ready_run(context)
      _report = seed_report(context, run)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#feed-publish-open") |> render_click()
      assert has_element?(view, "#feed-publish-review")

      # The action the operator presses is the submit control of this form.
      assert has_element?(view, "#feed-publish-consent #feed-publish-confirm")
      view |> element("#feed-publish-consent") |> render_submit()

      # The review is answered and the queue is now the durable record.
      refute has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#feed-publish-status", "Publishing")

      assert %Publication{status: :pending, desired_revision: 1, active_attempt_id: attempt_id} =
               Repo.get_by!(Publication, organization_id: context.organization.id, channel: :full)

      # What is queued is the hash the review showed, not a re-read of the source.
      attempt = Repo.get!(GtfsPlanner.FeedPublishing.Attempt, attempt_id)
      assert attempt.object_receipts["zip"]["sha256"] == run.artifact_sha256

      # Coming back to the page shows the same state, from the row rather than
      # from anything this page remembered.
      {:ok, reopened, _html} = live(conn(context), export_path(context))

      assert has_element?(reopened, "#feed-publish-status", "Publishing")
      refute has_element?(reopened, "#feed-publish-review")
    end

    test "leads with a mismatch notice and still publishes", context do
      run = ready_run(context)
      _report = seed_report(context, run)
      _alert = seed_accepted_alert(context)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#feed-publish-open") |> render_click()

      # The notice names what the file cannot answer, and the proceed action is
      # still there: a mismatch is information, never a block.
      assert has_element?(view, "#feed-publish-notices")
      assert has_element?(view, "#feed-publish-mismatch", "Ice on Route 99")
      assert has_element?(view, "#feed-publish-mismatch", "R99")
      assert has_element?(view, "#feed-publish-confirm")

      view |> element("#feed-publish-consent") |> render_submit()

      refute has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#feed-publish-status", "Publishing")
    end

    test "requires the error count to be confirmed and keeps the review on a refusal", context do
      run = ready_run(context)
      _report = seed_report(context, run, errors_count: 3)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#feed-publish-open") |> render_click()

      assert has_element?(view, "#feed-publish-report", "3 errors")
      assert has_element?(view, "#feed-publish-confirm-errors")
      assert has_element?(view, "#feed-publish-consent", "I have reviewed the 3 errors")

      # Publishing without the count confirmation is refused, and the review the
      # operator was reading is still there with its own numbers.
      view |> element("#feed-publish-consent") |> render_submit()

      assert has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#feed-publish-refusal", "Confirm the check report first")
      assert has_element?(view, "#feed-publish-refusal", "3 errors")

      assert Repo.aggregate(Publication, :count) == 0

      # The tick is the operator's own answer, so it survives the refusal. A
      # refused write after that changes nothing either, and the tick is still
      # there for the next attempt.
      view
      |> element("#feed-publish-consent")
      |> render_change(%{"publication" => %{"confirm_errors" => "true"}})

      assert has_element?(view, "#feed-publish-confirm-errors[checked]")

      publish_the_first_review_elsewhere(context, run)

      view
      |> element("#feed-publish-consent")
      |> render_submit(%{"publication" => %{"confirm_errors" => "true"}})

      assert has_element?(view, "#feed-publish-review")

      assert has_element?(
               view,
               "#feed-publish-refusal",
               "The public feed changed while you were reviewing"
             )

      assert has_element?(view, "#feed-publish-confirm-errors[checked]")
    end

    test "closing the review returns the page to the opener", context do
      run = ready_run(context)
      _report = seed_report(context, run)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#feed-publish-open") |> render_click()
      assert has_element?(view, "#feed-publish-review")
      refute has_element?(view, "#feed-publish-open")

      view |> element("#feed-publish-close") |> render_click()

      refute has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#feed-publish-open")

      # Reopening reviews the same file again, from the server's own answer.
      view |> element("#feed-publish-open") |> render_click()
      assert has_element?(view, "#feed-publish-review")
    end
  end

  describe "the review across navigation" do
    test "waits for a running check and opens when that check finishes", context do
      run = ready_run(context)
      report = seed_report(context, run, status: "running", completed_at: nil)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#feed-publish-open") |> render_click()

      refute has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#feed-publish-refusal", "Checking this file")

      complete_report(report)
      broadcast_validation(:validation_completed, report.id)

      assert has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#feed-publish-report")
    end

    test "ignores a check that finishes after the reader left that review", context do
      run = ready_run(context)
      report = seed_report(context, run, status: "running", completed_at: nil)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#feed-publish-open") |> render_click()
      refute has_element?(view, "#feed-publish-review")

      # The reader changes the export type, which is an ordinary navigation on
      # this page and a different run and channel. The page is still mounted and
      # still subscribed, so this is the effect of leaving, not of unmounting.
      view
      |> element("#gtfs-export-form")
      |> render_change(%{"export" => %{"type" => "pathways"}})

      assert has_element?(view, "#feed-publish")
      refute has_element?(view, "#feed-publish-review")

      complete_report(report)
      broadcast_validation(:validation_completed, report.id)

      refute has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#feed-publish")
    end
  end

  # -- Fixtures and helpers -------------------------------------------------

  defp conn(context),
    do: log_in_user(build_conn(), context.user, organization: context.organization)

  defp export_path(context, opts \\ []) do
    case Keyword.get(opts, :type) do
      nil -> "/gtfs/#{context.version.id}/export"
      type -> "/gtfs/#{context.version.id}/export?type=#{type}"
    end
  end

  defp ready_run(context, opts \\ []) do
    organization = context.organization
    version = context.version
    export_type = Keyword.get(opts, :export_type, :full)

    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    {:ok, main} =
      ArtifactStorage.publish(
        organization.id,
        version.id,
        run.id,
        "network.zip",
        zip_bytes(@full_members)
      )

    {:ok, ready} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{main: main, flex: nil})

    ready
  end

  defp seed_report(context, run, opts \\ []) do
    Repo.insert!(%ValidationRun{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      run_type: "mobility_data_artifact",
      status: Keyword.get(opts, :status, "completed"),
      errors_count: Keyword.get(opts, :errors_count, 0),
      warnings_count: Keyword.get(opts, :warnings_count, 0),
      infos_count: Keyword.get(opts, :infos_count, 0),
      artifact_sha256: run.artifact_sha256,
      artifact_slot: :main,
      artifact_export_run_id: run.id,
      started_at: DateTime.utc_now(),
      completed_at: Keyword.get(opts, :completed_at, DateTime.utc_now())
    })
  end

  defp complete_report(report) do
    report
    |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp broadcast_validation(event, run_id) do
    Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, Validations.topic(run_id), {event, run_id})
  end

  # An accepted alert whose selectors the emitted archive cannot answer: one
  # advisory mismatch notice, and no alert row is touched by publishing.
  defp seed_accepted_alert(context) do
    alert =
      Repo.insert!(%Alert{
        organization_id: context.organization.id,
        source_gtfs_version_id: context.version.id,
        revision: 1,
        public_entity_id: Ecto.UUID.generate(),
        scope: %ScopeAnswer{},
        timing: %TimingAnswer{},
        message: %MessageAnswer{}
      })

    Repo.insert!(%AlertPublication{
      organization_id: context.organization.id,
      alert_id: alert.id,
      desired_revision: 1,
      desired_snapshot: %{
        "public_entity_id" => alert.public_entity_id,
        "accepted_revision" => 1,
        "header" => "Ice on Route 99",
        "effect" => "detour",
        "scope" => @echo_scope
      },
      withdrawal: :none
    })

    alert
  end

  # Someone else publishes the same channel between the review and the confirm,
  # which is what makes the destination revision the operator is holding stale.
  # The report behind this review has errors, so that publish carries its own
  # count confirmation.
  defp publish_the_first_review_elsewhere(context, run) do
    scope = %{organization_id: context.organization.id, actor_id: context.user.id}

    assert {:ok, preview} = FeedPublishing.preview_static(scope, run.id, :main)

    assert {:ok, _publication_id} =
             FeedPublishing.publish_static(scope, preview.token, preview.destination_revision,
               confirm_errors?: true
             )
  end

  defp zip_bytes(members) do
    dir = Path.join(System.tmp_dir!(), "feed-publish-zip-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "archive.zip")

    entries = Enum.map(members, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, _written} = :zip.create(String.to_charlist(path), entries)
    bytes = File.read!(path)
    File.rm_rf!(dir)
    bytes
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
