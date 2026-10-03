defmodule GtfsPlanner.Agents.Packs.AlertsTest do
  @moduledoc """
  Step 26: the alerts capability pack reads and prepares only within its own
  alert (AC-27, FH-27).

  Every case drives the pack through `GtfsPlanner.Agents.Dispatch.call/4`, the
  fence the session actually uses, with a scope whose subject is one real
  `service_alerts` row created through `Alerts.create_alert/2`. Two versions of
  one organization share their GTFS identifiers, so a lookup that forgot the
  alert's version would return the sibling version's row rather than nothing.
  """

  use GtfsPlanner.DataCase, async: true

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.BrowserOpenRouter
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Alerts, as: AlertsPack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.ScopeAnswer.RouteStopPair
  alias GtfsPlanner.Alerts.ScopeAnswer.TripTarget
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  # The first Monday of October 2026; the fixture calendar runs Monday to Friday.
  @monday ~D[2026-10-05]

  @tool_names [
    "get_draft",
    "search_routes",
    "search_stops",
    "route_stops",
    "departures_on",
    "list_scripts",
    "get_guidelines",
    "check_draft",
    "propose_changes"
  ]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    sibling = gtfs_version_fixture(organization.id)
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    actor = editor_fixture(organization)

    agency_fixture(organization.id, version.id)
    agency_fixture(organization.id, sibling.id)
    agency_fixture(foreign_organization.id, foreign_version.id)

    audit = audit_context(organization, version, actor)
    sibling_audit = audit_context(organization, sibling, actor)

    alert = alert_fixture(audit, %{"urgency" => "now"})

    %{
      organization: organization,
      version: version,
      sibling: sibling,
      foreign_organization: foreign_organization,
      foreign_version: foreign_version,
      actor: actor,
      audit: audit,
      sibling_audit: sibling_audit,
      alert: alert,
      scope: scope_fixture(actor, organization, version, alert.id)
    }
  end

  describe "pack declaration" do
    test "declares the read tools and the one prepare tool" do
      assert AlertsPack.id() == "alerts"
      assert AlertsPack.title() == "Alert assistant"

      assert Enum.map(AlertsPack.tools(), & &1.name) == @tool_names

      assert Enum.all?(AlertsPack.tools(), &is_binary(&1.activity))
      assert [first_example | _rest] = AlertsPack.examples()
      assert is_binary(first_example)
      assert AlertsPack.intro() != ""
    end

    test "every tool closes its argument object and declares no identity" do
      for tool <- AlertsPack.tools() do
        assert tool.parameters["type"] == "object"
        assert tool.parameters["additionalProperties"] == false

        properties = Map.keys(tool.parameters["properties"])

        for forbidden <- [
              "alert_id",
              "organization_id",
              "gtfs_version_id",
              "user_id",
              "revision",
              "subject_id"
            ] do
          refute forbidden in properties, "#{tool.name} declares #{forbidden}"
        end
      end
    end

    test "propose_changes declares exactly the fields the answer changesets cast" do
      properties = propose_changes_properties()

      assert properties |> Map.keys() |> Enum.sort() ==
               ~w(cause cause_detail message scope service_change_kind situation timing urgency)

      assert declared_keys(properties["scope"]) == fields(ScopeAnswer, [])
      assert declared_keys(properties["timing"]) == fields(TimingAnswer, [:time_zone])

      assert declared_keys(properties["message"]) ==
               fields(MessageAnswer, [:script_key, :customized, :fact_digest])

      assert declared_keys(properties["scope"]["properties"]["route_stop_pairs"]["items"]) ==
               fields(RouteStopPair, [])

      assert declared_keys(properties["scope"]["properties"]["trips"]["items"]) ==
               fields(TripTarget, [])
    end

    test "the skill names the interview order and refuses to claim publication" do
      skill = AlertsPack.skill()

      assert skill =~ "You never save"
      assert skill =~ "Ask one question at a time"
      assert skill =~ "Now or planned"
      assert skill =~ "What is happening"
      assert skill =~ "When."
      assert skill =~ "The message"
    end
  end

  describe "the dispatch fence" do
    test "refuses an alert_id argument before the pack runs", context do
      for tool <- AlertsPack.tools() do
        assert Dispatch.call(AlertsPack, context.scope, tool.name, ~s|{"alert_id":"other"}|) ==
                 {:tool_error, "Unexpected argument: alert_id"}
      end

      assert row_count(context) == {1, 0, 0}
    end

    test "refuses an identity argument on propose_changes before validation", context do
      arguments =
        Jason.encode!(%{
          "situation" => "detour",
          "organization_id" => context.foreign_organization.id
        })

      assert Dispatch.call(AlertsPack, context.scope, "propose_changes", arguments) ==
               {:tool_error, "Unexpected argument: organization_id"}
    end

    test "refuses a conversation with no subject alert", context do
      scope = %{context.scope | subject_id: nil}

      assert Dispatch.call(AlertsPack, scope, "get_draft", "{}") == {:error, :unavailable}
    end

    test "reads a subject alert of this organization written against another version", context do
      sibling_route =
        route_fixture(context.organization.id, context.sibling.id, route_attrs("r12", "12"))

      _scope_route =
        route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      elsewhere = alert_fixture(context.sibling_audit, %{"urgency" => "planned"})
      scope = %{context.scope | subject_id: elsewhere.id}

      assert {:ok, %{"urgency" => "planned"}} =
               Dispatch.call(AlertsPack, scope, "get_draft", "{}")

      assert Dispatch.call(AlertsPack, scope, "check_draft", "{}") != {:error, :unavailable}

      # The tools read the alert's own retained source version, not the version
      # this scope carries.
      assert {:ok, %{"routes" => routes}} =
               Dispatch.call(AlertsPack, scope, "search_routes", ~s|{"query":"12"}|)

      assert Enum.map(routes, & &1["id"]) == [sibling_route.route_id]
    end

    test "refuses a subject alert of another organization", context do
      foreign_actor = editor_fixture(context.foreign_organization)

      foreign_audit =
        audit_context(context.foreign_organization, context.foreign_version, foreign_actor)

      elsewhere = alert_fixture(foreign_audit, %{"urgency" => "now"})

      scope = %{context.scope | subject_id: elsewhere.id}

      assert Dispatch.call(AlertsPack, scope, "get_draft", "{}") == {:error, :unavailable}
    end

    test "refuses a subject alert that was deleted", context do
      assert AlertsPack.authorize_context(context.scope) == :ok

      Repo.delete!(context.alert)

      assert AlertsPack.authorize_context(context.scope) == {:error, :unavailable}
      assert Dispatch.call(AlertsPack, context.scope, "get_draft", "{}") == {:error, :unavailable}
    end

    test "the subject is this organization's alert whichever version wrote it", context do
      elsewhere = alert_fixture(context.sibling_audit, %{"urgency" => "planned"})
      scope = %{context.scope | subject_id: elsewhere.id}

      assert {:ok, %{"urgency" => "planned"}} = AlertsPack.call("get_draft", %{}, scope)
    end

    test "a subject alert of another organization is refused, not read", context do
      stranger = editor_fixture(context.foreign_organization)

      elsewhere =
        alert_fixture(
          audit_context(context.foreign_organization, context.foreign_version, stranger),
          %{"urgency" => "planned"}
        )

      scope = %{context.scope | subject_id: elsewhere.id}

      assert AlertsPack.call("get_draft", %{}, scope) ==
               {:error, "This alert is not available here."}

      assert Dispatch.call(AlertsPack, scope, "get_draft", "{}") == {:error, :unavailable}
    end
  end

  describe "get_draft" do
    test "reads the subject alert's own answers and labels", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))
      stop = stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Elm St"))

      {:ok, _saved} =
        Alerts.save_draft(
          context.audit,
          context.alert.id,
          context.alert.revision,
          %{
            "situation" => "detour",
            "scope" => %{
              "shape" => "route_stops",
              "route_ids" => [route.route_id],
              "stop_ids" => [stop.stop_id]
            },
            "timing" => %{"start_date" => "2026-10-05", "start_time" => "08:00:00"},
            "message" => %{"header" => "Route 12 detour"}
          },
          schedule_opts(context.audit)
        )

      assert {:ok, draft} = call("get_draft", %{}, context.scope)

      assert draft["revision"] == 2
      assert draft["urgency"] == "now"
      assert draft["situation"] == "detour"
      assert draft["effect"] == "detour"
      assert draft["scope"]["shape"] == "route_stops"
      assert draft["scope"]["route_ids"] == [route.route_id]
      assert draft["timing"]["start_date"] == "2026-10-05"
      assert draft["timing"]["start_time"] == "08:00:00"
      assert draft["message"]["header"] == "Route 12 detour"
      assert draft["labels"]["routes"][route.route_id] =~ "12"
      assert draft["labels"]["stops"][stop.stop_id] =~ "Elm St"
    end

    test "reads a draft in another version only through that version's scope", context do
      sibling_route =
        route_fixture(context.organization.id, context.sibling.id, route_attrs("r12", "12"))

      _mine = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      elsewhere = alert_fixture(context.sibling_audit, %{"urgency" => "planned"})

      {:ok, _saved} =
        Alerts.save_draft(
          context.sibling_audit,
          elsewhere.id,
          elsewhere.revision,
          %{"scope" => %{"shape" => "routes", "route_ids" => [sibling_route.route_id]}},
          schedule_opts(context.sibling_audit)
        )

      sibling_scope =
        scope_fixture(context.actor, context.organization, context.sibling, elsewhere.id)

      assert {:ok, draft} = call("get_draft", %{}, sibling_scope)
      assert draft["urgency"] == "planned"
      assert draft["scope"]["route_ids"] == [sibling_route.route_id]

      # The alert is the subject and the organization owns it, so a scope naming
      # another of the organization's versions reads the same draft: the version
      # supplies lookup context, never the identity of the subject (step 9). The
      # editor still refuses another organization, which its own cases prove.
      other_version_scope = %{sibling_scope | gtfs_version_id: context.version.id}

      assert {:ok, same_draft} = Dispatch.call(AlertsPack, other_version_scope, "get_draft", "{}")
      assert same_draft["scope"]["route_ids"] == [sibling_route.route_id]
    end
  end

  describe "the target read tools" do
    test "search_stops returns only the subject alert's version", context do
      mine = stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Elm St"))

      _theirs =
        stop_fixture(
          context.organization.id,
          context.sibling.id,
          stop_attrs("S1", "Elm St Elsewhere")
        )

      _foreign =
        stop_fixture(
          context.foreign_organization.id,
          context.foreign_version.id,
          stop_attrs("S1", "Elm St Foreign")
        )

      assert {:ok, %{"stops" => [option]}} =
               call("search_stops", %{"query" => "S1"}, context.scope)

      assert option["id"] == mine.stop_id
      assert option["label"] == "Elm St"
    end

    test "search_stops can prefer and exclude this alert's own targets", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      served =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Elm St"))

      other =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S2", "Elm Road"))

      # Only Elm St is served by the route, so only it is preferred; Elm Road
      # would sort first alphabetically.
      trip = trip_fixture(context.organization.id, context.version.id, route.route_id)

      stop_time_fixture(
        context.organization.id,
        context.version.id,
        trip.trip_id,
        served.stop_id,
        %{stop_sequence: 1, departure_time: "08:15:00"}
      )

      assert {:ok, %{"stops" => [first, second]}} =
               call(
                 "search_stops",
                 %{"query" => "Elm", "prefer_route_ids" => [route.route_id]},
                 context.scope
               )

      assert Enum.map([first, second], & &1["id"]) == [served.stop_id, other.stop_id]

      assert {:ok, %{"stops" => [only]}} =
               call(
                 "search_stops",
                 %{"query" => "Elm", "exclude_stop_ids" => [served.stop_id]},
                 context.scope
               )

      assert only["id"] == other.stop_id
    end

    test "search_routes, route_stops and departures_on read this version", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      _sibling_route =
        route_fixture(context.organization.id, context.sibling.id, route_attrs("r12", "12"))

      trip =
        trip_fixture(context.organization.id, context.version.id, route.route_id, %{
          service_id: "weekday",
          direction_id: 0,
          trip_headsign: "Depot"
        })

      stop = stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Elm St"))

      calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      stop_time_fixture(
        context.organization.id,
        context.version.id,
        trip.trip_id,
        stop.stop_id,
        %{
          stop_sequence: 1,
          departure_time: "08:15:00"
        }
      )

      assert {:ok, %{"routes" => [only_route]}} =
               call("search_routes", %{"query" => "12"}, context.scope)

      assert only_route["id"] == route.route_id
      assert only_route["route_id"] == "r12"

      assert {:ok, %{"stops" => [only_stop]}} =
               call("route_stops", %{"route_id" => route.route_id}, context.scope)

      assert only_stop["id"] == stop.stop_id

      assert {:ok, %{"departures" => [departure]}} =
               call(
                 "departures_on",
                 %{"route_id" => route.route_id, "date" => "2026-10-05", "direction_id" => 0},
                 context.scope
               )

      assert departure["trip_id"] == trip.trip_id
      assert departure["label"] == "8:15 AM to Depot"
    end

    test "a foreign route id finds no stops and no departures", context do
      foreign_route =
        route_fixture(
          context.foreign_organization.id,
          context.foreign_version.id,
          route_attrs("r12", "12")
        )

      assert {:ok, %{"stops" => []}} =
               call("route_stops", %{"route_id" => foreign_route.route_id}, context.scope)

      assert {:ok, %{"departures" => []}} =
               call(
                 "departures_on",
                 %{"route_id" => foreign_route.route_id, "date" => "2026-10-05"},
                 context.scope
               )
    end

    test "departures_on refuses a date it cannot read and a direction it does not have",
         context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      assert call(
               "departures_on",
               %{"route_id" => route.route_id, "date" => "sometime"},
               context.scope
             ) ==
               {:tool_error, "Invalid date: sometime. Use a date like 2026-10-12."}

      assert call(
               "departures_on",
               %{"route_id" => route.route_id, "date" => @monday, "direction_id" => 4},
               context.scope
             ) ==
               {:tool_error, "Invalid direction: 4."}
    end

    test "list_scripts and get_guidelines read the organization, not a version", context do
      assert {:ok, %{"scripts" => scripts}} = call("list_scripts", %{}, context.scope)

      assert Enum.map(scripts, & &1["name"]) == [
               "Detour, stops skipped",
               "Delays",
               "Stop moved, use nearby stop",
               "Stop closed, use nearby stop",
               "No service on a day",
               "Elevator or lift out of service",
               "Rider information",
               "Service suspended"
             ]

      assert [first | _rest] = scripts
      assert first["built_in"] == true
      assert first["situation"] == "detour"
      assert first["header_template"] =~ "[first skipped]"

      assert {:ok, %{"guidelines" => guidelines, "revision" => 0}} =
               call("get_guidelines", %{}, context.scope)

      assert guidelines =~ "Lead with the route and the change"
    end
  end

  describe "check_draft" do
    test "names the questions the draft has not answered yet", context do
      assert {:ok, check} = call("check_draft", %{}, context.scope)

      assert check["complete"] == false
      assert check["effect"] == nil

      # The alert is a `now` alert: its timing is empty, so the start date, the
      # start time and the end are still open beside the situation and message.
      assert Enum.map(check["outstanding"], & &1["step"]) ==
               ["situation", "timing", "timing", "timing", "message", "message"]
    end

    test "reports the effect and the remaining questions after answers are saved", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      {:ok, _saved} =
        Alerts.save_draft(
          context.audit,
          context.alert.id,
          context.alert.revision,
          %{
            "situation" => "delay",
            "scope" => %{"shape" => "routes", "route_ids" => [route.route_id]},
            "timing" => %{
              "start_date" => "2026-10-05",
              "start_time" => "08:00:00",
              "end_kind" => "unknown",
              "check_in_at" => "2026-10-05 10:00:00"
            },
            "message" => %{
              "header" => "Route 12 delayed",
              "description" => "Route 12 buses are running late. Allow extra time."
            }
          },
          schedule_opts(context.audit)
        )

      assert {:ok, check} = call("check_draft", %{}, context.scope)

      assert check["effect"] == "significant_delays"
      assert check["timing"] =~ "Oct 5"
      assert check["outstanding"] == []
      assert check["complete"] == true
    end
  end

  describe "propose_changes" do
    test "prepares a validated change for the editor to apply", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      assert {:prepared, prepared, %{"status" => "prepared"}} =
               call(
                 "propose_changes",
                 %{"situation" => "detour", "scope" => %{"route_ids" => [route.route_id]}},
                 context.scope
               )

      assert prepared.command ==
               {:alert_changes,
                %{"situation" => "detour", "scope" => %{"route_ids" => [route.route_id]}}}

      assert prepared.summary.title == "Update this alert"
      assert "Situation · Detour" in prepared.summary.lines

      # Preparing wrote nothing: the draft is still the one the fixture made.
      assert {:ok, draft} = call("get_draft", %{}, context.scope)
      assert draft["revision"] == 1
      assert draft["situation"] == nil
    end

    test "accepts every field the answers declare", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))
      stop = stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Elm St"))
      trip = trip_fixture(context.organization.id, context.version.id, route.route_id)

      arguments = %{
        "urgency" => "planned",
        "situation" => "stop_moved",
        "service_change_kind" => "information",
        "cause" => "construction",
        "cause_detail" => "Track work",
        "scope" => %{
          "shape" => "route_stops",
          "mode_route_type" => 3,
          "route_ids" => [route.route_id],
          "stop_ids" => [stop.stop_id],
          "route_stop_pairs" => [%{"route_id" => route.route_id, "stop_id" => stop.stop_id}],
          "trips" => [%{"trip_id" => trip.trip_id, "service_date" => "2026-10-05"}],
          "direction_id" => 1,
          "all_routes_at_stops" => true,
          "stretch_from_stop_id" => stop.stop_id,
          "stretch_to_stop_id" => stop.stop_id,
          "alternative_stop_id" => stop.stop_id,
          "alternative_directions" => "Board at Elm St.",
          "facility" => "Elevator"
        },
        "timing" => %{
          "start_date" => "2026-10-05",
          "start_time" => "08:00",
          "end_kind" => "estimated",
          "end_date" => "2026-10-06",
          "end_time" => "17:00",
          "check_in_at" => "2026-10-05T10:00:00",
          "pattern" => "weekly",
          "first_date" => "2026-10-05",
          "weeks" => 4,
          "weekdays" => [1, 2, 3, 4, 5],
          "all_day" => false,
          "last_date" => "2026-11-02",
          "added_dates" => ["2026-10-10"],
          "removed_dates" => ["2026-10-12"],
          "notice_on" => "2026-10-01",
          "delay_minutes" => 15
        },
        "message" => %{
          "header" => "Route 12 detour",
          "description" => "Route 12 buses skip Elm St.",
          "url" => "https://example.com/alerts/12"
        }
      }

      assert {:prepared, prepared, %{"status" => "prepared"}} =
               call("propose_changes", arguments, context.scope)

      assert prepared.command == {:alert_changes, arguments}
    end

    test "prepares the arguments the scripted browser provider sends", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      arguments = scripted_propose_arguments(route.route_id)

      assert {:prepared, prepared, %{"status" => "prepared"}} =
               Dispatch.call(AlertsPack, context.scope, "propose_changes", arguments)

      assert {:alert_changes, %{"situation" => "detour"}} = prepared.command
    end

    test "refuses a route, stop and departure this alert's version does not have", context do
      sibling_route =
        route_fixture(context.organization.id, context.sibling.id, route_attrs("r12", "12"))

      missing = Ecto.UUID.generate()

      assert call(
               "propose_changes",
               %{"scope" => %{"route_ids" => [sibling_route.route_id]}},
               context.scope
             ) ==
               {:tool_error,
                "Not in this service version: route #{sibling_route.route_id}. " <>
                  "Use ids the search tools returned."}

      assert call(
               "propose_changes",
               %{"scope" => %{"stop_ids" => [missing], "stretch_from_stop_id" => "12"}},
               context.scope
             ) ==
               {:tool_error,
                "Not in this service version: stop #{missing}, stop 12. " <>
                  "Use ids the search tools returned."}

      assert call(
               "propose_changes",
               %{
                 "scope" => %{
                   "trips" => [%{"trip_id" => missing, "service_date" => "2026-10-05"}]
                 }
               },
               context.scope
             ) ==
               {:tool_error,
                "Not in this service version: trip #{missing}. Use ids the search tools returned."}

      assert {:ok, draft} = call("get_draft", %{}, context.scope)
      assert draft["revision"] == 1
    end

    test "accepts a route type the version has and refuses one it does not", context do
      route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      assert {:prepared, prepared, _result} =
               call("propose_changes", %{"scope" => %{"mode_route_type" => 3}}, context.scope)

      assert prepared.command == {:alert_changes, %{"scope" => %{"mode_route_type" => 3}}}

      assert call("propose_changes", %{"scope" => %{"mode_route_type" => 11}}, context.scope) ==
               {:tool_error,
                "Not in this service version: route type 11. Use ids the search tools returned."}
    end

    test "keeps a target the stored alert already names after the version dropped it", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      {:ok, _saved} =
        Alerts.save_draft(
          context.audit,
          context.alert.id,
          context.alert.revision,
          %{"scope" => %{"shape" => "routes", "route_ids" => [route.route_id]}},
          schedule_opts(context.audit)
        )

      Repo.delete!(route)

      assert {:prepared, _prepared, %{"status" => "prepared"}} =
               call(
                 "propose_changes",
                 %{"situation" => "delay", "scope" => %{"route_ids" => [route.route_id]}},
                 context.scope
               )
    end

    test "refuses a header over the length the fence declares", context do
      long_header = String.duplicate("a", 121)

      assert call("propose_changes", %{"message" => %{"header" => long_header}}, context.scope) ==
               {:tool_error, "Argument message.header must be at most 120 characters."}
    end

    test "names the argument and fills in the limit when the changeset refuses an answer",
         context do
      long_header = String.duplicate("a", 121)

      # The pack validates with the editor's own changeset even when the fence
      # is not in front of it, so a nested error is a message the model can
      # correct instead of a crash.
      assert AlertsPack.call(
               "propose_changes",
               %{"message" => %{"header" => long_header}},
               context.scope
             ) == {:error, "message.header: should be at most 120 character(s)"}
    end

    test "names every nested answer the editor would refuse", context do
      assert call(
               "propose_changes",
               %{
                 "timing" => %{"start_date" => "tomorrow"},
                 "message" => %{"url" => "javascript:alert(1)"}
               },
               context.scope
             ) ==
               {:tool_error,
                "message.url: must be a full web address starting with https:// or http://; " <>
                  "timing.start_date: is invalid"}
    end

    test "refuses a value outside the situations the editor offers", context do
      assert call("propose_changes", %{"situation" => "evacuation"}, context.scope) ==
               {:tool_error, "situation: is invalid"}
    end

    test "refuses a proposal that changes nothing", context do
      assert Dispatch.call(AlertsPack, context.scope, "propose_changes", "{}") ==
               {:tool_error, "Provide at least one answer to change."}
    end

    test "refuses an identity key inside an answer", context do
      assert call(
               "propose_changes",
               %{
                 "situation" => "delay",
                 "scope" => %{
                   "shape" => "system",
                   "organization_id" => context.foreign_organization.id
                 }
               },
               context.scope
             ) == {:tool_error, "Unexpected argument: scope.organization_id"}
    end

    test "refuses the answer fields the editor and the version own", context do
      for {answer, key} <- [
            {"message", "script_key"},
            {"message", "customized"},
            {"message", "fact_digest"},
            {"timing", "time_zone"}
          ] do
        assert call("propose_changes", %{answer => %{key => "x"}}, context.scope) ==
                 {:tool_error, "Unexpected argument: #{answer}.#{key}"}
      end
    end
  end

  describe "no tool writes" do
    test "row counts and the alert's revision are unchanged after every tool", context do
      before = row_count(context)
      assert before == {1, 0, 0}

      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))
      stop = stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Elm St"))

      assert {:ok, _} = call("get_draft", %{}, context.scope)
      assert {:ok, _} = call("search_routes", %{"query" => "12"}, context.scope)
      assert {:ok, _} = call("search_stops", %{"query" => "Elm"}, context.scope)
      assert {:ok, _} = call("route_stops", %{"route_id" => route.route_id}, context.scope)
      assert {:ok, _} = call("list_scripts", %{}, context.scope)
      assert {:ok, _} = call("get_guidelines", %{}, context.scope)
      assert {:ok, _} = call("check_draft", %{}, context.scope)

      assert {:prepared, _prepared, _result} =
               call(
                 "propose_changes",
                 %{
                   "situation" => "detour",
                   "scope" => %{
                     "shape" => "route_stops",
                     "route_ids" => [route.route_id],
                     "stop_ids" => [stop.stop_id]
                   },
                   "message" => %{"header" => "Route 12 detour"}
                 },
                 context.scope
               )

      assert row_count(context) == before

      assert Repo.get(Alert, context.alert.id).revision == 1
    end
  end

  defp call(name, args, scope) do
    Dispatch.call(AlertsPack, scope, name, Jason.encode!(args))
  end

  defp propose_changes_properties do
    tool = Enum.find(AlertsPack.tools(), &(&1.name == "propose_changes"))
    tool.parameters["properties"]
  end

  defp declared_keys(object), do: object["properties"] |> Map.keys() |> Enum.sort()

  defp fields(schema, left_out) do
    (schema.__schema__(:fields) -- left_out) |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  end

  # The `propose_changes` call the scripted browser provider makes after it has
  # found Route 12, read out of the stand-in's own reply rather than copied.
  defp scripted_propose_arguments(route_id) do
    messages = [
      %{"role" => "system", "content" => AlertsPack.skill() <> "\n\nToday is 2026-10-01."},
      %{"role" => "user", "content" => "Route 12 is detouring"},
      assistant_call("call_get_draft", "get_draft", %{}),
      tool_message("call_get_draft", %{}),
      assistant_call("call_search_routes", "search_routes", %{"query" => "12"}),
      tool_message("call_search_routes", %{
        "routes" => [%{"id" => route_id, "route_id" => "12", "short_name" => "12"}]
      })
    ]

    conn =
      :post
      |> Plug.Test.conn("/api/v1/chat/completions", Jason.encode!(%{"messages" => messages}))
      |> BrowserOpenRouter.call([])

    %{"choices" => [%{"message" => %{"tool_calls" => [call]}}]} = Jason.decode!(conn.resp_body)
    assert call["function"]["name"] == "propose_changes"
    call["function"]["arguments"]
  end

  defp assistant_call(id, name, arguments) do
    %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
        }
      ]
    }
  end

  defp tool_message(id, payload) do
    %{"role" => "tool", "tool_call_id" => id, "content" => Jason.encode!(payload)}
  end

  # The three row counts the pack could write: the alert itself, a script and the
  # organization's guidelines settings.
  defp row_count(context) do
    organization_id = context.organization.id

    {count(Alert, organization_id), count(Alerts.AlertScript, organization_id),
     count(Alerts.AlertSettings, organization_id)}
  end

  defp count(schema, organization_id) do
    Repo.aggregate(from(row in schema, where: row.organization_id == ^organization_id), :count)
  end

  defp scope_fixture(user, organization, version, subject_id) do
    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "alerts",
      version_name: version.name,
      subject_id: subject_id
    }
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp stop_attrs(stop_id, stop_name) do
    %{
      stop_id: stop_id,
      stop_name: stop_name,
      location_type: 0,
      stop_lat: Decimal.new("40.0"),
      stop_lon: Decimal.new("-74.0")
    }
  end

  defp route_attrs(route_id, short_name) do
    %{route_id: route_id, route_short_name: short_name, route_type: 3}
  end
end
