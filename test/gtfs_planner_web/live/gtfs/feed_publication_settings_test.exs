defmodule GtfsPlannerWeb.Gtfs.FeedPublicationSettingsTest do
  @moduledoc """
  Step 20: the organization's published feeds (AC-1, AC-2, AC-16, AC-17, AC-22;
  CL-1, CL-5, CL-6, CL-8).

  Every case drives the real organization route `/settings/published-feeds`
  through the real router, `on_mount` hooks and `GtfsPlannerWeb.Gtfs.FeedPublicationLive`,
  reading the same rows `FeedPublishing.status/1` returns. The channel rows are
  fixtures: a claimed namespace, the channel's durable state and the frozen
  attempt receipt the queue writes, so no publisher and no object store is part of
  this gate.

  The focused gate command is
  `MIX_TEST_PARTITION=_feedpub mix test test/gtfs_planner_web/live/gtfs/feed_publication_settings_test.exs`.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Publication, as: AlertPublication
  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.HTTPBoundary
  alias GtfsPlanner.FeedPublishing.Namespace
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @published_feeds "/settings/published-feeds"

  @config %Config{
    bucket: "gtfs-planner-loopback",
    endpoint: URI.parse("https://storage.loopback.invalid"),
    region: "us-east-1",
    access_key_id: "loopback-access-key",
    secret_access_key: "loopback-secret-access-key",
    public_base_url: URI.parse("https://feeds.loopback.invalid")
  }

  setup do
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

    on_exit(fn -> restore_env(:feed_publishing_config, previous_config) end)

    %{organization: organization, version: version, user: user}
  end

  describe "the addresses of an organization's published feeds" do
    test "each channel serves its own permanent address and its own source", context do
      full = current_channel(context, :full, filename: "network.zip", export_type: "full")
      flex = current_channel(context, :flex, filename: "network-flex.zip", export_type: "flex")

      pathways =
        current_channel(context, :pathways, filename: "pathways.zip", export_type: "pathways")

      {:ok, view, _html} = live(conn(context), @published_feeds)

      assert has_element?(view, "#published-feeds")

      # Every URL is the address of that channel's own file under the claimed
      # prefix; the three never collapse into one.
      assert url_of(view, :full) == "https://feeds.loopback.invalid/rivercity/static/gtfs.zip"

      assert url_of(view, :flex) ==
               "https://feeds.loopback.invalid/rivercity/static/gtfs-flex.zip"

      assert url_of(view, :pathways) ==
               "https://feeds.loopback.invalid/rivercity/static/pathways.zip"

      assert Enum.uniq([url_of(view, :full), url_of(view, :flex), url_of(view, :pathways)])
             |> length() == 3

      # The source is the receipt the queue froze for that channel, not a guess.
      assert row_text(view, "#feed-source-full") =~ "Full feed export"
      assert row_text(view, "#feed-source-full") =~ "network.zip"
      assert row_text(view, "#feed-source-flex") =~ "Flex feed export"
      assert row_text(view, "#feed-source-flex") =~ "network-flex.zip"
      assert row_text(view, "#feed-source-pathways") =~ "Pathways export"
      assert row_text(view, "#feed-source-pathways") =~ "pathways.zip"

      assert row_text(view, "#feed-status-full") =~ "Published"
      assert row_text(view, "#feed-status-full") =~ "2026-10-02 17:02 UTC"

      # Each row is the channel it names, and no channel is invented.
      assert full.channel == :full
      assert flex.channel == :flex
      assert pathways.channel == :pathways
      assert Enum.count(Repo.all(Publication)) == 3
    end

    test "changing the selected version leaves the addresses and sources alone", context do
      current_channel(context, :full, filename: "network.zip", export_type: "full")

      {:ok, view, _html} = live(conn(context), @published_feeds)
      before_url = url_of(view, :full)
      before_source = row_text(view, "#feed-source-full")

      assert back_href(view) == "/gtfs/#{context.version.id}/settings"

      # A second published version becomes the one AssignOrganization selects, so
      # the reader is now looking at this page through a different selection.
      {:ok, newer} =
        Versions.create_gtfs_version(context.organization.id, %{name: "Newer version"})

      {:ok, later, _html} = live(conn(context), @published_feeds)

      assert back_href(later) == "/gtfs/#{newer.id}/settings"
      assert url_of(later, :full) == before_url
      assert row_text(later, "#feed-source-full") == before_source
    end
  end

  describe "what each product sees" do
    test "a Pathways organization has this page and still hides its hidden surfaces", context do
      pathways_organization = organization_fixture(%{product: :pathways})
      pathways_version = gtfs_version_fixture(pathways_organization.id)
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: pathways_organization.id,
        roles: ["pathways_studio_editor"]
      })

      conn = log_in_user(build_conn(), user, organization: pathways_organization)

      {:ok, view, _html} = live(conn, @published_feeds)

      # The status surface belongs to every product.
      assert has_element?(view, "#published-feeds")
      assert has_element?(view, "#feed-status-empty")

      # And it does not drag the surfaces Pathways hides back into view: the
      # version's Settings overview still lists this page and still omits them.
      {:ok, overview, _html} =
        live(conn, "/gtfs/#{pathways_version.id}/settings")

      assert has_element?(overview, "#settings-entry-feed_url")
      refute has_element?(overview, "#settings-entry-agencies")
      refute has_element?(overview, "#settings-entry-fares")
      refute has_element?(overview, "#settings-entry-export_defaults")
    end
  end

  describe "an installation that cannot publish" do
    test "with no history it explains itself and shows no links", context do
      Application.put_env(:gtfs_planner, :feed_publishing_config, :disabled)

      {:ok, view, _html} = live(conn(context), @published_feeds)

      assert has_element?(view, "#published-feeds")
      assert has_element?(view, "#feed-status-disabled", "Publishing is turned off")
      assert has_element?(view, "#feed-status-empty", "Nothing published yet")
      refute has_element?(view, "#feed-status-list")
      refute has_element?(view, "#feed-copy-full")
      refute has_element?(view, "#feed-refresh-age")
    end

    test "with history it keeps the status readable and hides only the links", context do
      current_channel(context, :full, filename: "network.zip", export_type: "full")

      Application.put_env(:gtfs_planner, :feed_publishing_config, :disabled)

      {:ok, view, _html} = live(conn(context), @published_feeds)

      # The local history survives disabling: state, served instant, source and the
      # last refresh the application observed.
      assert has_element?(view, "#feed-status-list")
      assert row_text(view, "#feed-status-full") =~ "Published"
      assert row_text(view, "#feed-status-full") =~ "2026-10-02 17:02 UTC"

      assert has_element?(view, "#feed-refresh-age", "Last checked")

      # The address is the part that needs a configured publisher, so it is hidden
      # with its control rather than shown as a link that cannot work.
      refute has_element?(view, "#feed-copy-full")
      refute has_element?(view, "#feed-url-full")
      assert has_element?(view, "#feed-status-note-full")

      # Nothing was asked of any provider: the page renders with publishing
      # configured off, so there is no address to probe and no request to make.
      assert HTTPBoundary.requests() == []
    end
  end

  describe "the organization route" do
    test "works with no GTFS version at all", context do
      # A fresh organization is created with a published version, so the
      # versionless state this case is about is built by removing it.
      delete_versions!(
        from(v in Versions.GtfsVersion, where: v.organization_id == ^context.organization.id)
      )

      {:ok, view, _html} = live(conn(context), @published_feeds)

      assert has_element?(view, "#published-feeds")
      assert has_element?(view, "#feed-status-empty")
      assert has_element?(view, "#settings-link[href='/settings/published-feeds']")

      # There is no version-scoped Settings page to go back to.
      refute has_element?(view, "#published-feeds-back")
    end

    test "reports an outstanding alert removal although the alert is gone from the list",
         context do
      alert =
        alert_fixture(audit_context(context), %{
          "urgency" => "now",
          "message" => %{"header" => "Bridge closure"}
        })

      pending_removal(context, alert)

      {:ok, view, _html} = live(conn(context), @published_feeds)

      assert has_element?(view, "#feed-pending-removals")
      assert row_text(view, "#feed-pending-removals") =~ "still being removed"
      assert row_text(view, "#feed-pending-removals") =~ "Bridge closure"

      # The withdrawal is observable from the tombstone: the alert row is deleted
      # and no longer appears in this organization's alerts at all.
      assert Repo.get!(Alert, alert.id).deleted_at
      assert {:ok, tabs} = Alerts.list_alerts(audit_context(context), DateTime.utc_now())

      listed =
        Enum.map(tabs.current ++ tabs.upcoming ++ tabs.in_progress ++ tabs.past, & &1.alert.id)

      refute alert.id in listed

      assert [removal] = AlertPublication.pending_removals(context.organization.id)
      assert removal.alert_id == alert.id
    end
  end

  describe "copying an address" do
    test "is a labelled keyboard control that reports its own outcome", context do
      current_channel(context, :full, filename: "network.zip", export_type: "full")

      {:ok, view, _html} = live(conn(context), @published_feeds)

      # A real button, so it is tab-reachable and activates from the keyboard, with
      # the address it copies and a label that names which feed it is.
      assert has_element?(view, "button#feed-copy-full")
      assert has_element?(view, "button#feed-copy-full[aria-label='Copy the Full feed URL']")

      assert has_element?(
               view,
               "button#feed-copy-full[data-feed-url='https://feeds.loopback.invalid/rivercity/static/gtfs.zip']"
             )

      # The browser owns the clipboard, so the hook reports back and the page
      # announces the outcome rather than the button silently doing nothing.
      render_hook(view, "feed_url_copied", %{"channel" => "full"})
      assert has_element?(view, "#feed-copy-notice", "Full feed URL copied.")

      render_hook(view, "feed_url_copy_failed", %{"channel" => "full"})
      assert has_element?(view, "#feed-copy-notice", "was not copied")

      # A forged channel names nothing and changes nothing.
      render_hook(view, "feed_url_copied", %{"channel" => "not-a-channel"})
      assert has_element?(view, "#feed-copy-notice", "was not copied")
    end
  end

  # -- Fixtures and helpers -------------------------------------------------

  defp conn(context),
    do: log_in_user(build_conn(), context.user, organization: context.organization)

  defp audit_context(context) do
    %GtfsPlanner.Gtfs.AuditContext{
      organization_id: context.organization.id,
      gtfs_version_id: context.version && context.version.id,
      station_stop_id: nil,
      actor_id: context.user.id,
      actor_email: context.user.email
    }
  end

  defp namespace(context) do
    case Repo.get_by(Namespace, organization_id: context.organization.id) do
      %Namespace{} = namespace ->
        namespace

      nil ->
        Repo.insert!(%Namespace{
          organization_id: context.organization.id,
          prefix: "rivercity",
          public_claim: Ecto.UUID.generate()
        })
    end
  end

  # One channel that serves confirmed bytes: the durable row a publisher left
  # behind, with the frozen receipt naming the export those bytes came from.
  defp current_channel(context, channel, opts) do
    namespace = namespace(context)

    publication =
      Repo.insert!(%Publication{
        organization_id: context.organization.id,
        namespace_id: namespace.id,
        channel: channel,
        status: :never_published
      })

    attempt = attempt(context, publication, opts)

    publication
    |> Ecto.Changeset.change(%{
      active_attempt_id: attempt.id,
      status: :current,
      desired_revision: 1,
      next_sequence: 2,
      manifest_bytes: attempt.manifest_body,
      manifest_sha256: attempt.manifest_sha256,
      manifest_generation: attempt.generation,
      manifest_sequence: 1,
      manifest_last_modified: ~U[2026-10-02 17:02:00.000000Z],
      last_refresh_at: DateTime.add(DateTime.utc_now(), -180, :second)
    })
    |> Repo.update!()
  end

  defp attempt(context, publication, opts) do
    Repo.insert!(%Attempt{
      publication_id: publication.id,
      organization_id: context.organization.id,
      sequence: 1,
      generation: Ecto.UUID.generate(),
      desired_revision: 1,
      state: "pending",
      actor_id: context.user.id,
      provenance: "export-run:#{Ecto.UUID.generate()}",
      manifest_body: ~s({"schema":1,"channel":"#{publication.channel}"}),
      manifest_sha256: String.duplicate("a", 64),
      object_receipts: %{
        "zip" => %{"sha256" => String.duplicate("b", 64), "bytes" => 1261}
      },
      private_snapshot: %{
        "source" => %{
          "run_id" => Ecto.UUID.generate(),
          "slot" => "main",
          "filename" => Keyword.fetch!(opts, :filename),
          "export_type" => Keyword.fetch!(opts, :export_type)
        }
      }
    })
  end

  # Delete persists intent and a tombstone: the alert row stays with `deleted_at`
  # set and its publication waits for the rider feed to confirm the removal.
  defp pending_removal(context, alert) do
    Repo.update!(
      Ecto.Changeset.change(alert,
        deleted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
    )

    Repo.insert!(%AlertPublication{
      organization_id: context.organization.id,
      alert_id: alert.id,
      desired_revision: 1,
      desired_snapshot: %{"accepted_revision" => 1},
      confirmed_revision: 0,
      last_published_at: ~U[2026-10-01 12:00:00.000000Z],
      withdrawal: :pending
    })
  end

  defp url_of(view, channel) do
    view
    |> element("#feed-url-#{channel}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("href")
    |> List.first()
  end

  defp back_href(view) do
    view
    |> element("#published-feeds-back")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("href")
    |> List.first()
  end

  defp row_text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
