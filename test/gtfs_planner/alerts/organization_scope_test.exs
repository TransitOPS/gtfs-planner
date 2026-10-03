defmodule GtfsPlanner.Alerts.OrganizationScopeTest do
  @moduledoc """
  Step 7: an alert belongs to its organization, and its trusted targets survive
  the loss of the version they were written against.

  The three prepared cases are proved here at the real command boundary
  (`GtfsPlanner.Alerts`, `Alerts.Listing`, `Alerts.Targets`) with literal
  expectations:

    * both versions' alerts list and edit in one organization, a foreign
      organization is `:not_found`, and near UTC midnight a New York alert and a
      Tokyo alert classify against their own civil date whatever version the
      editor has selected;
    * after the source version is deleted, a message-only save keeps the trusted
      wire IDs, and a retarget replaces the whole selection from one owned
      version;
    * with no schedule an organization still authors a private system-scope
      alert, and the missing timezone and selectors are explicit rather than
      guessed.

  Every alert is written through `create_alert/2`, `save_draft/4` or
  `retarget/5`, so no row is reachable only by a hand-inserted struct.
  """

  use GtfsPlanner.DataCase

  import Ecto.Query, only: [from: 2]

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.AlertSettings
  alias GtfsPlanner.Gtfs.AuditContext

  # 5 October 2026, 02:30 UTC. That is 4 October 22:30 in New York and 5 October
  # 11:30 in Tokyo, so an alert written in either zone is on its own civil date
  # while the other is already on the next one.
  @new_york_night ~U[2026-10-05 02:30:00Z]
  @tokyo_morning ~U[2026-10-05 02:30:00Z]

  setup do
    organization = organization_fixture()
    spring = gtfs_version_fixture(organization.id, %{name: "Spring 26"})
    fall = gtfs_version_fixture(organization.id, %{name: "Fall 26"})

    agency_fixture(organization.id, spring.id, %{
      agency_id: "nyc",
      agency_name: "NYC Transit",
      agency_timezone: "America/New_York"
    })

    agency_fixture(organization.id, fall.id, %{
      agency_id: "tks",
      agency_name: "Tokyo Transit",
      agency_timezone: "Asia/Tokyo"
    })

    actor = editor_fixture(organization)

    %{
      organization: organization,
      spring: spring,
      fall: fall,
      actor: actor,
      audit: audit_context(organization, spring, actor),
      other_audit: audit_context(organization, fall, actor)
    }
  end

  describe "one organization lists and edits both versions' alerts" do
    setup context do
      %{
        spring_alert:
          delay_about(context, context.spring, "Spring detour", nil, "2026-10-01", nil),
        fall_alert: delay_about(context, context.fall, "Fall detour", nil, "2026-10-01", nil)
      }
    end

    test "the list shows every version's alert from either context", context do
      for audit <- [context.audit, context.other_audit] do
        assert {:ok, tabs} = Alerts.list_alerts(audit, @new_york_night)

        assert Enum.sort(Enum.map(tabs.current, & &1.alert.id)) ==
                 Enum.sort([context.spring_alert.id, context.fall_alert.id])
      end
    end

    test "each version's context reads and edits the other version's alert", context do
      # The alert is written against `spring` and read through the `fall` scope,
      # which is what an organization holding two schedules does.
      assert {:ok, alert} = Alerts.get_alert(context.other_audit, context.spring_alert.id)
      assert alert.id == context.spring_alert.id
      assert alert.source_gtfs_version_id == context.spring.id

      assert {:ok, saved} =
               Alerts.save_draft(context.other_audit, alert.id, alert.revision, %{
                 "message" => %{"header" => "Spring detour revised"}
               })

      assert saved.revision == alert.revision + 1
      assert saved.message.header == "Spring detour revised"
      assert saved.source_gtfs_version_id == context.spring.id
    end

    test "an alert of another organization is not found", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      agency_fixture(other_organization.id, other_version.id)

      other_actor = editor_fixture(other_organization)
      theirs = alert_fixture(audit_context(other_organization, other_version, other_actor))

      assert {:error, :not_found} = Alerts.get_alert(context.audit, theirs.id)

      assert {:error, :not_found} =
               Alerts.save_draft(context.audit, theirs.id, theirs.revision, %{
                 "cause" => "weather"
               })

      assert {:error, :not_found} = Alerts.delete_alert(context.audit, theirs.id, theirs.revision)

      # The list this organization reads is its own: the foreign row appears in no
      # tab, at an instant when the organization's own open alerts are current
      # (the enclosing setup writes one per version).
      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @new_york_night)

      listed =
        Enum.map(tabs.current ++ tabs.upcoming ++ tabs.in_progress ++ tabs.past, & &1.alert.id)

      refute theirs.id in listed
    end

    test "a retarget naming another organization's version is not found", context do
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      agency_fixture(foreign_organization.id, foreign_version.id)

      assert {:error, :not_found} =
               Alerts.retarget(
                 context.audit,
                 context.spring_alert.id,
                 context.spring_alert.revision,
                 foreign_version.id,
                 %{"shape" => "system"}
               )

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, context.spring_alert.id)
      assert unchanged.revision == context.spring_alert.revision
      assert unchanged.source_gtfs_version_id == context.spring.id
    end

    test "near UTC midnight each alert classifies on its own civil date", context do
      # The New York alert ended on 3 October local, the Tokyo alert starts on
      # 5 October local. At 02:30 UTC the same instant is 4 October 22:30 in
      # New York and 5 October 11:30 in Tokyo, so the two classify differently
      # and neither depends on the selected version.
      new_york =
        delay_about(context, context.spring, "NY ending today", nil, "2026-10-01", "2026-10-03")

      tokyo =
        delay_about(
          context,
          context.fall,
          "Tokyo starting today",
          nil,
          "2026-10-05",
          "2026-10-06"
        )

      # Read through the New York version's context: the Tokyo alert is still
      # grouped on its own date, not on the selected version's.
      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @tokyo_morning)

      assert Enum.map(tabs.past, & &1.alert.id) == [new_york.id]

      # The enclosing setup writes one open alert per version, so `current` holds
      # those too. What this proves is the classification: at this instant the
      # Tokyo alert is current and the finished New York one is not.
      current_ids = Enum.map(tabs.current, & &1.alert.id)
      assert tokyo.id in current_ids
      refute new_york.id in current_ids

      # And the same instant read through the Tokyo context classifies
      # identically: the selected version does not decide the civil date.
      assert {:ok, other_tabs} = Alerts.list_alerts(context.other_audit, @tokyo_morning)

      assert Enum.map(other_tabs.past, & &1.alert.id) == [new_york.id]

      other_current_ids = Enum.map(other_tabs.current, & &1.alert.id)
      assert tokyo.id in other_current_ids
      refute new_york.id in other_current_ids
    end
  end

  describe "retained targets after the source version is deleted" do
    setup context do
      # `Targets.route_label/1` presents `route_short_name` before `route_long_name`,
      # so the label this suite asserts is the fixture's short name.
      route =
        route_fixture(context.organization.id, context.spring.id, %{
          route_id: "r_1",
          route_short_name: "1 Main"
        })

      stop = stop_fixture(context.organization.id, context.spring.id, %{stop_id: "s_1"})

      alert =
        delay_about(context, context.spring, "Spring detour", route.route_id, "2026-10-01", nil)

      %{route: route, stop: stop, alert: alert}
    end

    test "the create captured the trusted wire IDs, labels and zone", context do
      reference = context.alert.target_reference

      assert reference["source_gtfs_version_id"] == context.spring.id
      assert reference["timezone"] == "America/New_York"

      assert reference["selectors"]["shape"] == "routes"
      assert [%{"gtfs_id" => "r_1", "label" => label}] = reference["selectors"]["routes"]
      assert label == "1 Main"
      assert reference["selectors"]["unresolved_routes"] == []
    end

    test "a message-only save keeps them after the source version is deleted", context do
      delete_version!(context.spring)

      assert {:ok, alert} = Alerts.get_alert(context.audit, context.alert.id)
      assert alert.source_gtfs_version_id == nil

      assert {:ok, saved} =
               Alerts.save_draft(context.audit, alert.id, alert.revision, %{
                 "message" => %{"header" => "Revised after the version went away"}
               })

      # The captured wire ID and label are the ones the alert keeps, and the
      # retained zone is untouched by an edit that changed no selection.
      assert saved.target_reference == alert.target_reference

      assert [%{"gtfs_id" => "r_1", "label" => "1 Main"}] =
               saved.target_reference["selectors"]["routes"]

      assert saved.timezone == "America/New_York"
    end

    test "the deleted route is reported from the retained capture, not guessed", context do
      delete_version!(context.spring)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @new_york_night)
      assert [row] = tabs.current
      assert row.alert.id == context.alert.id
      assert row.needs_attention? == true
    end

    test "retargeting replaces the whole selection from one owned version", context do
      new_route = route_fixture(context.organization.id, context.fall.id, %{route_id: "r_9"})

      assert {:ok, retargeted} =
               Alerts.retarget(
                 context.audit,
                 context.alert.id,
                 context.alert.revision,
                 context.fall.id,
                 %{
                   "shape" => "routes",
                   "route_ids" => [new_route.route_id]
                 }
               )

      assert retargeted.source_gtfs_version_id == context.fall.id
      assert retargeted.timezone == "Asia/Tokyo"
      assert retargeted.revision == context.alert.revision + 1
      assert retargeted.scope.route_ids == ["r_9"]

      assert [%{"gtfs_id" => "r_9"}] = retargeted.target_reference["selectors"]["routes"]
      assert retargeted.target_reference["selectors"]["unresolved_routes"] == []
      assert retargeted.target_reference["timezone"] == "Asia/Tokyo"
    end

    test "retargeting cannot store a selection the named version does not hold", context do
      foreign_stop = stop_fixture(context.organization.id, context.fall.id, %{stop_id: "s_tokyo"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Alerts.retarget(
                 context.audit,
                 context.alert.id,
                 context.alert.revision,
                 context.fall.id,
                 %{
                   "shape" => "stop_all_routes",
                   "stop_ids" => [context.stop.stop_id, foreign_stop.stop_id]
                 }
               )

      # The alert being retargeted still holds a route of the version it was
      # written in, so the fall version refuses both the route it does not hold
      # and the stop it cannot resolve from there.
      # Both messages are reported; the order a changeset holds them in is not
      # part of the contract, and a map-backed scope presents them either way.
      assert %{scope: scope_errors} = errors_on(changeset)

      assert Enum.sort(scope_errors) ==
               Enum.sort([
                 "Choose routes from this version.",
                 "Choose stops from this version."
               ])

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, context.alert.id)

      # The refused write stored nothing: the alert keeps the revision, the source
      # version and the route-shaped selection it already had. Its scope is a
      # `routes` answer, so it carries no stop selection at all (`stop_ids` is nil,
      # not an empty list).
      assert unchanged.revision == context.alert.revision
      assert unchanged.scope == context.alert.scope
      assert unchanged.scope.stop_ids == nil
      assert unchanged.source_gtfs_version_id == context.spring.id
    end

    test "a stale retarget revision changes nothing", context do
      new_route = route_fixture(context.organization.id, context.fall.id, %{route_id: "r_9"})

      {:ok, saved} =
        Alerts.save_draft(context.audit, context.alert.id, context.alert.revision, %{
          "message" => %{"header" => "Saved first"}
        })

      assert {:error, :stale, current} =
               Alerts.retarget(
                 context.audit,
                 context.alert.id,
                 saved.revision - 1,
                 context.fall.id,
                 %{
                   "shape" => "routes",
                   "route_ids" => [new_route.route_id]
                 }
               )

      assert current.revision == saved.revision
      assert current.source_gtfs_version_id == context.spring.id
    end
  end

  describe "an organization with no usable schedule" do
    setup do
      organization = organization_fixture()
      actor = editor_fixture(organization)

      %{
        organization: organization,
        actor: actor,
        # A context with no selected version: the organization has no schedule to
        # write against, which is the case this step must still author in.
        audit: %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: nil,
          station_stop_id: nil,
          actor_id: actor.id,
          actor_email: actor.email
        }
      }
    end

    test "still authors a private system-scope alert", context do
      assert {:ok, alert} =
               Alerts.create_alert(context.audit, %{
                 "urgency" => "now",
                 "situation" => "delay",
                 "cause" => "weather",
                 "scope" => %{"shape" => "system"},
                 "message" => %{"header" => "System-wide delay"}
               })

      assert alert.organization_id == context.organization.id
      assert alert.source_gtfs_version_id == nil
      assert alert.scope.shape == :system

      # No schedule means no zone to retain and no identities to capture: both
      # stay absent rather than defaulting to UTC or to an empty selector the
      # publication step could mistake for a system-wide agency list.
      assert alert.timezone == nil

      assert alert.target_reference["source_gtfs_version_id"] == nil
      assert alert.target_reference["timezone"] == nil
      assert alert.target_reference["selectors"]["agencies"] == []
      assert alert.target_reference["selectors"]["unresolved_routes"] == []

      assert {:ok, %{in_progress: [row]}} = Alerts.list_alerts(context.audit, @new_york_night)
      assert row.alert.id == alert.id
    end

    test "a system scope against a version captures that version's real agency ids" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      agency_fixture(organization.id, version.id, %{
        agency_id: "nyc",
        agency_name: "NYC Transit",
        agency_timezone: "America/New_York"
      })

      actor = editor_fixture(organization)
      audit = audit_context(organization, version, actor)

      assert {:ok, alert} =
               Alerts.create_alert(audit, %{"scope" => %{"shape" => "system"}})

      assert [%{"gtfs_id" => "nyc", "label" => "NYC Transit"}] =
               alert.target_reference["selectors"]["agencies"]

      assert alert.timezone == "America/New_York"
    end
  end

  describe "an alert with no retained zone" do
    setup context do
      # Two agencies with different zones in one version: there is no single
      # usable agency zone, so no zone is retained and none is guessed.
      conflicting = gtfs_version_fixture(context.organization.id, %{name: "Conflicting zones"})

      agency_fixture(context.organization.id, conflicting.id, %{
        agency_id: "one",
        agency_timezone: "America/New_York"
      })

      agency_fixture(context.organization.id, conflicting.id, %{
        agency_id: "two",
        agency_timezone: "Asia/Tokyo"
      })

      audit = audit_context(context.organization, conflicting, context.actor)

      %{conflicting: conflicting, conflicting_audit: audit}
    end

    test "listing falls back to the organization's stated zone", context do
      alert =
        alert_fixture(context.conflicting_audit, %{
          "urgency" => "now",
          "situation" => "delay",
          "cause" => "weather",
          "scope" => %{"shape" => "system"},
          "message" => %{"header" => "Conflicting zones", "description" => "Track work downtown."}
        })

      assert alert.timezone == nil
      assert alert.target_reference["timezone"] == nil
      assert Alerts.organization_zone(context.conflicting_audit) == nil

      # With no retained zone and no stated organization zone the row reads in
      # the disclosed UTC fallback, which is a presentation answer and never a
      # publication consent.
      assert GtfsPlanner.Alerts.Listing.zone(alert, nil) == "UTC"
      assert [row] = Alerts.Listing.rows([alert], @new_york_night, nil).in_progress
      assert row.alert.id == alert.id

      # The organization's explicit zone answers for it once stated, and is
      # absent - never UTC - until then.
      save_timezone!(context.organization, "America/New_York")
      assert Alerts.organization_zone(context.conflicting_audit) == "America/New_York"
      assert GtfsPlanner.Alerts.Listing.zone(alert, "America/New_York") == "America/New_York"
    end
  end

  # -- Fixtures ------------------------------------------------------------

  defp delay_about(context, version, header, route_id, start_date, end_date) do
    scope =
      if route_id do
        %{"shape" => "routes", "route_ids" => [route_id]}
      else
        %{"shape" => "system"}
      end

    audit = audit_context(context.organization, version, context.actor)

    alert =
      alert_fixture(audit, %{
        "urgency" => "now",
        "situation" => "delay",
        "cause" => "weather",
        "scope" => scope,
        "message" => %{"header" => header, "description" => "Water main work on Main St."}
      })

    timing = %{
      "start_date" => start_date,
      "start_time" => "08:00:00",
      "end_kind" => if(end_date, do: "confirmed", else: "estimated"),
      "end_date" => end_date,
      "check_in_at" => "2026-10-06 09:00:00"
    }

    {:ok, saved} = Alerts.save_draft(audit, alert.id, alert.revision, %{"timing" => timing})
    saved
  end

  # The GTFS rows and then the version itself: a route and a stop reference the
  # version with a plain foreign key, so a source version only becomes
  # unreachable once its own schedule rows are gone.
  defp delete_version!(version) do
    for schema <- [GtfsPlanner.Gtfs.Route, GtfsPlanner.Gtfs.Stop, GtfsPlanner.Gtfs.Agency] do
      Repo.delete_all(from(row in schema, where: row.gtfs_version_id == ^version.id))
    end

    Repo.get!(GtfsPlanner.Versions.GtfsVersion, version.id) |> Repo.delete!()
  end

  defp save_timezone!(organization, timezone) do
    settings =
      case Repo.get_by(AlertSettings, organization_id: organization.id) do
        nil ->
          %AlertSettings{}
          |> AlertSettings.timezone_changeset(%{"timezone" => timezone})
          |> Ecto.Changeset.put_change(:organization_id, organization.id)
          |> Repo.insert!()

        stored ->
          stored |> AlertSettings.timezone_changeset(%{"timezone" => timezone}) |> Repo.update!()
      end

    settings
  end

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
