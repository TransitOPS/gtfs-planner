defmodule GtfsPlanner.Gtfs.TransferPolicyReviewTest do
  @moduledoc """
  Merge evidence (EV-1) for reviewing a general transfer-policy change.

  `Transfers.review_policy_change/3` must show the scoped before and after the native
  editor would write, retain an explicit protected trip exception beside a broad
  A→B/300s rule, refuse a command that would join an equal-best witness with a
  differing effect while the same pair in the opposite direction does not compete,
  refuse a foreign target, an unknown selector and a requested protected deletion, and
  fingerprint its dependencies so an empty dependency set still enters the digest.

  The cases run against the shared literal network (`TransfersFixtures`) through the
  production function, the real `Transfer.editor_changeset/2` reference checks and the
  real `Overlaps` evaluator, cross-checked against the independent brute-force
  `TransferOverlapOracle`, so a review that re-derives its own verdict, widens its
  scope past the audit context, or hashes a state that omits an empty dependency set is
  rejected here. EV-1 does not prove the SERIALIZABLE interleavings of an apply (EV-2),
  the agent pack that calls this review (EV-4), the LiveView handoff (EV-5) or the
  browser journey (EV-13).

  The focused command is deferred to branch review:
  `MIX_TEST_PARTITION=_ai05 mix test test/gtfs_planner/gtfs/transfer_policy_review_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.Gtfs.Transfers.Overlaps
  alias GtfsPlanner.TransferOverlapOracle
  alias GtfsPlanner.TransfersFixtures

  setup do
    %{ctx: build_scope()}
  end

  describe "a broad rule beside a protected trip exception" do
    test "keeps the exception unchanged and the 300 second conversion literal", %{ctx: ctx} do
      # The exception is a trip-scoped A→B rule with a differing effect (type 3, no
      # minimum) beside the broad 300 second type 2 rule. It is rank 1 and the broad
      # rule is rank 6, so it keeps the one trip pair both of them cover.
      exception =
        write_general!(ctx, %{
          "from_stop_id" => "CEN-A",
          "to_stop_id" => "MKT",
          "from_trip_id" => "12-0815",
          "to_trip_id" => "24-0840",
          "transfer_type" => "3"
        })

      command =
        create_command(%{
          "from_stop_id" => "CEN-A",
          "to_stop_id" => "MKT",
          "transfer_type" => "2",
          "min_transfer_time" => "300"
        })
        |> Map.put(:protected_ids, [exception.id])

      assert {:ok, review} = Transfers.review_policy_change(ctx.scope, command, ctx.audit)

      assert review.command == command
      assert review.before == nil
      assert review.after["from_stop_id"] == "CEN-A"
      assert review.after["to_stop_id"] == "MKT"
      assert review.after["transfer_type"] == 2
      assert review.after["min_transfer_time"] == 300
      assert review.protected == [Transfer.audit_snapshot(exception)]
      assert review.conflicts == []
      assert review.dependencies_digest == Transfers.dependencies_digest(ctx.audit)

      # The broad rule is written exactly as supplied, and the more specific trip
      # exception outranks it, so the broad rule cannot erase it.
      assert Overlaps.rank(prospective(review.after)) > Overlaps.rank(prospective(exception))

      # The independent oracle agrees the two rules do not compete, which is the same
      # verdict the review's empty `conflicts` reports.
      assert oracle_conflicts([prospective(review.after), prospective(exception)]) == %{}
    end
  end

  describe "equal-best differing effects" do
    # The stored rule is rank 6 (no selector on either side) and the command's rule is
    # rank 6 too, and their keys differ while their coverage overlaps: the station CEN
    # covers the platform CEN-A, and both rules name MKT on the from side. The one
    # witness is `12-0815` at MKT and `12-0815` at CEN-A.
    setup %{ctx: ctx} do
      stored =
        write_general!(ctx, %{
          "from_stop_id" => "MKT",
          "to_stop_id" => "CEN",
          "transfer_type" => "0"
        })

      %{ctx: Map.put(ctx, :stored, stored)}
    end

    test "refuse a create that would join a concrete stop and trip witness", %{ctx: ctx} do
      command =
        create_command(%{
          "from_stop_id" => "MKT",
          "to_stop_id" => "CEN-A",
          "transfer_type" => "2",
          "min_transfer_time" => "300"
        })

      assert {:error, {:conflict, [witness]}} =
               Transfers.review_policy_change(ctx.scope, command, ctx.audit)

      assert witness.from_stop_id == "MKT"
      assert witness.from_trip_id == "12-0815"
      assert witness.to_stop_id == "CEN-A"
      assert witness.to_trip_id == "12-0815"
      assert witness.rule_ids == Enum.sort([ctx.stored.id, nil])

      # The same disagreement, read by the independent oracle over the same
      # prospective rules, names the same pair: the stored rule and the rule this
      # command would write.
      assert oracle_conflicts([prospective(ctx.stored), prospective(command.attrs)]) != %{}

      # A refused review writes nothing.
      assert Repo.all(Transfer) |> length() == 1
    end

    test "the same pair in the opposite direction has no competition", %{ctx: ctx} do
      command =
        create_command(%{
          "from_stop_id" => "CEN",
          "to_stop_id" => "MKT",
          "transfer_type" => "2",
          "min_transfer_time" => "300"
        })

      assert {:ok, review} = Transfers.review_policy_change(ctx.scope, command, ctx.audit)

      assert review.conflicts == []
      assert review.after["from_stop_id"] == "CEN"
      assert review.after["to_stop_id"] == "MKT"
      assert review.after["min_transfer_time"] == 300
    end
  end

  describe "refusals" do
    test "a foreign target, a malformed id, a stale timestamp and a foreign scope", %{ctx: ctx} do
      foreign_org = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_org.id)

      foreign =
        write_general!(build_scope(foreign_org, foreign_version), %{
          "from_stop_id" => "CEN-A",
          "to_stop_id" => "MKT",
          "transfer_type" => "0"
        })

      local =
        write_general!(ctx, %{
          "from_stop_id" => "MUS",
          "to_stop_id" => "NOC",
          "transfer_type" => "0"
        })

      assert {:error, :not_found} =
               Transfers.review_policy_change(
                 ctx.scope,
                 update_command(foreign.id, foreign.updated_at, %{}),
                 ctx.audit
               )

      assert {:error, :invalid_input} =
               Transfers.review_policy_change(
                 ctx.scope,
                 update_command("not-a-uuid", nil, %{}),
                 ctx.audit
               )

      assert {:error, :stale} =
               Transfers.review_policy_change(
                 ctx.scope,
                 update_command(local.id, DateTime.add(local.updated_at, -1, :second), %{}),
                 ctx.audit
               )

      # A scope that disagrees with the audit context is refused before any read.
      assert {:error, :forbidden} =
               Transfers.review_policy_change(
                 %{organization_id: foreign_org.id, gtfs_version_id: ctx.version.id},
                 create_command(%{
                   "from_stop_id" => "MUS",
                   "to_stop_id" => "NOC",
                   "transfer_type" => "0"
                 }),
                 ctx.audit
               )
    end

    test "an unknown selector and malformed commands", %{ctx: ctx} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Transfers.review_policy_change(
                 ctx.scope,
                 create_command(%{
                   "from_stop_id" => "CEN-A",
                   "to_stop_id" => "MKT",
                   "from_trip_id" => "NO-SUCH-TRIP",
                   "transfer_type" => "0"
                 }),
                 ctx.audit
               )

      assert Keyword.has_key?(changeset.errors, :from_trip_id)

      assert {:error, %Ecto.Changeset{}} =
               Transfers.review_policy_change(
                 ctx.scope,
                 create_command(%{
                   "from_stop_id" => "CEN-A",
                   "to_stop_id" => "NO-SUCH-STOP",
                   "transfer_type" => "0"
                 }),
                 ctx.audit
               )

      assert {:error, :invalid_input} =
               Transfers.review_policy_change(ctx.scope, %{action: :create}, ctx.audit)

      assert {:error, :invalid_input} =
               Transfers.review_policy_change(
                 ctx.scope,
                 Map.put(
                   create_command(%{
                     "from_stop_id" => "MUS",
                     "to_stop_id" => "NOC",
                     "transfer_type" => "0"
                   }),
                   :protected_ids,
                   ["nope"]
                 ),
                 ctx.audit
               )

      assert {:error, :invalid_input} =
               Transfers.review_policy_change(
                 ctx.scope,
                 Map.put(
                   create_command(%{
                     "from_stop_id" => "MUS",
                     "to_stop_id" => "NOC",
                     "transfer_type" => "0"
                   }),
                   :action,
                   :upsert
                 ),
                 ctx.audit
               )
    end

    test "a requested protected deletion is refused while an unrelated one is not", %{ctx: ctx} do
      exception =
        write_general!(ctx, %{
          "from_stop_id" => "CEN-A",
          "to_stop_id" => "MKT",
          "from_trip_id" => "12-0815",
          "transfer_type" => "3"
        })

      unrelated =
        write_general!(ctx, %{
          "from_stop_id" => "MUS",
          "to_stop_id" => "NOC",
          "transfer_type" => "0"
        })

      delete_command = %{
        action: :delete,
        target_id: exception.id,
        expected_updated_at: exception.updated_at,
        attrs: %{},
        protected_ids: [exception.id]
      }

      assert {:error, :protected} =
               Transfers.review_policy_change(ctx.scope, delete_command, ctx.audit)

      # The same command without the exception named protected is the deliberate
      # edit an explicit separate command makes.
      assert {:ok, review} =
               Transfers.review_policy_change(
                 ctx.scope,
                 %{delete_command | protected_ids: []},
                 ctx.audit
               )

      assert review.before == Transfer.audit_snapshot(exception)
      assert review.after == nil
      assert review.protected == []

      assert {:ok, unrelated_review} =
               Transfers.review_policy_change(
                 ctx.scope,
                 %{
                   delete_command
                   | target_id: unrelated.id,
                     expected_updated_at: unrelated.updated_at
                 },
                 ctx.audit
               )

      assert unrelated_review.before == Transfer.audit_snapshot(unrelated)
      assert unrelated_review.protected == [Transfer.audit_snapshot(exception)]
    end
  end

  describe "dependency digest" do
    test "an empty dependency set is still hashed, and an insertion changes it" do
      empty = build_scope()

      assert byte_size(Transfers.dependencies_digest(empty.audit)) == 64

      assert Transfers.dependencies_digest(empty.audit) ==
               Transfers.dependencies_digest(empty.audit)

      before = Transfers.dependencies_digest(empty.audit)

      write_general!(empty, %{
        "from_stop_id" => "MUS",
        "to_stop_id" => "NOC",
        "transfer_type" => "0"
      })

      assert Transfers.dependencies_digest(empty.audit) != before
    end

    test "a new stop_time at a coverage leaf moves the digest", %{ctx: ctx} do
      write_general!(ctx, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "MKT",
        "transfer_type" => "0"
      })

      before = Transfers.dependencies_digest(ctx.audit)

      trip =
        trip_fixture(ctx.organization.id, ctx.version.id, "12", %{
          trip_id: "12-1200",
          service_id: "WKDY"
        })

      stop_time_fixture(
        ctx.organization.id,
        ctx.version.id,
        trip.trip_id,
        "CEN-A",
        %{arrival_time: "12:00:00", departure_time: "12:00:00", stop_sequence: 1}
      )

      assert Transfers.dependencies_digest(ctx.audit) != before
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp build_scope(organization \\ nil, version \\ nil) do
    organization = organization || organization_fixture()
    version = version || gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)
    actor = user_fixture()
    organization_membership_fixture(actor, organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      },
      scope: %{organization_id: organization.id, gtfs_version_id: version.id}
    }
  end

  defp write_general!(ctx, attrs) do
    assert {:ok, transfer} = Transfers.create_general(attrs, ctx.audit)
    transfer
  end

  defp create_command(attrs) do
    %{
      action: :create,
      target_id: nil,
      expected_updated_at: nil,
      attrs: attrs,
      protected_ids: []
    }
  end

  defp update_command(target_id, expected_updated_at, attrs) do
    %{
      action: :update,
      target_id: target_id,
      expected_updated_at: expected_updated_at,
      attrs: attrs,
      protected_ids: []
    }
  end

  # The eight GTFS columns the review reports, in the shape the evaluator and the
  # oracle both read. A stored `Transfer` and a reported snapshot are both accepted.
  defp prospective(rule) do
    attrs = if Map.has_key?(rule, "from_stop_id"), do: rule, else: Transfer.audit_snapshot(rule)

    %{
      id: :prospective,
      from_coverage: expand(attrs["from_stop_id"]),
      to_coverage: expand(attrs["to_stop_id"]),
      from_route_id: attrs["from_route_id"],
      to_route_id: attrs["to_route_id"],
      from_trip_id: attrs["from_trip_id"],
      to_trip_id: attrs["to_trip_id"],
      transfer_type: attrs["transfer_type"],
      min_transfer_time: attrs["min_transfer_time"]
    }
  end

  # The oracle reads literal stop ids and the fixture's own `stop_time` rows, so the
  # station CEN is expanded to the leaves a rule really covers before it re-derives the
  # verdict, and each rule gets a distinct id.
  defp oracle_conflicts(rules) do
    incidence = %{
      "MKT" => [{"12-0815", "12"}, {"12-1010", "12"}, {"24-0840", "24"}, {"24-0920", "24"}],
      "CEN-A" => [{"12-0815", "12"}, {"6-0815", "6"}],
      "CEN-C" => [{"24-0840", "24"}],
      "HBR" => [{"12-0815", "12"}, {"12-1010", "12"}, {"24-0840", "24"}, {"24-0920", "24"}],
      "MUS" => [{"6-0815", "6"}],
      "NOC" => []
    }

    TransferOverlapOracle.competitors(
      Enum.map(rules, &Map.put(&1, :id, System.unique_integer([:positive]))),
      incidence
    )
  end

  defp expand(nil), do: []
  defp expand("CEN"), do: ["CEN", "CEN-A", "CEN-C"]
  defp expand(stop_id), do: [stop_id]
end
