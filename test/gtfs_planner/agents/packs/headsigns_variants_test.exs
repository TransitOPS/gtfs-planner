defmodule GtfsPlanner.Agents.Packs.HeadsignsVariantsTest do
  @moduledoc """
  Merge evidence (EV-2) for `find_headsign_variants`.

  Expected rows are hand-written from the A01 fixture in
  `GtfsPlanner.HeadsignHelperFixtures` and from a 60-trip pattern built here; the
  pack is reached through `Dispatch`, the same fence a model's call crosses.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.HeadsignHelperFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Headsigns
  alias GtfsPlanner.Agents.Scope

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)

    %{
      organization: organization,
      version: version,
      user: user,
      a01: a01_fixture(organization.id, version.id)
    }
  end

  test "lists the differing groups, likely typo first, with next-block routes", context do
    assert {:ok, result, evidence} = variants(scope(context, context.a01), %{})

    assert {result["group_count"], result["trip_count"], result["offset"]} == {2, 3, 0}
    assert {result["returned"], result["next_offset"]} == {3, nil}

    assert Enum.map(result["trips"], &Map.take(&1, ~w(trip_id group_value group_kind departure))) ==
             [
               %{
                 "trip_id" => "A01-C1",
                 "group_value" => "downtown terminal",
                 "group_kind" => "case_or_spacing",
                 "departure" => "19:00"
               },
               %{
                 "trip_id" => "A01-I1",
                 "group_value" => "Downtown Terminal, continues to Airport",
                 "group_kind" => "interline",
                 "departure" => "18:00"
               },
               %{
                 "trip_id" => "A01-I2",
                 "group_value" => "Downtown Terminal, continues to Airport",
                 "group_kind" => "interline",
                 "departure" => "18:30"
               }
             ]

    assert Enum.map(result["trips"], & &1["next_block_route"]) == [nil, "2", "2"]

    # The Off-peak timing's second stop carries the stop headsign `Airport`, so
    # every differing trip on that timing names that stop as where riders see it change.
    assert Enum.map(result["trips"], & &1["mid_trip_change"]) ==
             List.duplicate("Airport Plaza", 3)

    assert Enum.all?(
             result["trips"],
             &(&1["timing_name"] == "Off-peak" and &1["custom"] == false)
           )

    assert evidence.kind == "headsign_variants"
    assert evidence.total == 3
    assert evidence.total_label == "trips in the listed groups"
    assert evidence.completeness == :complete
    assert evidence.scope.identity == "route:#{context.a01.route.id}"
  end

  test "the default's own text lists the twelve followers in departure order", context do
    scope = scope(context, context.a01)
    expected = for index <- 1..12, do: "A01-F" <> String.pad_leading("#{index}", 2, "0")

    for value <- ["Downtown Terminal", "  Downtown Terminal "] do
      assert {:ok, result, _evidence} = variants(scope, %{"value" => value})
      assert {result["group_count"], result["trip_count"], result["returned"]} == {1, 12, 12}
      assert result["next_offset"] == nil
      assert Enum.map(result["trips"], & &1["trip_id"]) == expected
      assert Enum.all?(result["trips"], &(&1["group_kind"] == "follows"))
      assert Enum.all?(result["trips"], &(&1["group_value"] == "Downtown Terminal"))
      assert Enum.all?(result["trips"], &is_nil(&1["next_block_route"]))
    end
  end

  test "a value naming one differing group, or none, narrows the page", context do
    scope = scope(context, context.a01)

    assert {:ok, result, _evidence} = variants(scope, %{"value" => "downtown terminal"})
    assert Enum.map(result["trips"], & &1["trip_id"]) == ["A01-C1"]

    assert {:ok, result, evidence} = variants(scope, %{"value" => "Nowhere Plaza"})
    assert {result["group_count"], result["trip_count"], result["returned"]} == {0, 0, 0}
    assert {result["trips"], result["next_offset"]} == {[], nil}
    assert evidence.completeness == :complete
  end

  test "a 60-trip default pages 25, 25 and 10 without repeating a trip", context do
    {pattern, expected_ids} = sixty_trip_pattern(context)
    scope = scope_for(context, context.a01.route, pattern)

    pages =
      for offset <- [0, 25, 50] do
        assert {:ok, result, evidence} =
                 variants(scope, %{"value" => "Harbor", "offset" => offset})

        {result, evidence}
      end

    assert Enum.map(pages, fn {result, _} -> result["returned"] end) == [25, 25, 10]
    assert Enum.map(pages, fn {result, _} -> result["next_offset"] end) == [25, 50, nil]
    assert Enum.map(pages, fn {result, _} -> result["trip_count"] end) == [60, 60, 60]

    assert Enum.map(pages, fn {_, evidence} -> evidence.completeness end) ==
             [:incomplete, :incomplete, :complete]

    assert {_, first_evidence} = hd(pages)
    assert first_evidence.completeness_reason == "Showing 25 of 60"

    paged_ids =
      Enum.flat_map(pages, fn {result, _} -> Enum.map(result["trips"], & &1["trip_id"]) end)

    assert paged_ids == expected_ids
  end

  test "an offset past the end returns no trips and the same totals", context do
    scope = scope(context, context.a01)

    assert {:ok, result, evidence} = variants(scope, %{"offset" => 100})
    assert {result["trip_count"], result["returned"], result["next_offset"]} == {3, 0, nil}
    assert result["trips"] == []
    assert evidence.completeness == :complete
  end

  test "the declared schema refuses an out-of-range offset before the pack runs", context do
    scope = scope(context, context.a01)

    for offset <- [-1, 100_001] do
      assert {:tool_error, message} =
               Dispatch.call(Headsigns, scope, "find_headsign_variants", ~s({"offset":#{offset}}))

      assert message =~ "offset"
    end

    assert {:tool_error, "Unexpected argument: pattern_id"} =
             Dispatch.call(Headsigns, scope, "find_headsign_variants", ~s({"pattern_id":"x"}))
  end

  test "timing scope lists only that timing's trips", context do
    scope = scope(context, context.a01, context.a01.peak)

    assert {:ok, result, _evidence} = variants(scope, %{"value" => "Peak Terminal"})
    assert Enum.map(result["trips"], & &1["trip_id"]) == ["A01-P1", "A01-P2"]
    assert Enum.all?(result["trips"], &(&1["timing_name"] == "Peak"))

    assert {:ok, result, _evidence} = variants(scope, %{})
    assert result["trips"] == []
  end

  # -- helpers ----------------------------------------------------------------

  defp variants(scope, args),
    do: Dispatch.call(Headsigns, scope, "find_headsign_variants", Jason.encode!(args))

  defp scope(context, a01, timing \\ nil),
    do: scope_for(context, a01.route, a01.pattern, timing)

  defp scope_for(context, route, pattern, timing \\ nil) do
    {:ok, admitted} =
      Scope.with_source_snapshot(Scope.context({:route, route.id}), %{
        kind: "headsign_scope",
        payload: %{
          "schema_version" => 1,
          "pattern_id" => pattern.id,
          "timing_id" => timing && timing.id
        }
      })

    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "headsigns",
      version_name: context.version.name,
      resource_context: admitted
    }
  end

  # Sixty trips on one default, ten minutes apart from 05:00, so departure order is
  # the trip number.
  defp sixty_trip_pattern(context) do
    bundle =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.a01.route.route_id,
        route_pattern_id: "A02-P",
        headsign: "Harbor",
        timing_name: "All day",
        stops: [{"A01-S1", 0, 0, 1}, {"A01-S2", 300, 300, 1}]
      })

    ids =
      for index <- 1..60 do
        trip_id = "A02-T" <> String.pad_leading("#{index}", 2, "0")
        minutes = 5 * 60 + (index - 1) * 10

        schedule_trip_fixture(context.organization.id, context.version.id, "R1", bundle, %{
          service_id: "A01-WK",
          trip_id: trip_id,
          trip_headsign: "Harbor",
          start_time:
            "#{String.pad_leading("#{div(minutes, 60)}", 2, "0")}:#{String.pad_leading("#{rem(minutes, 60)}", 2, "0")}:00"
        })

        trip_id
      end

    {bundle.pattern, ids}
  end
end
