defmodule GtfsPlanner.Agents.Packs.HeadsignsPrepareTest do
  @moduledoc """
  Merge evidence (EV-3) for `prepare_headsign_change`.

  Selection is checked against the A01 fixture in
  `GtfsPlanner.HeadsignHelperFixtures`, written by hand: the twelve followers
  (the twelfth stored with surrounding spaces) change, while the two interlined
  trips, the lowercase trip and the two `Peak` trips, which carry their own
  headsign, never do. Every case also stamps the rows before and after, so a
  preparation that wrote anything fails.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.HeadsignHelperFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Headsigns
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)
    a01 = a01_fixture(organization.id, version.id)

    %{organization: organization, version: version, user: user, a01: a01}
  end

  test "renames exactly the twelve followers and keeps every protected trip", context do
    scope = pattern_scope(context)
    before = stamps()

    assert {:prepared, prepared, result, evidence} =
             prepare(scope, %{
               "current_text" => "Downtown Terminal",
               "new_text" => "Central Station"
             })

    assert {:headsign_change, command} = prepared.command

    assert command == %{
             pattern_id: context.a01.pattern.id,
             scope: :pattern,
             from: "Downtown Terminal",
             to: "Central Station",
             trip_ids: follower_ids(context)
           }

    protected = for id <- ~w(A01-I1 A01-I2 A01-C1 A01-P1 A01-P2), do: trip_uuid(context, id)
    assert Enum.all?(protected, &(&1 not in command.trip_ids))
    assert length(command.trip_ids) == 12

    assert prepared.summary.title == ~s(Rename headsign to "Central Station")

    assert prepared.summary.detail ==
             ~s(Pattern Downtown · "Downtown Terminal" to "Central Station")

    assert prepared.summary.lines == [
             "12 trips change",
             "3 trips keep their own text (A01-C1, A01-I1, A01-I2)",
             "Stop-level headsigns are not changed",
             "2 trips on timings with their own headsign are not changed",
             "Trips whose text matches the default by coincidence are treated as following it"
           ]

    assert result["trips_change"] == 12
    assert result["trips_kept"] == 3
    assert result["trips_shielded"] == 2
    assert result["note"] =~ "Nothing is saved"

    assert evidence.kind == "headsign_change"
    assert evidence.total == 12
    assert evidence.total_label == "trips will change"
    assert evidence.completeness == :complete

    assert evidence.exclusions == [
             "A01-C1 (keeps its own text)",
             "A01-I1 (keeps its own text)",
             "A01-I2 (keeps its own text)"
           ]

    assert stamps() == before
  end

  test "the prepared ids are exactly what the native review proposes", context do
    scope = pattern_scope(context)

    assert {:prepared, %{command: {:headsign_change, command}}, _result, _evidence} =
             prepare(scope, %{
               "current_text" => "Downtown Terminal",
               "new_text" => "Central Station"
             })

    audit = GtfsPlanner.Agents.Scope.audit_context(scope)

    assert {:ok, %{proposed: %{headsign_changes: changes}}} =
             Gtfs.review(
               context.a01.pattern.id,
               {:details, %{headsign: "Central Station"}, %{headsign_trip_ids: command.trip_ids}},
               nil,
               audit
             )

    assert changes |> Enum.map(& &1.id) |> Enum.sort() == command.trip_ids
    assert Enum.all?(changes, &(&1.from == "Downtown Terminal" and &1.to == "Central Station"))
  end

  test "excluded trips leave the selection; unknown or foreign ones are refused", context do
    scope = pattern_scope(context)
    args = %{"current_text" => "Downtown Terminal", "new_text" => "Central Station"}

    excluded = trip_uuid(context, "A01-F03")

    assert {:prepared, %{command: {:headsign_change, command}} = prepared, result, _evidence} =
             prepare(scope, Map.put(args, "exclude_trip_ids", ["A01-F03"]))

    assert length(command.trip_ids) == 11
    assert excluded not in command.trip_ids
    assert hd(Enum.drop(prepared.summary.lines, 1)) =~ "4 trips keep their own text"
    assert result["trips_change"] == 11

    # A trip of another pattern in the same version is not a trip of this scope.
    other =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.a01.route.route_id,
        route_pattern_id: "A01-OTHER"
      })

    trip_fixture(context.organization.id, context.version.id, context.a01.route.route_id,
      trip_id: "A01-OTHER-1"
    )
    |> trip_pattern_metadata_fixture(%{
      route_pattern_id: other.route_pattern_id,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: "stops_mismatch"
    })

    before = stamps()

    for unknown <- ["NO-SUCH-TRIP", "A01-OTHER-1"] do
      assert {:tool_error, message} = prepare(scope, Map.put(args, "exclude_trip_ids", [unknown]))
      assert message =~ unknown
    end

    assert stamps() == before
  end

  test "a current text that is not the default, or a blank or unchanged new text, is refused",
       context do
    scope = pattern_scope(context)
    before = stamps()

    assert {:tool_error, message} =
             prepare(scope, %{"current_text" => "Uptown", "new_text" => "Central Station"})

    assert message =~ ~s("Downtown Terminal")

    assert {:tool_error, _message} =
             prepare(scope, %{"current_text" => "", "new_text" => "Central Station"})

    assert {:tool_error, message} =
             prepare(scope, %{"current_text" => "Downtown Terminal", "new_text" => " "})

    assert message =~ "blank"

    # The same text, even padded, is no change; a different case is a real change.
    assert {:tool_error, message} =
             prepare(scope, %{
               "current_text" => " Downtown Terminal",
               "new_text" => "Downtown Terminal "
             })

    assert message =~ "already the default"

    assert {:prepared, %{command: {:headsign_change, %{to: "downtown terminal"}}}, _result,
            _evidence} =
             prepare(scope, %{
               "current_text" => "Downtown Terminal",
               "new_text" => "downtown terminal"
             })

    # An empty new_text never reaches the pack: the declared schema refuses it.
    assert {:tool_error, message} =
             Dispatch.call(
               Headsigns,
               scope,
               "prepare_headsign_change",
               ~s({"current_text":"Downtown Terminal","new_text":""})
             )

    assert message =~ "new_text"
    assert stamps() == before
  end

  test "timing scope selects only that timing's trips under its own default", context do
    scope = pattern_scope(context, context.a01.peak)
    before = stamps()

    assert {:prepared, %{command: {:headsign_change, command}} = prepared, result, _evidence} =
             prepare(scope, %{"current_text" => "Peak Terminal", "new_text" => "Rush Terminal"})

    assert command.scope == {:timing, context.a01.peak.id}
    assert command.from == "Peak Terminal"

    assert command.trip_ids ==
             Enum.sort([trip_uuid(context, "A01-P1"), trip_uuid(context, "A01-P2")])

    assert prepared.summary.lines |> hd() == "2 trips change"
    refute Enum.any?(prepared.summary.lines, &(&1 =~ "own headsign are not changed"))
    assert result["scope"] == "timing"

    # The pattern's default is not this timing's default.
    assert {:tool_error, message} =
             prepare(scope, %{
               "current_text" => "Downtown Terminal",
               "new_text" => "Rush Terminal"
             })

    assert message =~ ~s("Peak Terminal")

    assert stamps() == before
  end

  test "a pattern with no default headsign renames the blank trips", context do
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.a01.route.route_id,
        route_pattern_id: "A01-BLANK",
        headsign: nil
      })

    timing = timed_pattern_fixture(pattern, %{name: "Plain"})

    blank =
      for index <- 1..2 do
        context.organization.id
        |> trip_fixture(context.version.id, context.a01.route.route_id,
          trip_id: "A01-BLANK-#{index}",
          trip_headsign: nil
        )
        |> trip_pattern_metadata_fixture(%{
          route_pattern_id: pattern.route_pattern_id,
          timed_pattern_id: timing.id,
          pattern_derivation_state: "linked"
        })
      end

    scope =
      helper_scope(
        context.organization,
        context.version,
        context.user,
        context.a01.route,
        pattern
      )

    assert {:prepared, %{command: {:headsign_change, command}}, _result, _evidence} =
             prepare(scope, %{"current_text" => "", "new_text" => "Harbor"})

    assert command.from == nil
    assert command.trip_ids == blank |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "100 followers prepare and 101 are refused with the Also-update guidance", context do
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.a01.route.route_id,
        route_pattern_id: "A03-P",
        headsign: "Harbor"
      })

    timing = timed_pattern_fixture(pattern, %{name: "All day"})

    for index <- 1..101 do
      context.organization.id
      |> trip_fixture(context.version.id, context.a01.route.route_id,
        trip_id: "A03-T#{String.pad_leading("#{index}", 3, "0")}",
        trip_headsign: "Harbor"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
    end

    scope =
      helper_scope(
        context.organization,
        context.version,
        context.user,
        context.a01.route,
        pattern
      )

    args = %{"current_text" => "Harbor", "new_text" => "Waterfront"}
    before = stamps()

    assert {:tool_error, message} = prepare(scope, args)
    assert message =~ "101 trips follow the default"
    assert message =~ "Also-update"

    assert {:prepared, %{command: {:headsign_change, command}}, _result, _evidence} =
             prepare(scope, Map.put(args, "exclude_trip_ids", ["A03-T101"]))

    assert length(command.trip_ids) == 100
    assert stamps() == before
  end

  test "the declared schema takes no scope argument and refuses a wrong type", context do
    scope = pattern_scope(context)

    assert {:tool_error, "Unexpected argument: pattern_id"} =
             Dispatch.call(
               Headsigns,
               scope,
               "prepare_headsign_change",
               ~s({"current_text":"a","new_text":"b","pattern_id":"x"})
             )

    assert {:tool_error, message} =
             Dispatch.call(
               Headsigns,
               scope,
               "prepare_headsign_change",
               ~s({"current_text":"a","new_text":"b","exclude_trip_ids":"A01-F01"})
             )

    assert message =~ "exclude_trip_ids"
  end

  # -- helpers ----------------------------------------------------------------

  defp prepare(scope, args),
    do: Dispatch.call(Headsigns, scope, "prepare_headsign_change", Jason.encode!(args))

  defp pattern_scope(context, timing \\ nil) do
    helper_scope(
      context.organization,
      context.version,
      context.user,
      context.a01.route,
      context.a01.pattern,
      timing
    )
  end

  defp trip_uuid(context, trip_id), do: Map.fetch!(context.a01.trips, trip_id).id

  defp follower_ids(context) do
    for(index <- 1..12, do: trip_uuid(context, "A01-F" <> String.pad_leading("#{index}", 2, "0")))
    |> Enum.sort()
  end

  # Every row a preparation could touch, with its update stamp and stored headsign,
  # plus the audit log: equal stamps before and after mean nothing was written.
  defp stamps do
    {Repo.all(from(t in Trip, order_by: t.id, select: {t.id, t.updated_at, t.trip_headsign})),
     Repo.all(from(p in RoutePattern, order_by: p.id, select: {p.id, p.updated_at, p.headsign})),
     Repo.all(from(t in TimedPattern, order_by: t.id, select: {t.id, t.updated_at, t.headsign})),
     Repo.aggregate(ChangeLog, :count)}
  end
end
