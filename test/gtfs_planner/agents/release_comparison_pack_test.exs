defmodule GtfsPlanner.Agents.ReleaseComparisonPackTest do
  @moduledoc """
  Merge evidence (EV-11, CL-11/FH-11) for the Release comparison pack through the
  real composition: two retained native ZIPs published through
  `ExportRuns`/`ArtifactStorage`, compared by `ReleaseComparison.start/4`, frozen
  by `AssistantContext.freeze/3` into the shared source-snapshot seam, then read
  through `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` ->
  `Packs.ReleaseComparison`. Only the OpenRouter HTTP boundary is doubled.

  Every expected value is counted by hand from the two fixtures in
  `GtfsPlanner.ReleaseComparisonFixtures`, which this suite shares with the helper
  suite and the browser seed. Window: Wed 2026-11-25 and Thu 2026-11-26.

    * Earlier file: route R1 runs trips T1 and T2 on the weekday service WEEK and
      route R2 runs trip U1 on WEEK, so 2 + 1 trips on each of the two dates.
    * Candidate file: R1 still runs T1 on WEEK, but T2 moves to service HOL, which
      the calendar exception removes on 2026-11-26, so R1 runs 2 trips on the
      25th and 1 on the 26th. Route R2 and trip U1 are renamed R2X and U1X with
      every other field equal, so R2/R2X runs 1 trip on each date. That is the
      loss (R1, one trip, the 26th) and the churn (two identifiers, no service).
    * The earlier file has one stop "Twin"; the candidate has two stops "Twin" at
      the same point, so that stop has two candidates and is unresolved.

  So the comparison measures 4 route/date units, an exact and scheduled delta of
  (2 + 1 + 1 + 1) - (2 + 2 + 1 + 1) = -1 and exactly one effective difference. It
  also states three structural changes - the route rename, the trip rename and
  trip T2 losing its 26 November service date - and three unresolved stop
  matches (the earlier stop with both candidates, and each candidate with the
  earlier stop), so it is incomplete.

  What these cases reject (FH-11) is a tool that starts computation, reads a
  receipt or the live version, a cursor that crosses a scope, and an unavailable
  comparison that still answers.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ReleaseComparisonFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.ReleaseComparison, as: Pack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.AssistantContext

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  @from "2026-11-25"
  @to "2026-11-26"
  @oversized "Too much data for one result. Narrow the request."

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug and
    # the SQL sandbox are both shared (`async: false`).
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()

    root =
      Path.join(
        System.tmp_dir!(),
        "release-comparison-pack-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    organization = organization_fixture()
    host = gtfs_version_fixture(organization.id)
    left_version = gtfs_version_fixture(organization.id)
    right_version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)

    base = %Scope{
      organization_id: organization.id,
      gtfs_version_id: host.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "release_comparison",
      version_name: host.name,
      resource_context: Scope.context({:version, host.id})
    }

    left = publish_run!(organization, left_version, left_zip())
    right = publish_run!(organization, right_version, right_zip(twins?: true))
    result = compare!(base, left, right)

    context = %{
      organization: organization,
      host: host,
      left_version: left_version,
      right_version: right_version,
      user: user,
      base: base,
      left: left,
      right: right,
      result: result
    }

    Map.put(context, :scope, frozen_scope(context, result))
  end

  describe "the shipped registration" do
    test "the registry names the pack and its four strict tools", context do
      assert Agents.packs()["release_comparison"] == Pack
      assert Pack.id() == "release_comparison"

      assert Enum.map(Pack.tools(), & &1.name) == [
               "resolve_export_comparison_scope",
               "get_export_comparison",
               "inspect_service_difference",
               "inspect_unresolved_entity_matches"
             ]

      assert Enum.all?(Pack.tools(), &(&1.parameters["additionalProperties"] == false))

      assert Pack.tools()
             |> Enum.map(&Map.keys(&1.parameters["properties"]))
             |> Enum.map(&Enum.sort/1) ==
               [[], [], ["cursor", "limit", "result_ref"], ["cursor", "limit"]]

      for tool <- Pack.tools(), do: assert(Pack.skill() =~ tool.name)

      # A conversation on a frozen comparison opens; the same page without one
      # opens too, and is refused where the pack runs, not at the registry.
      assert {:ok, session, snapshot} = Agents.open(context.scope)
      assert is_pid(session)
      assert snapshot.entries == []
    end

    test "an argument naming a tenant, run, date, path or new start is refused before the pack",
         context do
      for {tool, arguments} <- [
            {"get_export_comparison", ~s({"organization_id":"x"})},
            {"resolve_export_comparison_scope", ~s({"run_id":"x"})},
            {"inspect_service_difference", ~s({"gtfs_version_id":"x"})},
            {"inspect_service_difference", ~s({"from":"2026-11-25"})},
            {"inspect_service_difference", ~s({"path":"/tmp/network.zip"})},
            {"inspect_service_difference", ~s({"start":true})},
            {"inspect_unresolved_entity_matches", ~s({"result_ref":"R1/R1"})},
            {"inspect_unresolved_entity_matches", ~s({"left_run_id":"x"})}
          ] do
        assert {:tool_error, "Unexpected argument: " <> _key} =
                 Dispatch.call(Pack, context.scope, tool, arguments)
      end

      for arguments <- [
            ~s({"limit":0}),
            ~s({"limit":101}),
            ~s({"limit":"5"}),
            ~s({"limit":null}),
            ~s({"cursor":""}),
            ~s({"cursor":"#{String.duplicate("a", 513)}"}),
            ~s({"result_ref":"#{String.duplicate("a", 257)}"})
          ] do
        assert {:tool_error, _message} =
                 Dispatch.call(Pack, context.scope, "inspect_service_difference", arguments)
      end
    end
  end

  describe "the composed turn (Agents -> Session -> Dispatch -> pack)" do
    test "a summary question answers with the hand-counted totals and carries its evidence",
         context do
      before = run_receipts(context)

      expect_reply(tool_calls_reply([{"call_1", "get_export_comparison", "{}"}]))
      expect_reply(text_reply("One route lost a trip on Thanksgiving."))

      entry = run_turn(context.scope, "Did we lose any service?")

      assert entry.status == :done
      assert entry.text == "One route lost a trip on Thanksgiving."
      assert entry.activity == ["Read the comparison summary"]

      assert %{"totals" => totals, "counts" => counts, "completeness" => completeness} =
               tool_result()

      # (2 + 1 + 1 + 1) - (2 + 2 + 1 + 1) = -1 on both counts, over 4 units.
      assert totals["exact_count_delta"] == -1
      assert totals["scheduled_count_delta"] == -1
      assert totals["measured_units"] == 4
      assert totals["total_units"] == 4
      assert totals["reasons"] == []

      assert counts["route_date_units"] == 4
      assert counts["effective_changes"]["total"] == 1

      assert counts["effective_changes"]["by_kind"] == [
               %{"kind" => "count_changed", "count" => 1}
             ]

      assert counts["structural_changes"]["total"] == 3

      assert counts["structural_changes"]["by_change"] == [
               %{"entity" => "route", "change" => "identifier", "count" => 1},
               %{"entity" => "trip", "change" => "identifier", "count" => 1},
               %{"entity" => "trip", "change" => "service_dates", "count" => 1}
             ]

      assert counts["unresolved"]["total"] == 3
      assert counts["unknowns"]["total"] == 0

      # Complete would be a claim the unresolved stop does not support.
      assert completeness["status"] == "incomplete"
      assert completeness["reasons"] == ["unresolved_entity_matches"]

      assert [evidence] = entry.evidence
      assert evidence.kind == "export_comparison"
      assert evidence.total == 1
      assert evidence.total_label == "effective service differences"
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason =~ "some entities could not be paired"
      assert evidence.source_ref == "gtfs_release_comparison"
      assert evidence.digest == context.result.comparison.digest
      assert evidence.source_revision == nil
      assert evidence.scope.organization_id == context.organization.id
      assert evidence.scope.gtfs_version_id == context.host.id
      assert evidence.scope.identity == "version:#{context.host.id}"

      assert [%{kind: "export_comparison", id: digest}] = evidence.resources
      assert digest == context.result.comparison.digest

      assert Enum.find(evidence.facts, &(&1.label == "Exact departures")).value == "-1"
      assert Enum.find(evidence.facts, &(&1.label == "Scheduled trips")).value == "-1"

      assert Enum.find(evidence.facts, &(&1.label == "Route and date groups measured")).value ==
               "4 of 4"

      assert Enum.find(evidence.facts, &(&1.label == "Identifier and presence changes")).value ==
               "3"

      assert Enum.find(evidence.facts, &(&1.label == "Unresolved matches")).value == "3"

      # Asking claims nothing: no receipt moved and no export run changed.
      assert run_receipts(context) == before
    end

    test "loss and churn are separate records and neither tool starts anything", context do
      before = run_receipts(context)

      expect_reply(tool_calls_reply([{"call_1", "inspect_service_difference", "{}"}]))
      expect_reply(text_reply("R1 lost a trip; R2 was renamed."))

      entry = run_turn(context.scope, "What changed?")

      assert %{"records" => records, "true_total" => 4, "returned_count" => 4} = tool_result()

      assert [loss, route_churn, lost_date, trip_churn] = records

      # The one effective change: R1 runs 2 trips on the 25th and 1 on the 26th.
      assert loss["type"] == "effective"
      assert loss["kind"] == "count_changed"
      assert loss["date"] == "2026-11-26"
      assert loss["route_ids"] == %{"left" => "R1", "right" => "R1"}
      assert loss["counts"]["left"] == %{"scheduled_count" => 2, "exact_count" => 2}
      assert loss["counts"]["right"] == %{"scheduled_count" => 1, "exact_count" => 1}
      assert loss["delta"]["scheduled_count"] == -1
      assert loss["delta"]["exact_count"] == -1

      # The renames are structural, never service: same service, new identifier.
      assert route_churn["type"] == "structural"
      assert {route_churn["entity"], route_churn["change"]} == {"route", "identifier"}
      assert {route_churn["left"], route_churn["right"]} == {"R2", "R2X"}
      assert trip_churn["type"] == "structural"
      assert {trip_churn["entity"], trip_churn["change"]} == {"trip", "identifier"}
      assert {trip_churn["left"], trip_churn["right"]} == {"U1", "U1X"}

      # The same loss seen from the trip: T2 keeps its identifier but runs on one
      # fewer date, so this is service, not a rename.
      assert {lost_date["entity"], lost_date["change"], lost_date["id"]} ==
               {"trip", "service_dates", "T2"}

      assert lost_date["left"] == ["2026-11-25", "2026-11-26"]
      assert lost_date["right"] == ["2026-11-25"]

      assert [evidence] = entry.evidence
      assert evidence.kind == "export_comparison_differences"
      assert evidence.total == 4
      assert evidence.completeness == :incomplete
      assert [%{kind: "export_comparison"}] = evidence.resources

      assert run_receipts(context) == before
    end

    test "unresolved matches name the twin stops and their candidates, and are not a loss",
         context do
      expect_reply(tool_calls_reply([{"call_1", "inspect_unresolved_entity_matches", "{}"}]))
      expect_reply(text_reply("Two stops look alike."))

      entry = run_turn(context.scope, "Which stops could not be matched?")

      assert %{"records" => records, "true_total" => 3} = tool_result()
      assert Enum.all?(records, &(&1["entity"] == "stop"))
      assert Enum.all?(records, &(&1["reason"] == "ambiguous_signature"))

      # The earlier stop (row 4) names both candidates; each candidate (rows 4
      # and 5 of the candidate file) names the one earlier stop it could be.
      assert [one, two, earlier] = records
      assert earlier["left_ref"] == %{"file" => "stops.txt", "row" => 4}
      assert earlier["right_ref"] == nil
      assert length(earlier["candidates"]) == 2
      assert {one["right_ref"]["row"], two["right_ref"]["row"]} == {4, 5}
      assert one["candidates"] == [%{"file" => "stops.txt", "row" => 4}]

      assert [evidence] = entry.evidence
      assert evidence.kind == "export_comparison_unresolved"
      assert evidence.total == 3
      assert evidence.completeness == :incomplete
    end

    test "the scope tool names what was compared without run or version identifiers",
         context do
      assert {:ok, result, evidence} =
               Dispatch.call(Pack, context.scope, "resolve_export_comparison_scope", "{}")

      assert result["window"] == %{"from" => @from, "to" => @to}
      assert result["route_pairs"] == ["R1/R1", "R2/R2X"]
      assert result["dates"] == [@from, @to]
      assert result["narrowed"] == false
      assert result["digest"] == context.result.comparison.digest

      assert [left, right] = result["artifacts"]
      assert {left["label"], right["label"]} == {"Earlier export", "Candidate export"}
      assert left["sha256"] == context.left.artifact_sha256
      assert right["sha256"] == context.right.artifact_sha256
      assert left["profile"] == "full"

      encoded = Jason.encode!(result)
      refute encoded =~ context.left.id
      refute encoded =~ context.left_version.id
      refute encoded =~ context.host.id

      assert evidence.kind == "export_comparison_scope"
      assert evidence.total == 2

      assert Enum.find(evidence.facts, &(&1.label == "Compared dates")).value ==
               "#{@from} to #{@to}"
    end

    test "a narrowed context answers from its own rows and a different digest", context do
      narrowed =
        frozen_scope(context, context.result, %{
          route_pair_keys: ["R2/R2X"],
          dates: [~D[2026-11-25]]
        })

      assert {:ok, result, evidence} =
               Dispatch.call(Pack, narrowed, "resolve_export_comparison_scope", "{}")

      assert result["narrowed"] == true
      assert result["route_pairs"] == ["R2/R2X"]
      assert result["dates"] == [@from]
      assert result["digest"] != context.result.comparison.digest
      assert result["result_digest"] == context.result.comparison.digest
      assert hd(evidence.resources).id == result["digest"]

      # R1's loss is out of scope, so it is neither listed nor counted, and the
      # scoped total is the whole selection's 0 (1 trip against 1 on the 25th).
      assert {:ok, summary, _evidence} =
               Dispatch.call(Pack, narrowed, "get_export_comparison", "{}")

      assert summary["totals"]["exact_count_delta"] == 0
      assert summary["counts"]["effective_changes"]["total"] == 0
      assert summary["selection"]["narrowed"] == true

      # What the narrowing left out stays disclosed.
      assert Enum.any?(summary["exclusions"], &(&1["reason"] == "narrowed_out_of_scope"))
    end
  end

  describe "bounded pages" do
    test "one-row pages walk the whole list once and keep the true total and digest", context do
      {:ok, whole, _evidence} =
        Dispatch.call(Pack, context.scope, "inspect_service_difference", ~s({"limit":100}))

      assert whole["true_total"] == 4
      assert whole["next_cursor"] == nil
      digest = context.result.comparison.digest

      {pages, cursors} = walk(context.scope, "inspect_service_difference", %{"limit" => 1})

      assert length(pages) == 4
      assert length(cursors) == 3
      assert Enum.all?(pages, &(&1["true_total"] == 4 and &1["digest"] == digest))
      assert Enum.all?(pages, &(&1["returned_count"] == 1))
      assert Enum.flat_map(pages, & &1["records"]) == whole["records"]
      assert List.last(pages)["next_cursor"] == nil

      # The cursor is URL-safe base64 of exactly the digest, collection and offset.
      assert [first | _] = cursors

      assert first |> Base.url_decode64!(padding: false) |> Jason.decode!() == %{
               "selected_digest" => digest,
               "collection" => "differences",
               "offset" => 1
             }
    end

    test "a result_ref limits the page to one route pair and only a listed pair is known",
         context do
      assert {:ok, loss, _} =
               Dispatch.call(
                 Pack,
                 context.scope,
                 "inspect_service_difference",
                 ~s({"result_ref":"R1/R1"})
               )

      assert loss["true_total"] == 1
      assert [%{"type" => "effective", "date" => "2026-11-26"}] = loss["records"]
      assert loss["selection"]["result_ref"] == "R1/R1"

      # The renamed route's own identifier change belongs to its pair; the trip
      # rename names no route, so it is not attributed to one.
      assert {:ok, churn, _} =
               Dispatch.call(
                 Pack,
                 context.scope,
                 "inspect_service_difference",
                 ~s({"result_ref":"R2/R2X"})
               )

      assert [%{"type" => "structural", "entity" => "route", "left" => "R2"}] = churn["records"]

      for forged <- ["R9/R9", "R1/R2X", "../../etc/passwd", "r1/r1", "?/?"] do
        assert {:tool_error, message} =
                 Dispatch.call(
                   Pack,
                   context.scope,
                   "inspect_service_difference",
                   Jason.encode!(%{"result_ref" => forged})
                 )

        assert message =~ "not a route pair in this comparison"
        refute message =~ forged
      end
    end

    test "a cursor from another scope, tool, offset or encoding is refused", context do
      {:ok, first, _} =
        Dispatch.call(Pack, context.scope, "inspect_service_difference", ~s({"limit":1}))

      cursor = first["next_cursor"]
      assert is_binary(cursor)

      narrowed =
        frozen_scope(context, context.result, %{
          route_pair_keys: ["R1/R1", "R2/R2X"],
          dates: [~D[2026-11-25], ~D[2026-11-26]]
        })

      # Another narrowing is another digest, so this cursor is stale there.
      assert {:tool_error, message} =
               Dispatch.call(
                 Pack,
                 narrowed,
                 "inspect_service_difference",
                 Jason.encode!(%{"cursor" => cursor})
               )

      assert message =~ "does not belong to this comparison"

      forged = fn body ->
        body |> Jason.encode!() |> Base.url_encode64(padding: false)
      end

      digest = context.result.comparison.digest

      for bad <- [
            "not-a-cursor",
            Base.url_encode64("{", padding: false),
            forged.(%{"selected_digest" => digest, "collection" => "differences", "offset" => 0}),
            forged.(%{"selected_digest" => digest, "collection" => "differences", "offset" => 4}),
            forged.(%{
              "selected_digest" => digest,
              "collection" => "differences",
              "offset" => -1
            }),
            forged.(%{
              "selected_digest" => digest,
              "collection" => "differences",
              "offset" => "1"
            }),
            forged.(%{
              "selected_digest" => digest,
              "collection" => "differences",
              "offset" => 1.5
            }),
            forged.(%{"selected_digest" => digest, "collection" => "unresolved", "offset" => 1}),
            forged.(%{
              "selected_digest" => String.duplicate("a", 64),
              "collection" => "differences",
              "offset" => 1
            }),
            forged.(%{
              "selected_digest" => digest,
              "collection" => "differences",
              "offset" => 1,
              "run_id" => "x"
            }),
            # A cursor issued under one result_ref is not valid under another.
            forged.(%{
              "selected_digest" => digest,
              "collection" => "differences:R1/R1",
              "offset" => 1
            })
          ] do
        assert {:tool_error, message} =
                 Dispatch.call(
                   Pack,
                   context.scope,
                   "inspect_service_difference",
                   Jason.encode!(%{"cursor" => bad})
                 )

        assert message =~ "does not belong to this comparison"
      end

      # The tool that issued a cursor is the one that may continue it.
      assert {:tool_error, _message} =
               Dispatch.call(
                 Pack,
                 context.scope,
                 "inspect_unresolved_entity_matches",
                 Jason.encode!(%{"cursor" => cursor})
               )
    end

    test "an empty completed page is a valid zero", context do
      quiet =
        readmit(context, fn payload ->
          payload
          |> put_in(["changes", "effective"], [])
          |> put_in(["changes", "structural"], [])
        end)

      assert {:ok, page, evidence} =
               Dispatch.call(Pack, quiet, "inspect_service_difference", "{}")

      assert page["records"] == []
      assert page["true_total"] == 0
      assert page["returned_count"] == 0
      assert page["next_cursor"] == nil
      assert evidence.total == 0
    end

    test "a narrowed page keeps the structural changes that name no route", context do
      # Narrowed to R1 on the 25th, where both files run 2 trips: no effective
      # difference is in scope. The trip changes carry no route, so they stay,
      # while the rename of route R2 is not R1's and does not.
      narrowed =
        frozen_scope(context, context.result, %{
          route_pair_keys: ["R1/R1"],
          dates: [~D[2026-11-25]]
        })

      assert {:ok, page, evidence} =
               Dispatch.call(Pack, narrowed, "inspect_service_difference", "{}")

      assert Enum.map(page["records"], &{&1["type"], &1["entity"], &1["id"]}) == [
               {"structural", "trip", "T2"},
               {"structural", "trip", "U1"}
             ]

      assert page["true_total"] == 2
      assert evidence.total == 2

      # Unresolved matches are never narrowed away, so all three stay disclosed.
      assert {:ok, unresolved, _evidence} =
               Dispatch.call(Pack, narrowed, "inspect_unresolved_entity_matches", "{}")

      assert unresolved["true_total"] == 3
    end

    test "a comparison without unresolved matches reads complete and a no-difference page is zero",
         context do
      scope = clean_scope(context)

      assert {:ok, unresolved, evidence} =
               Dispatch.call(Pack, scope, "inspect_unresolved_entity_matches", "{}")

      assert unresolved["records"] == []
      assert unresolved["true_total"] == 0
      assert unresolved["completeness"] == %{"status" => "complete", "reasons" => []}
      assert evidence.completeness == :complete
      assert evidence.completeness_reason == nil

      assert {:ok, summary, evidence} = Dispatch.call(Pack, scope, "get_export_comparison", "{}")
      assert summary["completeness"]["status"] == "complete"
      assert evidence.completeness == :complete
    end

    test "a page that is only part of the list is never shown as complete", context do
      scope = clean_scope(context)

      assert {:ok, %{"true_total" => 4, "next_cursor" => cursor}, evidence} =
               Dispatch.call(Pack, scope, "inspect_service_difference", ~s({"limit":2}))

      assert is_binary(cursor)
      assert evidence.total == 4
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason == "Showing rows 1 to 2 of 4."
    end

    test "a page whose rows and evidence pass 32768 bytes is refused whole, never truncated",
         context do
      scope = bloated_scope(context)

      assert {:tool_error, @oversized} =
               Dispatch.call(Pack, scope, "inspect_service_difference", ~s({"limit":100}))

      # A smaller page of the same list is the narrowing the refusal asks for.
      assert {:ok, page, _evidence} =
               Dispatch.call(Pack, scope, "inspect_service_difference", ~s({"limit":10}))

      assert page["returned_count"] == 10
      assert page["true_total"] > 10
      assert is_binary(page["next_cursor"])
    end

    test "the unknown-row examples are capped while the true total is not", context do
      scope =
        readmit(context, fn payload ->
          unknowns =
            for index <- 1..12 do
              %{
                "side" => "left",
                "layer" => "projection",
                "entity" => nil,
                "entity_id" => "E#{index}",
                "field" => "end_date",
                "reason" => "malformed_date",
                "detail" => "end_date could not be read from the selected bytes",
                "source" => %{"file" => "calendar.txt", "row" => index + 1}
              }
            end

          Map.put(payload, "unknowns", unknowns)
        end)

      assert {:ok, summary, evidence} = Dispatch.call(Pack, scope, "get_export_comparison", "{}")

      assert summary["counts"]["unknowns"]["total"] == 12
      assert length(summary["counts"]["unknowns"]["examples"]) == 10

      assert summary["counts"]["unknowns"]["by_reason"] == [
               %{
                 "side" => "left",
                 "layer" => "projection",
                 "reason" => "malformed_date",
                 "count" => 12
               }
             ]

      assert Enum.find(evidence.facts, &(&1.label == "Unknown rows")).value == "12"
    end

    test "a suppressed total keeps its reasons and is never shown as zero", context do
      scope =
        readmit(context, fn payload ->
          payload
          |> put_in(["totals", "exact_count_delta"], nil)
          |> put_in(["totals", "scheduled_count_delta"], nil)
          |> put_in(["totals", "reasons"], ["incomplete_counts", "unmapped_route"])
        end)

      assert {:ok, summary, evidence} = Dispatch.call(Pack, scope, "get_export_comparison", "{}")

      assert summary["totals"]["exact_count_delta"] == nil
      assert summary["totals"]["reasons"] == ["incomplete_counts", "unmapped_route"]

      fact = Enum.find(evidence.facts, &(&1.label == "Exact departures")).value
      assert fact =~ "not measured"
      assert fact =~ "frequency windows rather than exact departures"
      assert fact =~ "no proven match in the other"
      refute fact =~ "no change"
    end
  end

  describe "an unavailable comparison" do
    test "a conversation with no admitted comparison is unavailable and sends no request",
         context do
      scope = %{context.base | resource_context: Scope.context({:version, context.host.id})}

      assert {:error, :unavailable} =
               Dispatch.call(Pack, scope, "get_export_comparison", "{}")

      assert Pack.authorize_context(scope) == {:error, :unavailable}

      # No request is stubbed: a conversation with no comparison must never reach
      # the provider, so `verify_on_exit!` is the assertion.
      assert {:error, :unavailable} = Agents.open(scope)
      refute_received {:model_request, _request}
    end

    test "a snapshot of another kind or schema is not a comparison here", context do
      payload = context.scope |> Scope.source_snapshot() |> Map.fetch!(:payload)

      for snapshot <- [
            %{kind: "gtfs_timetable_source", payload: payload},
            %{kind: "release_comparison", payload: Map.put(payload, "schema_version", 2)},
            %{kind: "release_comparison", payload: Map.delete(payload, "totals")},
            %{kind: "release_comparison", payload: Map.put(payload, "selected_digest", "short")},
            %{kind: "release_comparison", payload: Map.put(payload, "expires_at", "soon")}
          ] do
        {:ok, resource_context} =
          Scope.with_source_snapshot(Scope.context({:version, context.host.id}), snapshot)

        scope = %{context.base | resource_context: resource_context}
        assert Pack.authorize_context(scope) == {:error, :unavailable}
        assert {:error, :unavailable} = Dispatch.call(Pack, scope, "get_export_comparison", "{}")
      end
    end

    test "an expired comparison is refused at open and at every tool, with no request",
         context do
      assert Pack.authorize_context(context.scope) == :ok

      # The earlier of the two artifact expiries is the copy's own expiry, so a
      # comparison whose earlier file has expired reads as gone.
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      expired = frozen_scope(context, put_in(context.result.left.expires_at, past).result)

      assert Pack.authorize_context(expired) == {:error, :unavailable}
      assert {:error, :unavailable} = Dispatch.call(Pack, expired, "get_export_comparison", "{}")
      assert {:error, :unavailable} = Agents.open(expired)
      refute_received {:model_request, _request}
    end

    test "a deleted source version ends the conversation before the next tool is read",
         context do
      # The first reply asks for a tool; the source version is deleted before that
      # tool runs, so the delivery is refused and nothing is read.
      expect_reply(tool_calls_reply([{"call_1", "get_export_comparison", "{}"}]), fn ->
        Repo.delete!(context.left_version)
      end)

      assert {:ok, session, _snapshot} = Agents.open(context.scope)
      monitor = Process.monitor(session)
      assert :ok = Agents.send_message(session, "What changed?")

      assert_receive {:agent_event, ^session, {:status, :unavailable}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 5_000

      # The tool never ran, so the model was never handed a result.
      assert_received {:model_request, %{"messages" => messages}}
      refute Enum.any?(messages, &(&1["role"] == "tool"))
      refute_received {:model_request, _request}

      assert {:error, :ended} = Agents.send_message(session, "Try again")
    end

    test "a deleted candidate version is refused", context do
      assert Pack.authorize_context(context.scope) == :ok

      Repo.delete!(context.right_version)

      assert Pack.authorize_context(context.scope) == {:error, :unavailable}

      assert {:error, :unavailable} =
               Dispatch.call(Pack, context.scope, "get_export_comparison", "{}")
    end

    test "a deleted host version is refused", context do
      assert {:ok, session, _snapshot} = Agents.open(context.scope)

      Repo.delete!(context.host)

      assert {:error, :unavailable} =
               Dispatch.call(Pack, context.scope, "get_export_comparison", "{}")

      assert {:error, :unavailable} = Agents.send_message(session, "What changed?")
      refute_received {:model_request, _request}
    end

    test "a membership withdrawn after the comparison ended the helper's access", context do
      assert {:ok, session, _snapshot} = Agents.open(context.scope)

      Repo.update_all(
        from(m in UserOrgMembership, where: m.user_id == ^context.user.id),
        set: [deactivated_at: DateTime.utc_now()]
      )

      assert {:error, :forbidden} =
               Dispatch.call(Pack, context.scope, "get_export_comparison", "{}")

      assert {:error, :forbidden} = Agents.send_message(session, "What changed?")
      refute_received {:model_request, _request}
    end

    test "a page bound to another host version is not this page's comparison", context do
      other_host = gtfs_version_fixture(context.organization.id)

      scope = %{
        context.scope
        | gtfs_version_id: other_host.id,
          resource_context: %{
            context.scope.resource_context
            | identity: {:version, other_host.id}
          }
      }

      assert Pack.authorize_context(scope) == :ok

      route_identity = %{
        scope
        | resource_context: %{scope.resource_context | identity: {:route, other_host.id}}
      }

      assert Pack.authorize_context(route_identity) == {:error, :unavailable}
    end
  end

  ## Fixtures

  # The comparison is the production one: the coordinator claims both retained
  # artifacts, reads their bytes and compares them, and the delivered result is
  # what the page would freeze.
  defp compare!(scope, left, right) do
    ref = make_ref()

    params = %{
      "left_run_id" => left.id,
      "right_run_id" => right.id,
      "left_version_id" => left.gtfs_version_id,
      "right_version_id" => right.gtfs_version_id,
      "from" => @from,
      "to" => @to
    }

    assert {:ok, pid} = ReleaseComparison.start(scope, params, self(), ref)
    assert_receive {:release_comparison, ^ref, {:ok, result}}, 60_000

    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000

    result
  end

  # The same two retained files without the twin stop: every entity pairs, so
  # the comparison is complete and has one loss and two identifier changes.
  defp clean_scope(context) do
    right =
      publish_run!(
        context.organization,
        gtfs_version_fixture(context.organization.id),
        right_zip(twins?: false)
      )

    left =
      publish_run!(
        context.organization,
        gtfs_version_fixture(context.organization.id),
        left_zip()
      )

    frozen_scope(context, compare!(context.base, left, right))
  end

  defp frozen_scope(context, result, selection \\ :all) do
    assert {:ok, resource_context} =
             AssistantContext.freeze(context.base.resource_context, result, selection)

    %{context.base | resource_context: resource_context}
  end

  # Re-admits an edited copy of the real payload through the same shared seam,
  # so a case can shape one field the fixture cannot produce without rebuilding
  # the artifacts, and still reads it exactly the way a conversation does.
  defp readmit(context, fun) do
    payload = context.scope |> Scope.source_snapshot() |> Map.fetch!(:payload)

    assert {:ok, resource_context} =
             Scope.with_source_snapshot(Scope.context({:version, context.host.id}), %{
               kind: "release_comparison",
               payload: fun.(payload)
             })

    %{context.base | resource_context: resource_context}
  end

  # More than one full page of effective differences: the real row repeated until
  # the list is larger than the 32768-byte result ceiling but the whole context
  # is still inside the shared 65536-byte admission.
  defp bloated_scope(context) do
    readmit(context, fn payload ->
      [row | _] = payload["changes"]["effective"]
      row_bytes = row |> Jason.encode!() |> byte_size()
      copies = div(44_000, row_bytes) + 1
      put_in(payload, ["changes", "effective"], List.duplicate(row, copies))
    end)
  end

  defp walk(scope, tool, args, pages \\ [], cursors \\ []) do
    assert {:ok, page, _evidence} = Dispatch.call(Pack, scope, tool, Jason.encode!(args))
    pages = pages ++ [page]

    case page["next_cursor"] do
      nil -> {pages, cursors}
      cursor -> walk(scope, tool, Map.put(args, "cursor", cursor), pages, cursors ++ [cursor])
    end
  end

  defp run_receipts(context) do
    for run <- [context.left, context.right] do
      Repo.get!(Run, run.id)
      |> Map.take([
        :state,
        :download_count,
        :download_claimed_until,
        :last_downloaded_at,
        :artifact_sha256,
        :artifact_size_bytes,
        :artifact_expires_at
      ])
    end
  end

  ## Provider boundary and process hygiene

  defp run_turn(scope, text) do
    assert {:ok, pid, _snapshot} = Agents.open(scope)
    assert :ok = Agents.send_message(pid, text)
    await_settled(pid)
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working, do: await_settled(pid), else: entry
  end

  # The tool message the turn sent back to the provider is the pack's own result,
  # decoded, so the assertions read what the model read.
  defp tool_result do
    assert_receive {:model_request, request}, 5_000

    case Enum.filter(request["messages"] || [], &(&1["role"] == "tool")) do
      [] -> tool_result()
      messages -> messages |> List.last() |> Map.fetch!("content") |> Jason.decode!()
    end
  end

  defp expect_reply(payload, before \\ fn -> :ok end) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})
      before.()

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)
  end

  defp text_reply(content) do
    %{
      "id" => "gen-test-text",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 16, "cost" => 0.0}
    }
  end

  defp tool_calls_reply(calls) do
    %{
      "id" => "gen-test-tool",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "tool_calls",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" =>
              Enum.map(calls, fn {id, name, arguments} ->
                %{
                  "id" => id,
                  "type" => "function",
                  "function" => %{"name" => name, "arguments" => arguments}
                }
              end)
          }
        }
      ],
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 32, "cost" => 0.0}
    }
  end

  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
  end
end
