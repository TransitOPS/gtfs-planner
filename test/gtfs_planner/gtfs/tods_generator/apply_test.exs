defmodule GtfsPlanner.Gtfs.TodsGenerator.ApplyTest do
  @moduledoc """
  Step 7: a generation commits once, atomically, against the reviewed source.

  `Gtfs.apply_tods_generation/2` and `Gtfs.get_tods_generation/2` are the facade
  the page saves and recovers through. The failures this file isolates are the
  save's own:

    * a preview's normalized input and fingerprint apply once and produce every
      promised row — the new block and its attribute row, the trip assignment and
      its audit, the run rows, the base-week choice, the single-slot lines, their
      slots and their fictional operators — beside exactly one receipt;
    * a repeated identical request answers with the receipt it already has and
      writes nothing again, while the same request token with a different input is
      refused even when the fingerprint still matches the receipt;
    * a source fact changed after the preview — a garage's geometry, a trip's times,
      a stored base choice — is `:stale_plan` with nothing written, and a revoked
      editor is `:forbidden`;
    * a change log the transaction refuses is `{:audit_failed, reason}` with the
      block and attribute rows it was written after rolled back with it, and a SQL
      failure on the receipt insert, forced through a test-local trigger, rolls the
      whole generation back: no block, run, choice, line, slot, operator or audit
      survives it;
    * receipt retrieval is scoped to the audit's organization and version and never
      creates a row.

  Every case drives the production composition over the fixture's own small
  schedule: `TodsGeneratorFixtures.roster_world_fixture/1` with one unblocked trip
  of the generator's own route, so the candidate has a new block, runs and roster
  lines to write. Assertions are literal facts read back from the database.

  Run with:
  `mix test test/gtfs_planner/gtfs/tods_generator/apply_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.TodsGeneratorFixtures

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TodsGeneration
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Repo

  @moduletag timeout: 120_000

  describe "applying a reviewed preview" do
    test "writes the promised rows once and records one receipt", %{} do
      world = world()
      holiday_week = Date.to_iso8601(Date.add(roster_monday(world), 14))

      assert {:ok, preview} =
               roster_preview(world, %{"representative_week" => holiday_week})

      assert preview.save_available?
      assert [block] = preview.blocks
      assert block.block_id == "103"
      assert preview.assignments == %{trip_uuid(world, "gen-a") => "103"}
      assert preview.roster_day_types == %{"1" => world.holiday_day_type}
      assert preview.roster_lines != []

      request_id = Ecto.UUID.generate()
      assert {:ok, receipt} = apply_preview(world, preview, request_id)

      # The receipt names the request, the reviewed source and what it created.
      assert receipt.request_id == request_id
      assert receipt.organization_id == world.organization.id
      assert receipt.gtfs_version_id == world.version.id
      assert receipt.actor_id == world.audit.actor_id
      assert receipt.normalized_inputs == preview.normalized_inputs
      assert receipt.source_fingerprint == preview.source_fingerprint
      assert receipt.created_ids["block_ids"] == ["103"]
      assert receipt.created_ids["changed_trip_ids"] == [trip_uuid(world, "gen-a")]
      assert receipt.created_ids["settings_changes"] == preview.roster_day_types

      assert receipt.created_ids["run_ids"] ==
               preview.run_deltas
               |> Map.values()
               |> Enum.flat_map(&Map.values/1)
               |> Enum.uniq()
               |> Enum.sort()

      assert length(receipt.created_ids["slot_ids"]) == length(preview.roster_lines)
      assert length(receipt.created_ids["operator_ids"]) == length(preview.roster_lines)

      assert receipt.summary["blocks"] == 1
      assert receipt.summary["changed_trips"] == 1
      assert receipt.summary["base_choices"] == 1
      assert receipt.summary["lines"] == length(preview.roster_lines)
      assert receipt.summary["slots"] == length(preview.roster_lines)
      assert receipt.summary["operators"] == length(preview.roster_lines)

      # The database holds exactly that generation and one receipt.
      assert stored_blocks(world)[trip_uuid(world, "gen-a")] == "103"
      assert attribute_rows(world) == [block_attribute(block)]
      assert runs_of(world, preview) == preview.run_deltas

      assert stored_choices(world) == preview.roster_day_types
      assert length(line_rows(world)) == length(preview.roster_lines)
      assert length(slot_rows(world)) == length(preview.roster_lines)
      assert length(operator_rows(world)) == length(preview.roster_lines)
      assert length(receipt_ids(world)) == 1

      # Every fictional operator holds one of the created lines, so the save leaves
      # no unused operator behind.
      line_operator_ids = Enum.map(line_rows(world), &elem(&1, 1))
      assert Enum.sort(line_operator_ids) == Enum.sort(operator_ids(world))
      assert Enum.all?(line_operator_ids, &is_binary/1)

      # The recovery read is the same receipt.
      assert {:ok, recovered} = Gtfs.get_tods_generation(world.audit, request_id)
      assert recovered.id == receipt.id

      # Re-previewing after the commit reports what remains and proposes no second
      # operator for a run-day a stored line already holds.
      assert {:ok, after_preview} =
               roster_preview(world, %{"representative_week" => holiday_week})

      staffed = MapSet.new(preview.roster_lines, &{&1.weekday, &1.run_id})

      refute Enum.any?(
               after_preview.roster_lines,
               &MapSet.member?(staffed, {&1.weekday, &1.run_id})
             )
    end
  end

  describe "one scoped request token" do
    test "a repeated identical request returns its receipt and writes nothing again" do
      world = world()
      assert {:ok, preview} = roster_preview(world)
      request_id = Ecto.UUID.generate()

      assert {:ok, receipt} = apply_preview(world, preview, request_id)
      committed = generation_state(world)

      # The retry carries the original fingerprint, which no longer describes the
      # source the first save changed; the completed receipt answers anyway.
      assert {:ok, repeated} = apply_preview(world, preview, request_id)
      assert repeated.id == receipt.id
      assert repeated.created_ids == receipt.created_ids
      assert generation_state(world) == committed
    end

    test "a different input under the same token is refused even with the receipt's fingerprint" do
      world = world()
      holiday_week = Date.to_iso8601(Date.add(roster_monday(world), 14))

      assert {:ok, preview} =
               roster_preview(world, %{"representative_week" => holiday_week})

      request_id = Ecto.UUID.generate()
      assert {:ok, receipt} = apply_preview(world, preview, request_id)
      committed = generation_state(world)

      # A different input — another representative week — with the receipt's own
      # fingerprint, so only the input tells the two requests apart.
      assert {:ok, other} = roster_preview(world)
      refute other.normalized_inputs == preview.normalized_inputs

      assert {:error, :request_conflict} =
               Gtfs.apply_tods_generation(world.audit, %{
                 request_id: request_id,
                 input: other.normalized_inputs,
                 source_fingerprint: receipt.source_fingerprint
               })

      assert generation_state(world) == committed
    end
  end

  describe "a source that changed after the preview" do
    test "a garage's geometry is :stale_plan with nothing written" do
      world = world()
      assert {:ok, preview} = roster_preview(world)
      before = generation_state(world)

      assert {:ok, _garage} =
               Operations.update_garage(
                 world.organization.id,
                 %{id: world.audit.actor_id},
                 world.garage.id,
                 %{"lat" => "41.0000"}
               )

      assert {:error, :stale_plan} = apply_preview(world, preview, Ecto.UUID.generate())
      assert generation_state(world) == before
    end

    test "a trip retimed is :stale_plan with nothing written" do
      world = world()
      assert {:ok, preview} = roster_preview(world)
      before = generation_state(world)

      assert {1, _} =
               Repo.update_all(
                 from(st in StopTime,
                   where:
                     st.organization_id == ^world.organization.id and
                       st.gtfs_version_id == ^world.version.id and
                       st.trip_id == "gen-a" and
                       st.stop_sequence == 2
                 ),
                 set: [departure_time: "05:00:00", updated_at: DateTime.utc_now()]
               )

      assert {:error, :stale_plan} = apply_preview(world, preview, Ecto.UUID.generate())
      assert generation_state(world) == before
    end

    test "a base choice stored since is :stale_plan with nothing written" do
      world = world()
      assert {:ok, preview} = roster_preview(world)

      assert {:ok, _settings} =
               Gtfs.update_roster_settings(world.audit, %{
                 "roster_day_types" => %{"1" => world.monday_day_type}
               })

      # The operator's own choice is what the refused save must leave standing.
      assert stored_choices(world) == %{"1" => world.monday_day_type}
      before = generation_state(world)

      assert {:error, :stale_plan} = apply_preview(world, preview, Ecto.UUID.generate())
      assert generation_state(world) == before
    end

    test "a revoked editor is :forbidden with nothing written" do
      world = world()
      assert {:ok, preview} = roster_preview(world)
      before = generation_state(world)

      assert {1, _} =
               Repo.delete_all(
                 from(m in UserOrgMembership,
                   where:
                     m.user_id == ^world.audit.actor_id and
                       m.organization_id == ^world.organization.id
                 )
               )

      assert {:error, :forbidden} = apply_preview(world, preview, Ecto.UUID.generate())
      assert generation_state(world) == before
      assert {:error, :forbidden} = Gtfs.get_tods_generation(world.audit, Ecto.UUID.generate())
    end
  end

  describe "a write that fails at the last step" do
    test "a refused receipt insert rolls the whole generation back" do
      world = world()
      assert {:ok, preview} = roster_preview(world)
      before = generation_state(world)
      request_id = Ecto.UUID.generate()

      refuse_receipt_inserts!()

      # A plain SQL error is not transient, so it is answered `:write_failed` rather
      # than retried, and the attempt's whole transaction is gone.
      assert {:error, :write_failed} = apply_preview(world, preview, request_id)
      assert generation_state(world) == before

      # The same request then commits with the trigger removed, so the refusal above
      # removed real writes rather than a call that wrote nothing.
      remove_receipt_refusal!()

      assert {:ok, _receipt} = apply_preview(world, preview, request_id)
      assert length(receipt_ids(world)) == 1
      assert stored_blocks(world)[trip_uuid(world, "gen-a")] == "103"
      assert length(line_rows(world)) == length(preview.roster_lines)
    end
  end

  describe "a write the transaction refuses inside the plan" do
    test "a refused change log answers the block writer's {:audit_failed, reason}" do
      world = world()
      assert {:ok, preview} = roster_preview(world)
      before = generation_state(world)
      request_id = Ecto.UUID.generate()

      refuse_change_logs!()

      # The moved trip's change log is the block plan's own audit write, so its
      # refusal is that writer's reason rather than `:write_failed` or a raise, and
      # it rolls back the block and attribute rows written before it.
      assert {:error, {:audit_failed, _reason}} = apply_preview(world, preview, request_id)
      assert generation_state(world) == before

      # The same request then commits with the trigger removed, so the refusal above
      # removed real writes rather than a call that wrote nothing.
      remove_change_log_refusal!()

      assert {:ok, receipt} = apply_preview(world, preview, request_id)
      assert receipt.summary["blocks"] == 1
      assert stored_blocks(world)[trip_uuid(world, "gen-a")] == "103"
      assert length(audit_ids(world)) == 1
    end
  end

  describe "reading a completed request" do
    test "is scoped to the caller's organization and version and creates no row" do
      world = world()
      assert {:ok, preview} = roster_preview(world)
      request_id = Ecto.UUID.generate()
      assert {:ok, receipt} = apply_preview(world, preview, request_id)
      committed = generation_state(world)

      assert {:ok, recovered} = Gtfs.get_tods_generation(world.audit, request_id)
      assert recovered.id == receipt.id

      # The same token read from another organization's scope is not disclosed.
      theirs = foreign_scope_fixture()
      assert {:error, :not_found} = Gtfs.get_tods_generation(theirs.audit, request_id)

      assert {:error, :not_found} =
               Gtfs.get_tods_generation(world.audit, Ecto.UUID.generate())

      assert {:error, :not_found} = Gtfs.get_tods_generation(world.audit, "not-a-uuid")
      assert generation_state(world) == committed
    end
  end

  # --- fixtures and helpers --------------------------------------------------

  # One unblocked weekday trip on the generator's own route and vehicle type, so the
  # candidate has one new block ("103") carrying the selected garage.
  defp world do
    roster_world_fixture(extra_trips: [{"gen-a", "WK", "RIV", "RIV", "04:00:00", "04:30:00"}])
  end

  defp apply_preview(world, preview, request_id) do
    Gtfs.apply_tods_generation(world.audit, %{
      request_id: request_id,
      input: preview.normalized_inputs,
      source_fingerprint: preview.source_fingerprint
    })
  end

  defp trip_uuid(world, trip_id), do: Map.fetch!(world.trip_ids, trip_id)

  defp block_attribute(block) do
    %{
      service_id: "WK",
      block_id: block.block_id,
      garage_id: block.garage_id,
      vehicle_type_id: block.vehicle_type_id
    }
  end

  # `trip_id => run_id` per day type, the shape one key of a run delta is, over the
  # day types the candidate wrote. The world stores no runs of its own.
  defp runs_of(world, preview) do
    stored =
      from(r in TripRun,
        select: %{day_type_key: r.day_type_key, trip_id: r.trip_id, run_id: r.run_id}
      )
      |> scoped(world)
      |> Repo.all()
      |> Enum.group_by(& &1.day_type_key, &{&1.trip_id, &1.run_id})
      |> Map.new(fn {key, pairs} -> {key, Map.new(pairs)} end)

    Map.take(stored, Map.keys(preview.run_deltas))
  end

  # Everything a generation could change, read from the database.
  defp generation_state(world) do
    %{
      blocks: stored_blocks(world),
      attributes: attribute_rows(world),
      runs: run_rows(world),
      relief: relief_stops(world),
      audits: audit_ids(world),
      choices: stored_choices(world),
      lines: line_rows(world),
      slots: slot_rows(world),
      operators: operator_rows(world),
      receipts: receipt_ids(world)
    }
  end

  defp stored_blocks(world) do
    from(t in Trip, select: {t.id, t.block_id})
    |> scoped(world)
    |> Repo.all()
    |> Map.new()
  end

  defp attribute_rows(world) do
    from(a in BlockAttribute,
      select: %{
        service_id: a.service_id,
        block_id: a.block_id,
        garage_id: a.garage_id,
        vehicle_type_id: a.vehicle_type_id
      },
      order_by: [asc: a.service_id, asc: a.block_id]
    )
    |> scoped(world)
    |> Repo.all()
  end

  defp run_rows(world) do
    from(r in TripRun,
      select: {r.day_type_key, r.trip_id, r.run_id},
      order_by: [asc: r.day_type_key, asc: r.trip_id]
    )
    |> scoped(world)
    |> Repo.all()
  end

  defp relief_stops(world) do
    from(p in ReliefPoint, select: p.stop_id, order_by: p.stop_id)
    |> scoped(world)
    |> Repo.all()
  end

  defp audit_ids(world) do
    from(l in ChangeLog, select: l.id, order_by: l.id)
    |> scoped(world)
    |> Repo.all()
  end

  defp stored_choices(world),
    do: Gtfs.get_roster_settings(world.organization.id, world.version.id).roster_day_types

  defp line_rows(world) do
    from(l in RosterLine, select: {l.line_number, l.operator_id}, order_by: l.line_number)
    |> scoped(world)
    |> Repo.all()
  end

  defp slot_rows(world) do
    from(d in RosterLineDay,
      select: {d.weekday, d.day_type_key, d.run_id},
      order_by: [asc: d.weekday, asc: d.run_id]
    )
    |> scoped(world)
    |> Repo.all()
  end

  # Operators hold no version of their own; they belong to the organization.
  defp operator_rows(world) do
    from(o in Operator,
      where: o.organization_id == ^world.organization.id,
      select: {o.employee_id, o.display_name},
      order_by: o.employee_id
    )
    |> Repo.all()
  end

  defp operator_ids(world) do
    from(l in RosterLine,
      where:
        l.organization_id == ^world.organization.id and l.gtfs_version_id == ^world.version.id,
      select: l.operator_id
    )
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
  end

  defp receipt_ids(world) do
    from(g in TodsGeneration, select: g.id, order_by: g.id)
    |> scoped(world)
    |> Repo.all()
  end

  defp scoped(query, world) do
    where(
      query,
      [r],
      field(r, :organization_id) == ^world.organization.id and
        field(r, :gtfs_version_id) == ^world.version.id
    )
  end

  # A test-local trigger that refuses every receipt insert with a plain SQL error;
  # the same shape the card asks for instead of a production fault-injection hook.
  # The fixture is removed by the case and again in `on_exit`, so a failed case
  # cannot leave it behind.
  defp refuse_receipt_inserts! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION tods_test_refuse_receipt() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'test fixture refuses receipt inserts' USING ERRCODE = 'P0001';
    END;
    $$ LANGUAGE plpgsql;
    """)

    Repo.query!("""
    CREATE TRIGGER tods_test_refuse_receipt
    BEFORE INSERT ON tods_generations
    FOR EACH ROW EXECUTE FUNCTION tods_test_refuse_receipt();
    """)

    on_exit(&remove_receipt_refusal!/0)
  end

  # A test-local trigger that refuses every change-log insert, the shape the receipt
  # case above uses and the same one an audit insert a database rejects has. The
  # fixture is removed by the case and again in `on_exit`, so a failed case cannot
  # leave it behind.
  defp refuse_change_logs! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION tods_test_refuse_change_log() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'test fixture refuses change log inserts' USING ERRCODE = 'P0001';
    END;
    $$ LANGUAGE plpgsql;
    """)

    Repo.query!("""
    CREATE TRIGGER tods_test_refuse_change_log
    BEFORE INSERT ON change_logs
    FOR EACH ROW EXECUTE FUNCTION tods_test_refuse_change_log();
    """)

    on_exit(&remove_change_log_refusal!/0)
  end

  defp remove_change_log_refusal! do
    Repo.query!("DROP TRIGGER IF EXISTS tods_test_refuse_change_log ON change_logs")
    Repo.query!("DROP FUNCTION IF EXISTS tods_test_refuse_change_log()")
  end

  defp remove_receipt_refusal! do
    Repo.query!("DROP TRIGGER IF EXISTS tods_test_refuse_receipt ON tods_generations")
    Repo.query!("DROP FUNCTION IF EXISTS tods_test_refuse_receipt()")
  end
end
