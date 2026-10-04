defmodule GtfsPlanner.Gtfs.ReleaseComparison.AssistantContextTest do
  @moduledoc """
  Focused evidence for CL-10/FH-10: the finished native comparison is frozen
  into the AI04 shared source-snapshot contract, and only the exact selection
  the editor is looking at.

  Every case drives production code end to end for the result itself: the two
  artifacts are ZIPs published through `ExportRuns`/`ArtifactStorage`, read
  through the real reader, projected by the real projection and compared by
  `Compare.run/3`. Nothing is manufactured and no adapter is injected. Only the
  byte-boundary case varies a scalar the server already holds - the recorded
  artifact digest - so the payload can be walked up to the shared ceiling one
  byte at a time.

  What these cases reject (FH-10) is measuring the payload instead of the whole
  context, a narrowed scope silently reusing the complete result's totals, a
  refused source attaching a truncated summary, and any p id, handle, path or
  URL travelling into the admitted copy.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.AssistantContext
  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare
  alias GtfsPlanner.Gtfs.ReleaseComparison.Projection
  alias GtfsPlanner.Gtfs.ReleaseComparison.Reader

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ReleaseComparisonFixtures, only: [frequency_zip: 1]
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  @date "2026-11-23"
  @window %{from: Date.from_iso8601!(@date), to: Date.from_iso8601!(@date)}
  @max_context_bytes 65_536

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "release-comparison-context-#{System.unique_integer([:positive])}"
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
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "release_comparison",
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }

    %{organization: organization, version: version, scope: scope}
  end

  describe "freeze/3 over the complete comparison" do
    test "admits the whole context through the shared seam and states exactly what it compared",
         context do
      %{scope: scope} = context
      result = result(context, trips: 2, other_trips: 1)

      assert {:ok, admitted} = AssistantContext.freeze(scope.resource_context, result, :all)

      assert %{kind: "release_comparison", payload: payload, digest: digest} =
               admitted.source_snapshot

      assert payload["schema_version"] == 1
      assert payload["source_ref"] == result.fingerprint
      assert payload["result_digest"] == result.comparison.digest
      assert payload["selected_digest"] == result.comparison.digest
      assert payload["window"] == %{"from" => @date, "to" => @date}
      assert payload["scope"] == nil

      # The digest is the shared seam's own hash of the admitted envelope. This
      # package supplies none, and the admitted payload carries its own digest
      # field as content without it standing in for the envelope's.
      assert byte_size(digest) == 64
      refute Map.has_key?(payload, "digest")

      # Both artifacts are named by what the native export recorded, and the
      # retention copied is the earlier of the two expiries - never a recomputed
      # or extended one.
      assert [left, right] = payload["artifacts"]
      assert left["side"] == "left"
      assert right["side"] == "right"

      for artifact <- [left, right] do
        assert artifact["run_id"]
        assert artifact["version_id"]
        assert byte_size(artifact["sha256"]) == 64
        assert is_integer(artifact["size"]) and artifact["size"] > 0
        assert artifact["profile"] == "full"
        assert artifact["expires_at"]
        assert is_boolean(artifact["estimate_missing_times"])
      end

      assert payload["expires_at"] == Enum.min([left["expires_at"], right["expires_at"]])

      # The rows, the changes and the uncertainty all travel, and the suppressed
      # total keeps the reason it was suppressed rather than reading as no
      # difference.
      assert [%{"date" => @date} | _] = payload["groups"]
      assert is_list(payload["changes"]["effective"])
      assert is_list(payload["changes"]["structural"])
      assert is_list(payload["unresolved"])
      assert is_list(payload["unknowns"])
      assert payload["completeness"]["status"] in ["complete", "incomplete"]

      if payload["totals"]["exact_count_delta"] == nil do
        assert payload["totals"]["reasons"] != []
      end

      # The complete selection is every route pair and every date proved.
      assert payload["selected_route_pairs"] == ["R1/R1"]
      assert payload["selected_dates"] == [@date]

      # Row references are the physical GTFS member and row: evidence a person
      # can open, never a path on this server.
      # The earlier file states two trips, so its one group's rows are trips.txt
      # rows 2 and 3; the candidate states one, so its single row is row 2. Rows
      # are 1-based and the header is row 1, which no ref ever names.
      group = hd(payload["groups"])

      assert group["left"]["source_refs"] == [
               %{"file" => "trips.txt", "row" => 2},
               %{"file" => "trips.txt", "row" => 3}
             ]

      assert group["right"]["source_refs"] == [%{"file" => "trips.txt", "row" => 2}]

      # The counts the comparison proved: two trips against one.
      assert group["left"]["scheduled_count"] == 2
      assert group["right"]["scheduled_count"] == 1
      assert group["delta"]["exact_count"] == -1
      assert payload["totals"]["exact_count_delta"] == -1

      # The admitted copy holds no host handle of any kind.
      assert_no_handles(payload)
    end

    test "is byte-bounded by the whole context and refuses over it without attaching",
         context do
      %{scope: scope} = context
      base = result(context, trips: 2, other_trips: 1)

      # The recorded artifact digest is a server-held scalar, so lengthening it
      # is the one honest way to walk this payload up to the shared ceiling.
      # The admitted maximum is exactly the cap; one more byte is refused.
      fitted = fitted_padding(context, base)
      at_limit = admit(context, base, fitted)
      over_limit = admit(context, base, fitted + 1)

      assert at_limit.outcome != {:error, :source_too_large}
      assert measured_bytes(at_limit.admitted) == @max_context_bytes

      assert over_limit.outcome == {:error, :source_too_large}

      # A refusal returns no context at all, so a host cannot mistake the answer
      # for an attached copy, and the context the host already held is untouched.
      # The same result still freezes cleanly: the ceiling limits that one
      # payload, not the finding.
      assert over_limit.admitted == nil
      assert scope.resource_context[:source_snapshot] == nil
      assert {:ok, _still_fine} = AssistantContext.freeze(scope.resource_context, base, :all)
    end

    test "refuses a snapshot this package is not allowed to describe", context do
      %{scope: scope} = context
      resource_context = scope.resource_context

      base = result(context, trips: 2, other_trips: 1)

      assert AssistantContext.freeze(resource_context, %{comparison: %{}}, :all) ==
               {:error, :invalid_scope}

      assert AssistantContext.freeze("not a context", base, :all) == {:error, :invalid_scope}

      assert AssistantContext.freeze(resource_context, base, []) == {:error, :invalid_scope}
    end
  end

  describe "freeze/3 over structural values that are not strings" do
    test "admits a frequency window the matcher compared as a tuple", context do
      %{scope: scope} = context

      # The candidate's one trip becomes a non-exact window. The matcher states
      # that as a structural change whose compared value is a tuple, which JSON
      # has no spelling for, so it must reach the seam as its elements in order.
      result = result_of(context, frequency_zip(false), frequency_zip(true))

      assert {:ok, admitted} = AssistantContext.freeze(scope.resource_context, result, :all)
      payload = admitted.source_snapshot.payload

      assert [change] =
               Enum.filter(payload["changes"]["structural"], &(&1["change"] == "frequencies"))

      assert {change["entity"], change["id"]} == {"trip", "T1"}
      assert change["left"] == []
      assert change["right"] == [[28_800, 32_400, 1_200, 0]]

      assert [effective] = payload["changes"]["effective"]
      assert effective["kind"] == "frequency_changed"

      assert_no_handles(payload)
    end
  end

  describe "freeze/3 over an explicit narrowing" do
    test "recomputes scoped totals, discloses what it left out, and is stable across repeats",
         context do
      %{scope: scope} = context
      result = result(context, trips: 2, other_trips: 1)
      selection = %{route_pair_keys: ["R1/R1"], dates: [@window.from]}

      assert {:ok, admitted} = AssistantContext.freeze(scope.resource_context, result, selection)
      payload = admitted.source_snapshot.payload

      # The narrowed body is a different identity from the complete one, and the
      # complete result's digest still names what the comparison actually was.
      assert payload["selected_digest"] != payload["result_digest"]
      assert payload["result_digest"] == result.comparison.digest

      assert payload["scope"] == %{
               "narrowed" => true,
               "route_pair_keys" => ["R1/R1"],
               "dates" => [@date]
             }

      assert payload["selected_route_pairs"] == ["R1/R1"]
      assert payload["selected_dates"] == [@date]

      # Repeating the same selection freezes to exactly the same admitted
      # context: the same rows, the same totals and the same digest, so a host
      # that changed its own state in between cannot make the copy move.
      assert {:ok, again} = AssistantContext.freeze(scope.resource_context, result, selection)
      assert again == admitted

      assert_no_handles(payload)
    end

    test "lists the narrowed dates chronologically across a month boundary", context do
      %{scope: scope} = context

      # Monday November 30 through Wednesday December 2 are service days.
      window = %{from: ~D[2026-11-29], to: ~D[2026-12-02]}
      result = result_of(context, week_zip(2), week_zip(1), window)
      selection = %{route_pair_keys: ["R1/R1"], dates: [~D[2026-12-01], ~D[2026-11-30]]}

      assert {:ok, admitted} = AssistantContext.freeze(scope.resource_context, result, selection)
      payload = admitted.source_snapshot.payload

      assert payload["selected_dates"] == ["2026-11-30", "2026-12-01"]
      assert payload["scope"]["dates"] == ["2026-11-30", "2026-12-01"]
    end

    test "refuses a selection that names no unit of this comparison", context do
      %{scope: scope} = context
      result = result(context, trips: 2, other_trips: 1)

      assert AssistantContext.freeze(
               scope.resource_context,
               result,
               %{route_pair_keys: ["R9/R9"], dates: [@window.from]}
             ) == {:error, :invalid_scope}

      assert AssistantContext.freeze(
               scope.resource_context,
               result,
               %{route_pair_keys: ["R1/R1"], dates: [~D[2026-12-25]]}
             ) == {:error, :invalid_scope}

      assert AssistantContext.freeze(
               scope.resource_context,
               result,
               %{route_pair_keys: [], dates: [@window.from]}
             ) == {:error, :invalid_scope}
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # Two artifacts of the shape the native exporter produces. The earlier file
  # runs two trips on the one service date; the candidate runs one, so the
  # comparison proves exactly one lost trip on that date.
  defp result(context, opts) do
    result_of(
      context,
      week_zip(Keyword.fetch!(opts, :trips)),
      week_zip(Keyword.fetch!(opts, :other_trips))
    )
  end

  defp result_of(context, left_bytes, right_bytes, window \\ @window) do
    organization = context.organization
    scope = context.scope

    left = publish!(organization, context.version, left_bytes)
    right = publish!(organization, gtfs_version_fixture(organization.id), right_bytes)

    left_projection = projection!(organization, left, scope)
    right_projection = projection!(organization, right, scope)
    {:ok, comparison} = Compare.run(left_projection, right_projection, window)

    %{
      fingerprint: fingerprint(left, right),
      window: window,
      left: identity(left),
      right: identity(right),
      comparison: comparison
    }
  end

  defp projection!(organization, run, scope) do
    {:ok, claim} = ExportRuns.claim_download(organization.id, run.gtfs_version_id, run.id, :main)

    assert {:ok, selection} =
             ReleaseComparison.resolve_selection(scope, %{
               "left_run_id" => run.id,
               "right_run_id" => run.id,
               "from" => @date,
               "to" => @date
             })

    {:ok, output} = Reader.read(claim, selection.left)
    {:ok, projection} = Projection.build(output)
    projection
  end

  defp identity(run) do
    %{
      run_id: run.id,
      version_id: run.gtfs_version_id,
      sha256: run.artifact_sha256,
      size: run.artifact_size_bytes,
      export_type: run.export_type,
      expires_at: run.artifact_expires_at,
      estimate_missing_times: run.estimate_missing_times,
      estimate_method: run.estimate_method
    }
  end

  # The coordinator's own fingerprint shape, so the frozen `source_ref` is a
  # value production produces rather than one this test invents.
  defp fingerprint(left, right) do
    [
      {:left_run_id, left.id},
      {:left_sha256, left.artifact_sha256},
      {:right_run_id, right.id},
      {:right_sha256, right.artifact_sha256},
      {:from, @window.from},
      {:to, @window.to}
    ]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp publish!(organization, version, bytes) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "network.zip", bytes)

    {:ok, run} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: nil
      })

    run
  end

  defp week_zip(trips) do
    trip_rows =
      Enum.map_join(1..trips, "\n", fn index ->
        "R1,WEEK,T#{index},0"
      end)

    members = [
      {"agency.txt",
       "agency_id,agency_name,agency_url,agency_timezone\nAGENCY,Agency,https://a.example,America/New_York\n"},
      {"routes.txt",
       "route_id,agency_id,route_short_name,route_long_name,route_type\nR1,AGENCY,R1,Route 1,3\n"},
      {"stops.txt", "stop_id,stop_name,stop_lat,stop_lon\nS,Stop,40.0,-73.0\n"},
      {"trips.txt", "route_id,service_id,trip_id,direction_id\n#{trip_rows}\n"},
      {"stop_times.txt",
       "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" <>
         Enum.map_join(1..trips, "\n", fn index ->
           "T#{index},08:00:00,08:00:00,S,1"
         end) <> "\n"},
      {"calendar.txt",
       "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nWEEK,1,1,1,1,1,0,0,20260101,20261231\n"}
    ]

    {:ok, {_, bytes}} =
      :zip.create(
        ~c"network.zip",
        Enum.map(members, fn {n, b} -> {String.to_charlist(n), b} end),
        [
          :memory
        ]
      )

    bytes
  end

  # Walks the payload up to the shared ceiling by lengthening one recorded
  # digest: the largest padding that is still admitted. Binary search, because
  # the payload grows exactly one byte per byte of padding.
  defp fitted_padding(context, base), do: do_fit(context, base, 0, 70_000)

  defp do_fit(context, base, low, high) do
    middle = div(low + high, 2)

    case admit(context, base, middle) do
      %{outcome: {:ok, _admitted}} ->
        if middle == high, do: middle, else: do_fit(context, base, middle, high)

      _refused ->
        if middle == 0, do: nil, else: do_fit(context, base, low, middle - 1)
    end
  end

  defp admit(context, base, padding) do
    result = padded(base, padding)
    outcome = AssistantContext.freeze(context.scope.resource_context, result, :all)

    case outcome do
      {:ok, admitted} -> %{admitted: admitted, outcome: outcome}
      {:error, _reason} = error -> %{admitted: nil, outcome: error}
    end
  end

  # The digest is server-held durable metadata, so padding it is data the
  # comparison genuinely carries rather than an injected handle.
  defp padded(base, padding) do
    put_in(base, [:left, :sha256], String.duplicate("a", 64 + padding))
  end

  # The measurement the shared seam documents: the whole serialized resource
  # context, identity and approval and envelope included. This test states it
  # independently rather than trusting the module under test to report its own
  # size.
  defp measured_bytes(context) do
    %{
      "identity" => %{
        "kind" => "version",
        "id" => elem(context.identity, 1)
      },
      "approved_extension" => nil,
      "source_snapshot" => %{
        "kind" => context.source_snapshot.kind,
        "payload" => context.source_snapshot.payload,
        "digest" => context.source_snapshot.digest
      }
    }
    |> Jason.encode!()
    |> byte_size()
  end

  defp assert_no_handles(term) when is_map(term) do
    for {key, value} <- term do
      assert is_binary(key)
      assert_no_handles(value)
    end
  end

  defp assert_no_handles(term) when is_list(term), do: Enum.each(term, &assert_no_handles/1)
  defp assert_no_handles(term) when is_number(term) or is_boolean(term) or is_nil(term), do: term
  defp assert_no_handles(term) when is_binary(term), do: refute_path?(term)

  defp assert_no_handles(term) do
    flunk("the admitted projection carried a non-JSON value: #{inspect(term)}")
  end

  # No admitted string may be a filesystem path, a URL or this worktree's
  # artifact root. A GTFS member name such as "trips.txt" is evidence and stays.
  defp refute_path?(string) do
    refute String.contains?(string, System.tmp_dir!())
    refute String.starts_with?(string, "/")
    refute String.contains?(string, "://")
    refute String.contains?(string, "network.zip")
  end
end
