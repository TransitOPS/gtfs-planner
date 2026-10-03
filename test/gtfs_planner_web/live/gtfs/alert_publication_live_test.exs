defmodule GtfsPlannerWeb.Gtfs.AlertPublicationLiveTest do
  @moduledoc """
  Step 19: the review's Publish/Republish control (AC-11, AC-14-17, CL-1, CL-5,
  CL-6, CL-7, CL-8).

  Every case drives the real `AlertEditorLive` review step and the real
  `Alerts.save_review/5` and `Alerts.delete_alert/3` commands against the real
  authorization, the real `alert_publications` schema and the real
  `FeedPublishing.Config`. Only the manifest confirmation - which the delivery
  steps own - is seeded directly, because no application command reaches it.

  The cases are the four the step prepared:

    * a fresh mount is unchecked, an unchecked save never publishes, and a
      later autosave does not become a publication;
    * a checked save accepts exactly the committed revision, and the
      confirmation date appears only once a served manifest confirmed it, never
      for a scheduled acceptance;
    * a refused publication keeps the draft and the checked intent, and an
      ambiguous civil reading offers the exact offsets to choose between;
    * a confirmed delete leaves a pending removal, and a disabled publisher is
      read-only without an enabled publication action.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Changeset
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Publication
  alias GtfsPlanner.FeedPublishing.Config, as: PublishingConfig
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  @zone "America/New_York"
  # The ambiguous reading the fall-back on 2026-11-01 creates, keyed exactly as
  # `FeedPeriods.choice_key/2` keys it.
  @ambiguous_key "America/New_York|2026-11-01T01:30:00"
  @edt_seconds "-14400"

  setup do
    enable_publishing()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    actor = editor_fixture(organization)

    agency_fixture(organization.id, version.id, %{
      agency_id: "nyc",
      agency_name: "NYC Transit",
      agency_timezone: @zone
    })

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "r_1",
        route_short_name: "1",
        route_type: 3
      })

    %{
      organization: organization,
      version: version,
      actor: actor,
      route: route,
      conn: log_in_user(build_conn(), actor, organization: organization),
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the publication control" do
    test "a fresh review mounts unchecked and an unchecked save stays private", context do
      alert = complete_alert(context)
      {:ok, view, _html} = live(context.conn, review_path(alert))

      assert has_element?(view, "#alert-publish-checkbox")
      refute has_element?(view, "#alert-publish-checkbox[checked]")
      assert has_element?(view, "#alert-publication-status", "Not published")
      assert has_element?(view, "#alert-publication-date", "No confirmed publication yet.")
      assert has_element?(view, "#alert-reference-version", "Fall 2026 service")
      assert has_element?(view, "#alert-timezone", @zone)

      # The publish control is its own form, so the draft form that autosaves
      # cannot carry the checkbox at all (FH-6).
      refute has_element?(view, "#alert-form #alert-publish-checkbox")

      # An unchecked Save is the private save: it finishes the review and
      # returns to the list, and nothing public was written.
      view |> element("#save-alert") |> render_click()

      assert_redirect(view, ~p"/alerts")
      assert publication_row(alert) == nil
      assert Repo.get!(Alert, alert.id).public_entity_id == nil
    end

    test "a checked save accepts the committed revision and shows the request, not a date",
         context do
      alert = complete_alert(context)
      {:ok, view, _html} = live(context.conn, review_path(alert))

      view |> form("#review-publication-form") |> render_change(%{"publish" => "true"})
      assert has_element?(view, "#alert-publish-checkbox[checked]")

      view |> element("#save-alert") |> render_click()

      # The notice has begun, so the accepted revision is staging; there is no
      # confirmation date because no manifest has proved one yet (AC-14, AC-15).
      assert has_element?(view, "#alert-publication-status", "Publishing changes")
      assert has_element?(view, "#alert-publication-date", "No confirmed publication yet.")
      assert has_element?(view, "#alert-publication-requested", "Changes requested")

      saved = Repo.get!(Alert, alert.id)
      row = publication_row(alert)

      assert row.desired_revision == saved.revision
      assert row.desired_snapshot["accepted_revision"] == saved.revision
      assert row.confirmed_revision == nil
      assert row.confirmed_snapshot == nil
      assert row.last_published_at == nil
    end

    test "the confirmation date appears only after a manifest confirmed that revision",
         context do
      alert = complete_alert(context)
      {:ok, view, _html} = live(context.conn, review_path(alert))

      view |> form("#review-publication-form") |> render_change(%{"publish" => "true"})
      view |> element("#save-alert") |> render_click()

      row = publication_row(alert)

      # The delivery steps own this receipt; the editor only renders it.
      confirmed_at = ~U[2026-10-02 12:00:00.000000Z]

      {:ok, _row} =
        row
        |> Changeset.change(
          confirmed_revision: row.desired_revision,
          confirmed_snapshot: row.desired_snapshot,
          last_published_at: confirmed_at
        )
        |> Repo.update()

      {:ok, reloaded, _html} = live(context.conn, review_path(alert))

      assert has_element?(reloaded, "#alert-publication-status", "Published")

      assert has_element?(
               reloaded,
               "#alert-publication-date",
               "Reflected in the public feed 2 Oct 2026 at 08:00 America/New_York"
             )

      refute has_element?(reloaded, "#alert-publication-requested")
    end

    test "a scheduled acceptance shows its request time and no publication date", context do
      alert = scheduled_alert(context)
      {:ok, view, _html} = live(context.conn, review_path(alert))

      view |> form("#review-publication-form") |> render_change(%{"publish" => "true"})
      view |> element("#save-alert") |> render_click()

      assert has_element?(view, "#alert-publication-status", "Scheduled")
      assert has_element?(view, "#alert-publication-requested", "Scheduled to start")
      assert has_element?(view, "#alert-publication-date", "No confirmed publication yet.")
    end

    test "an autosave after a checked save never becomes a publication", context do
      alert = complete_alert(context)
      {:ok, view, _html} = live(context.conn, review_path(alert))

      view |> form("#review-publication-form") |> render_change(%{"publish" => "true"})
      view |> element("#save-alert") |> render_click()

      accepted = publication_row(alert)

      # A later draft autosave carries no publish intent: the checkbox lives on
      # the review's own form, which `#alert-form`'s change event does not send.
      view
      |> form("#alert-form")
      |> render_change(%{"alert" => %{"cause" => "weather"}})

      after_autosave = publication_row(alert)

      assert after_autosave.desired_revision == accepted.desired_revision
      assert after_autosave.desired_snapshot == accepted.desired_snapshot
      assert after_autosave.requested_at == accepted.requested_at
    end
  end

  describe "a refused publication" do
    test "keeps the draft and the checked intent, and offers the exact offset", context do
      alert = ambiguous_alert(context)
      {:ok, view, _html} = live(context.conn, review_path(alert))

      view |> form("#review-publication-form") |> render_change(%{"publish" => "true"})
      view |> element("#save-alert") |> render_click()

      # The draft is saved; only the publication was refused, and the checkbox
      # keeps the operator's intent (AC-11, AC-12).
      assert has_element?(view, "#alert-publish-checkbox[checked]")

      assert has_element?(
               view,
               ~s([id="alert-offset-choice-#{@ambiguous_key}"])
             )

      assert publication_row(alert) == nil

      saved = Repo.get!(Alert, alert.id)
      assert saved.timing.start_date == ~D[2026-11-01]
      assert saved.complete == true

      # Choosing the offset resolves exactly that reading rather than guessing
      # one, and the next Save accepts it.
      view
      |> form("#review-publication-form")
      |> render_change(%{
        "publish" => "true",
        "offset_choices" => %{@ambiguous_key => @edt_seconds}
      })

      view |> element("#save-alert") |> render_click()

      refute has_element?(view, "[id^='alert-offset-choice-']")
      assert has_element?(view, "#alert-publication-status", "Scheduled")
      assert publication_row(alert) != nil
    end

    test "explains a reference version that lost an identity", context do
      dropped =
        route_fixture(context.organization.id, context.version.id, %{route_id: "r_dropped"})

      later = route_fixture(context.organization.id, context.version.id, %{route_id: "r_later"})

      alert =
        alert_fixture(context.audit, %{
          complete_attrs(context)
          | "scope" => %{
              "shape" => "routes",
              "route_ids" => [context.route.route_id, dropped.route_id]
            }
        })

      # The source version drops the named route, and a later scope change
      # re-captures the selection, recording the dropped identity as unresolved.
      Repo.delete!(dropped)

      {:ok, _alert} =
        Alerts.save_draft(
          context.audit,
          alert.id,
          alert.revision,
          %{
            "scope" => %{
              "shape" => "routes",
              "route_ids" => [context.route.route_id, dropped.route_id, later.route_id]
            }
          },
          schedule_opts(context.audit)
        )

      {:ok, view, _html} = live(context.conn, review_path(alert))

      assert has_element?(view, "#alert-reference-missing")
      assert has_element?(view, "#alert-reference-version", "Fall 2026 service")
    end
  end

  describe "removal and disabled publishing" do
    test "a confirmed delete leaves a pending removal the list still shows", context do
      alert = complete_alert(context)
      {:ok, view, _html} = live(context.conn, review_path(alert))

      view |> form("#review-publication-form") |> render_change(%{"publish" => "true"})
      view |> element("#save-alert") |> render_click()
      assert publication_row(alert) != nil

      view |> element("#delete-alert") |> render_click()
      view |> element("#delete-alert-dialog-confirm") |> render_click()

      assert_redirect(view, ~p"/alerts")

      # The row is a tombstone with a durable pending withdrawal, and the list
      # still names it so a removal is never hidden (AC-16, FH-14).
      assert Repo.get!(Alert, alert.id).deleted_at != nil
      assert publication_row(alert).withdrawal == :pending

      {:ok, list, _html} = live(context.conn, ~p"/alerts")
      assert has_element?(list, "#alerts-pending-removal")
    end

    test "a disabled publisher keeps read-only status without a publication action",
         context do
      alert = complete_alert(context)
      {:ok, view, _html} = live(context.conn, review_path(alert))

      view |> form("#review-publication-form") |> render_change(%{"publish" => "true"})
      view |> element("#save-alert") |> render_click()
      assert publication_row(alert) != nil

      disable_publishing()

      {:ok, reloaded, _html} = live(context.conn, review_path(alert))

      assert has_element?(reloaded, "#alert-publication-status", "Publishing changes")
      assert has_element?(reloaded, "#alert-publication-disabled")
      refute has_element?(reloaded, "#alert-publish-checkbox")
      refute has_element?(reloaded, "#review-publication-form")

      # The disabled page still saves privately: the review's Save alert writes
      # the draft, and the accepted intent is untouched.
      assert reloaded |> element("#save-alert") |> render_click()
      assert_redirect(reloaded, ~p"/alerts")
      assert publication_row(alert).withdrawal == :none
    end
  end

  # -- Fixtures ------------------------------------------------------------

  # A complete current delay about the version's own route. Its notice has
  # begun, so an accepted revision stages rather than schedules.
  defp complete_alert(context) do
    alert_fixture(context.audit, complete_attrs(context))
  end

  defp complete_attrs(context) do
    %{
      "urgency" => "now",
      "situation" => "delay",
      "cause" => "construction",
      "scope" => %{"shape" => "routes", "route_ids" => [context.route.route_id]},
      "timing" => %{
        "start_date" => "2026-10-05",
        "start_time" => "08:00:00",
        "end_kind" => "confirmed",
        "end_date" => "2026-10-06",
        "end_time" => "20:00:00"
      },
      "message" => %{
        "header" => "Route 1 buses delayed",
        "description" => "Construction on Main St. Use Route 2 instead."
      }
    }
  end

  # A complete alert whose first period starts on the fall-back morning, so its
  # 01:30 reading exists twice and only the operator can choose the offset.
  defp ambiguous_alert(context) do
    attrs =
      Map.put(complete_attrs(context), "timing", %{
        "start_date" => "2026-11-01",
        "start_time" => "01:30:00",
        "end_kind" => "confirmed",
        "end_date" => "2026-11-01",
        "end_time" => "20:00:00"
      })

    alert_fixture(context.audit, attrs)
  end

  # A complete alert whose notice has not begun, so an accepted revision is
  # scheduled rather than publishing.
  defp scheduled_alert(context) do
    attrs =
      Map.put(complete_attrs(context), "timing", %{
        "start_date" => "2035-06-01",
        "start_time" => "08:00:00",
        "end_kind" => "confirmed",
        "end_date" => "2035-06-02",
        "end_time" => "20:00:00",
        "notice_on" => "2035-05-01"
      })

    alert_fixture(context.audit, attrs)
  end

  defp publication_row(alert), do: Repo.get_by(Publication, alert_id: alert.id)

  defp review_path(alert), do: "/alerts/#{alert.id}?mode=form&step=review"

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  # Publishing is configured only for these cases, and the environment is put
  # back so no sibling test reads an enabled setting.
  defp enable_publishing do
    previous = Application.get_env(:gtfs_planner, :feed_publishing_config)

    Application.put_env(:gtfs_planner, :feed_publishing_config, {:enabled, publishing_config()})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:gtfs_planner, :feed_publishing_config)
        value -> Application.put_env(:gtfs_planner, :feed_publishing_config, value)
      end
    end)
  end

  defp disable_publishing do
    Application.put_env(:gtfs_planner, :feed_publishing_config, :disabled)
  end

  defp publishing_config do
    %PublishingConfig{
      bucket: "test-bucket",
      endpoint: URI.parse("https://storage.example.test"),
      region: "test-region",
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      public_base_url: URI.parse("https://feeds.example.test")
    }
  end
end
