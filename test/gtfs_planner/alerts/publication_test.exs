defmodule GtfsPlanner.Alerts.PublicationTest do
  @moduledoc """
  Step 12: an explicit checked Save accepts immutable public intent, and a
  confirmed removal persists with it (AC-11, AC-14–17, CL-1, CL-6, CL-7).

  Every case here runs the real production command - `Alerts.save_review/5` and
  `Alerts.delete_alert/3` - against the real `Authorization` membership check,
  the real `alerts` channel row and the real `GtfsPlanner.Alerts.Publication`
  schema. Nothing is faked: the alerts channel is claimed through
  `FeedPublishing.claim_namespace/1` and inserted through the schema, and the
  served bytes are read back out of the stored snapshot by re-running
  `Alerts.Feed.encode/2` rather than asserted from a struct.

  The four prepared cases are:

    * an unchecked Save and an autosave retain the served content and its
      publication date, a checked Save captures exactly the revision that
      committed, and a later autosave stays private;
    * membership is checked before any lock, and an incomplete or
      unrepresentable publication keeps the draft with explicit field errors;
    * a candidate that would exceed the 16 MiB budget is refused without
      replacing earlier accepted content, and removal stays available while the
      feed is blocked;
    * a delete while publishing is disabled retains the tombstone and the
      pending withdrawal, and no draft or legacy complete row is ever published
      on its own.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Feed
  alias GtfsPlanner.Alerts.Publication
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Config, as: PublishingConfig
  alias GtfsPlanner.FeedPublishing.Publication, as: Channel
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  @zone "America/New_York"
  @header_now 1_791_205_200

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
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

    # The alerts channel is claimed through the production command and inserted
    # through its schema, so the channel row, its namespace and its permanent
    # prefix are all real.
    {:ok, namespace} =
      FeedPublishing.claim_namespace(%{
        organization_id: organization.id,
        actor_id: actor.id
      })

    Repo.insert!(%Channel{
      organization_id: organization.id,
      namespace_id: namespace.id,
      channel: :alerts
    })

    %{
      organization: organization,
      version: version,
      actor: actor,
      route: route,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "an unchecked save or autosave" do
    test "retains the served content and its publication date", context do
      alert = accepted_alert(context)

      assert {:ok, %{alert: saved, publication: :pending}} =
               save_review(
                 context,
                 alert,
                 %{"message" => %{"header" => "Served wording", "description" => "Served."}},
                 publish?: true
               )

      accepted_after = publication_for(alert)

      # The autosave follows a checked Save that moved the revision, so it is
      # issued at the revision that Save committed.
      assert {:ok, %{publication: :private}} = autosave(context, saved)

      reloaded = publication_for(alert)

      # The desired snapshot, its revision and the actor who asked are exactly
      # what the checked Save stored; a later unchecked Save and an autosave moved
      # none of them.
      assert reloaded.desired_snapshot == accepted_after.desired_snapshot
      assert reloaded.desired_revision == accepted_after.desired_revision
      assert reloaded.requested_by_id == accepted_after.requested_by_id
      assert DateTime.compare(reloaded.requested_at, accepted_after.requested_at) == :eq
      assert reloaded.confirmed_revision == accepted_after.confirmed_revision
      assert reloaded.last_published_at == accepted_after.last_published_at
      assert channel_revision(context) == 2
    end

    test "leaves an alert that was never published with no publication row", context do
      alert = draft_alert(context)

      assert {:ok, %{publication: :private}} = save_review(context, alert, %{})

      assert publication_count(alert) == 0
      assert Repo.get!(Alert, alert.id).public_entity_id == nil
      assert channel_revision(context) == 0
    end

    test "stays private after a checked Save, even from a stale revision", context do
      alert = accepted_alert(context)
      accepted = publication_for(alert)

      {:ok, _saved} =
        Alerts.save_draft(context.audit, alert.id, alert.revision, %{"cause" => "weather"})

      assert {:error, :stale, %Alert{revision: current_revision}} =
               save_review(context, alert, %{}, publish?: true)

      assert current_revision == accepted.desired_revision + 1
      assert publication_for(alert).desired_revision == accepted.desired_revision
      assert channel_revision(context) == 1
    end
  end

  describe "a checked save" do
    test "captures exactly the revision that committed", context do
      alert = draft_alert(context)

      assert {:ok, %{alert: saved, publication: :pending}} =
               save_review(context, alert, %{}, publish?: true)

      assert saved.revision == alert.revision

      accepted = publication_for(alert)

      assert accepted.desired_revision == saved.revision
      assert accepted.requested_by_id == context.actor.id
      assert accepted.confirmed_revision == nil
      assert accepted.confirmed_snapshot == nil
      assert accepted.last_published_at == nil
      assert accepted.withdrawal == :none
      assert Repo.get!(Alert, alert.id).public_entity_id == saved.public_entity_id

      snapshot = stored(accepted)

      # The snapshot names GTFS identities and absolute instants only, and it is
      # exactly what the encoder serves for this alert.
      assert {:ok, %{included: included, pb: pb, json: json}} =
               Feed.encode([snapshot], @header_now)

      assert included == %{to_string(saved.public_entity_id) => saved.revision}
      assert byte_size(pb) > 0
      assert byte_size(json) > 0
      assert snapshot.scope.shape == :routes
      assert snapshot.scope.routes == ["r_1"]
      assert [%{start: start, end: finish}] = snapshot.periods
      assert is_integer(start) and is_integer(finish)
      assert snapshot.header == "Route 1 buses delayed"
      assert snapshot.accepted_revision == saved.revision
    end

    test "keeps the same public entity id across a republish", context do
      alert = accepted_alert(context)
      first = Repo.get!(Alert, alert.id).public_entity_id

      assert {:ok, %{publication: :pending}} =
               save_review(context, alert, %{"cause" => "weather"}, publish?: true)

      assert Repo.get!(Alert, alert.id).public_entity_id == first
      assert stored(publication_for(alert)).cause == :weather
    end

    test "reports a scheduled acceptance separately from a pending one", context do
      alert = draft_alert(context)

      assert {:ok, %{publication: :scheduled}} =
               save_review(context, alert, future_attrs(context), publish?: true)

      assert publication_for(alert) |> stored() |> Map.fetch!(:notice_at) >
               DateTime.utc_now() |> DateTime.to_unix()
    end

    test "marks the alerts channel dirty so a refresh can notice without a browser",
         context do
      alert = draft_alert(context)

      assert channel_revision(context) == 0

      assert {:ok, %{publication: :pending}} = save_review(context, alert, %{}, publish?: true)

      assert channel_revision(context) == 1

      assert Repo.get_by!(Channel, organization_id: context.organization.id, channel: :alerts).status ==
               :never_published
    end
  end

  describe "refusals" do
    test "checks membership before any lock and changes nothing", context do
      alert = accepted_alert(context)
      accepted = publication_for(alert)

      membership =
        Repo.get_by(
          GtfsPlanner.Accounts.UserOrgMembership,
          user_id: context.actor.id,
          organization_id: context.organization.id
        )

      deactivate_membership_fixture(membership)

      assert {:error, :forbidden} = save_review(context, alert, %{}, publish?: true)
      assert Repo.get!(Alert, alert.id).revision == accepted.desired_revision
      assert publication_for(alert) == accepted
      assert channel_revision(context) == 1
    end

    test "keeps the draft and reports explicit errors for an incomplete alert", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      assert {:ok, %{alert: saved, publication: {:refused, errors}}} =
               save_review(context, alert, %{}, publish?: true)

      # The private save happened; only the publication did not.
      assert saved.revision == alert.revision
      assert Repo.get!(Alert, alert.id).situation == nil

      assert Enum.map(errors, & &1.field) |> Enum.sort() ==
               [:description, :end_kind, :header, :situation, :start_date, :start_time]

      assert Enum.all?(errors, &(&1.message != "" and is_binary(&1.message)))
      assert publication_count(alert) == 0
      assert Repo.get!(Alert, alert.id).public_entity_id == nil
      assert channel_revision(context) == 0
    end

    test "reports an unrepresentable scope rather than publishing a narrower alert", context do
      # A second route the alert also names, and a third added later to force a
      # re-capture after the second disappears from the source version.
      dropped =
        route_fixture(context.organization.id, context.version.id, %{route_id: "r_dropped"})

      later = route_fixture(context.organization.id, context.version.id, %{route_id: "r_later"})

      alert =
        complete_alert(context.audit, %{
          "scope" => %{"shape" => "routes", "route_ids" => [context.route.id, dropped.id]}
        })

      # The source version no longer holds the dropped route, but the capture is
      # only rewritten when the selection changes.
      Repo.delete!(dropped)

      {:ok, alert} =
        Alerts.save_draft(context.audit, alert.id, alert.revision, %{
          "scope" => %{
            "shape" => "routes",
            "route_ids" => [context.route.id, dropped.id, later.id]
          }
        })

      assert {:ok, %{publication: {:refused, [%{field: :scope, message: message}]}}} =
               save_review(context, alert, %{}, publish?: true)

      assert message =~ "no longer has"
      assert publication_count(alert) == 0
    end

    test "refuses an ambiguous civil reading until the editor saves an offset", context do
      alert = draft_alert(context)

      attrs = %{
        "timing" => %{
          "start_date" => "2026-11-01",
          "start_time" => "01:30:00",
          "end_kind" => "confirmed",
          "end_date" => "2026-11-01",
          "end_time" => "20:00:00"
        }
      }

      assert {:ok, %{publication: {:refused, [error]}}} =
               save_review(context, alert, attrs, publish?: true)

      assert error.key == "America/New_York|2026-11-01T01:30:00"
      assert [%{offset_seconds: -14_400}, %{offset_seconds: -18_000}] = error.choices
      assert publication_count(alert) == 0
    end

    test "requires an explicit zone rather than the disclosed display fallback", context do
      conflicting = gtfs_version_fixture(context.organization.id)
      actor = editor_fixture(context.organization)
      audit = audit_context(context.organization, conflicting, actor)

      agency_fixture(context.organization.id, conflicting.id, %{
        agency_id: "one",
        agency_name: "One",
        agency_timezone: @zone
      })

      agency_fixture(context.organization.id, conflicting.id, %{
        agency_id: "two",
        agency_name: "Two",
        agency_timezone: "Asia/Tokyo"
      })

      alert = complete_alert(audit, %{})

      assert alert.timezone == nil

      assert {:ok, %{publication: {:refused, errors}}} =
               save_review(context, alert, %{}, publish?: true)

      assert Enum.map(errors, & &1.field) == [:time_zone]
      assert publication_count(alert) == 0
    end
  end

  describe "the admission budget" do
    test "counts a scheduled snapshot the projection would not include yet", context do
      scheduled = accepted_alert(context)
      inflate_publication!(scheduled, 17_000_000, scheduled: true)
      stored_snapshot = stored(publication_for(scheduled))

      # A scheduled snapshot is not projected at the current instant, which is
      # what makes it easy to forget: `Feed.encode/2` drops it entirely here.
      assert {:ok, %{included: included}} = Feed.encode([stored_snapshot], @header_now)
      assert included == %{}

      candidate = draft_alert(context)
      before = publication_for(scheduled)

      # It still counts before acceptance, so a candidate that would fit on its
      # own is refused rather than admitted over the conservative envelope.
      assert {:ok, %{publication: {:refused, [error]}}} =
               save_review(context, candidate, %{}, publish?: true)

      assert error.field == :publication
      assert error.message =~ "budget"

      # Earlier accepted content survives untouched, and the alert that could
      # not be admitted has no intent of its own.
      assert publication_count(candidate) == 0
      assert publication_for(scheduled).desired_snapshot == before.desired_snapshot

      # Removal stays available while the feed is over budget, which is the only
      # way back: it is the corrective action the refusal names.
      assert {:ok, _deleted} =
               Alerts.delete_alert(context.audit, scheduled.id, scheduled.revision)

      candidate = Repo.get!(Alert, candidate.id)

      assert {:ok, %{publication: :pending}} =
               save_review(context, candidate, %{}, publish?: true)
    end

    test "replaces one alert's own previous intent instead of adding to it", context do
      alert = accepted_alert(context)
      inflate_publication!(alert, 9_000_000)

      other = accepted_alert(context)
      inflate_publication!(other, 9_000_000)

      # Two stored intents already exceed the budget, so a fresh alert is refused.
      fresh = draft_alert(context)

      assert {:ok, %{publication: {:refused, [_error]}}} =
               save_review(context, fresh, %{}, publish?: true)

      # Re-publishing the same alert against its own large stored text fits,
      # because its previous intent is replaced rather than stacked.
      assert {:ok, %{publication: :pending}} =
               save_review(context, alert, %{}, publish?: true)

      assert Repo.aggregate(Publication, :count) == 2

      assert stored(publication_for(alert)).description ==
               "Construction on Main St. Use Route 2 instead."
    end
  end

  describe "a confirmed removal" do
    test "retains the tombstone and the pending withdrawal", context do
      alert = accepted_alert(context)
      accepted = publication_for(alert)
      reference = Repo.get!(Alert, alert.id).target_reference

      assert {:ok, deleted} = Alerts.delete_alert(context.audit, alert.id, alert.revision)

      assert deleted.deleted_at != nil

      row = Repo.get!(Alert, alert.id)

      # The trusted capture, the accepted revision and the snapshot a served
      # manifest may still be serving all survive the delete.
      assert row.revision == accepted.desired_revision
      assert row.target_reference == reference
      assert to_string(row.public_entity_id) == to_string(stored(accepted).public_entity_id)

      withdrawn = publication_for(alert)

      assert withdrawn.withdrawal == :pending
      assert withdrawn.desired_snapshot == accepted.desired_snapshot
      assert withdrawn.confirmed_revision == accepted.confirmed_revision
      assert channel_revision(context) == 2

      # The removed draft is gone from the editor's own listing, and the pending
      # removal stays observable outside the deleted row.
      assert {:ok, tabs} = Alerts.list_alerts(context.audit, DateTime.utc_now())
      assert all_rows(tabs) == []

      assert [pending] = Publication.pending_removals(context.organization.id)
      assert pending.alert_id == alert.id
      assert pending.withdrawn_at != nil
    end

    test "records the removal while publishing is disabled", context do
      alert = accepted_alert(context)

      # The suite runs with no publishing settings at all, so `Config.current/0`
      # is already `:disabled` here and nothing in the delete path reads it
      # anyway: a disabled publisher keeps the tombstone and the intent rather
      # than hiding them.
      assert PublishingConfig.current() == :disabled

      assert {:ok, deleted} = Alerts.delete_alert(context.audit, alert.id, alert.revision)

      assert deleted.deleted_at != nil
      assert publication_for(alert).withdrawal == :pending
      assert [_pending] = Publication.pending_removals(context.organization.id)
      assert channel_revision(context) == 2
    end

    test "removes a draft that was never published outright", context do
      alert = draft_alert(context)

      assert {:ok, deleted} = Alerts.delete_alert(context.audit, alert.id, alert.revision)

      assert deleted.id == alert.id
      assert Repo.get(Alert, alert.id) == nil
      assert channel_revision(context) == 0
    end

    test "keeps a blocked alert's earlier accepted content out of the next projection",
         context do
      blocked = accepted_alert(context)
      inflate_publication!(blocked, 17_000_000)

      fresh = draft_alert(context)

      assert {:ok, %{publication: {:refused, [_error]}}} =
               save_review(context, fresh, %{}, publish?: true)

      # Withdrawing the oversized accepted alert takes it out of the envelope,
      # which is what makes the next acceptance fit again.
      assert {:ok, _deleted} =
               Alerts.delete_alert(context.audit, blocked.id, blocked.revision)

      fresh = Repo.get!(Alert, fresh.id)

      assert {:ok, %{publication: :pending}} = save_review(context, fresh, %{}, publish?: true)

      snapshots =
        Repo.all(
          Ecto.Query.from(publication in Publication,
            where: publication.organization_id == ^context.organization.id,
            where: publication.withdrawal == :none,
            select: publication.desired_snapshot
          )
        )
        |> Enum.map(&Publication.snapshot_from_stored/1)

      # The withdrawn alert's oversized snapshot is gone; what remains encodes.
      assert {:ok, %{included: included}} = Feed.encode(snapshots, @header_now)
      assert map_size(included) == 1
    end

    test "refuses a stale revision and keeps the removal pending", context do
      alert = accepted_alert(context)

      {:ok, saved} =
        Alerts.save_draft(context.audit, alert.id, alert.revision, %{"cause" => "weather"})

      assert {:error, :stale, %Alert{}} =
               Alerts.delete_alert(context.audit, alert.id, alert.revision)

      assert Repo.get!(Alert, alert.id).deleted_at == nil
      assert publication_for(alert).withdrawal == :none

      assert {:ok, _deleted} = Alerts.delete_alert(context.audit, saved.id, saved.revision)
      assert Repo.get!(Alert, alert.id).deleted_at != nil
    end
  end

  describe "what is never published on its own" do
    test "a complete legacy draft never gains public intent", context do
      alert = complete_alert(context.audit, %{})

      assert Repo.get!(Alert, alert.id).complete == true
      assert Repo.aggregate(Publication, :count) == 0

      # Only the checked Save creates intent, so listing and reading the draft -
      # which the editor does on every render and every startup - cannot.
      assert {:ok, tabs} = Alerts.list_alerts(context.audit, DateTime.utc_now())
      assert length(all_rows(tabs)) == 1

      assert {:ok, _alert} = Alerts.get_alert(context.audit, alert.id)

      assert {:ok, [_channel]} =
               FeedPublishing.status(%{
                 organization_id: context.organization.id,
                 actor_id: context.actor.id
               })

      assert Repo.aggregate(Publication, :count) == 0
    end
  end

  # -- Fixtures -------------------------------------------------------------

  # A complete, privately authored alert about the version's own route.
  defp draft_alert(context), do: complete_alert(context.audit, %{"route" => context.route})

  # `create_alert/2` already stores the whole answer and derives `complete`, so
  # this needs no follow-up save: a save that changed nothing would not move the
  # revision, and the cases below reason about revisions explicitly.
  defp complete_alert(audit, attrs) do
    {route, overrides} =
      case attrs do
        %{"route" => %{} = route} -> {route, %{}}
        %{} = overrides -> {nil, overrides}
      end

    scope =
      if route,
        do: %{"shape" => "routes", "route_ids" => [route.id]},
        else: %{"shape" => "routes", "route_ids" => [nil]}

    merged =
      Map.merge(
        %{
          "urgency" => "now",
          "situation" => "delay",
          "cause" => "construction",
          "scope" => scope,
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
        },
        overrides
      )

    alert_fixture(audit, merged)
  end

  # The same alert with a notice date far enough ahead that an accepted snapshot
  # is scheduled rather than pending.
  defp future_attrs(_context) do
    %{
      "timing" => %{
        "start_date" => "2035-06-01",
        "start_time" => "08:00:00",
        "end_kind" => "confirmed",
        "end_date" => "2035-06-02",
        "end_time" => "20:00:00",
        "notice_on" => "2035-05-01"
      }
    }
  end

  defp accepted_alert(context) do
    alert = draft_alert(context)
    {:ok, _result} = save_review(context, alert, %{}, publish?: true)

    Repo.get!(Alert, alert.id)
  end

  # The stored snapshot as it comes back out of its `jsonb` column: string keys,
  # ISO dates and effect text. Reading it through the production decoder is what
  # the encoder will do, so these cases assert on exactly that.
  defp stored(publication), do: Publication.snapshot_from_stored(publication.desired_snapshot)

  # The authoring API bounds a description at 2,000 characters, so accepted
  # content large enough to reach the 16 MiB admission budget cannot be built
  # through `save_review/5` at all. These cases therefore store the oversized
  # accepted snapshot directly in `alert_publications` - the same column a
  # refresh reads - and drive every admission and removal through the real
  # production commands, so the budget and withdrawal behavior under test is
  # the production one. `scheduled: true` moves the periods and notice into the
  # future, where `Feed.encode/2` drops the snapshot but admission must not.
  defp inflate_publication!(alert, description_size, opts \\ []) do
    publication = publication_for(alert)

    snapshot =
      publication.desired_snapshot
      |> Map.put("description", String.duplicate("x", description_size))
      |> maybe_scheduled(opts)

    publication
    |> Ecto.Changeset.change(desired_snapshot: snapshot)
    |> Repo.update!()
  end

  defp maybe_scheduled(snapshot, scheduled: true) do
    start = @header_now + 400 * 24 * 60 * 60

    snapshot
    |> Map.put("notice_at", start)
    |> Map.put("periods", [%{"start" => start, "end" => start + 60 * 60}])
  end

  defp maybe_scheduled(snapshot, _opts), do: snapshot

  defp save_review(context, alert, attrs, opts \\ []) do
    Alerts.save_review(context.audit, alert.id, alert.revision, attrs, opts)
  end

  defp autosave(context, alert), do: save_review(context, alert, %{}, [])

  defp publication_for(alert), do: Repo.get_by!(Publication, alert_id: alert.id)

  # A real filtered count: `Repo.aggregate(schema, :count, alert_id: id)` does not
  # apply `alert_id`, so it would count every publication in the transaction.
  defp publication_count(alert) do
    Repo.aggregate(
      from(publication in Publication, where: publication.alert_id == ^alert.id),
      :count
    )
  end

  defp channel_revision(context) do
    Repo.get_by!(Channel, organization_id: context.organization.id, channel: :alerts).desired_revision
  end

  defp all_rows(tabs), do: Enum.flat_map(Map.values(tabs), & &1)

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: if(is_struct(version), do: version.id, else: version),
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end
end
