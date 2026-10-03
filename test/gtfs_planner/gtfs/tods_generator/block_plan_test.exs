defmodule GtfsPlanner.Gtfs.TodsGenerator.BlockPlanTest do
  @moduledoc """
  Step 2: a generation preview composes a scoped block candidate from a consistent
  snapshot and writes nothing.

  These are the failures specific to *generation* composition, which the
  single-day-type suggestion tests cannot see because they never ask the question:

    * a permutation of the source row order produces an identical candidate and an
      identical fingerprint — a candidate that depended on the order its rows came
      back in would differ between two reads of one committed revision, and the
      fingerprint a later save compares would refuse its own preview;
    * a preview leaves `trips`, `block_attributes`, `roster_lines`,
      `roster_line_days`, `trip_runs` and `operators` at the counts it found them,
      including on every refusal;
    * 3,000 distinct trips are admitted and the 3,001st is refused as
      `{:too_large, 3001}`;
    * a trip in two day types is given one block ID, and a new block invalid on any
      affected day loses all of its new moves rather than half of them;
    * a block's trip running on a date outside the selected range is part of the
      block: it is counted against the bound, and it decides whether a new move
      onto that block is valid;
    * an existing block is preserved, and nothing a preview proposes is written;
    * a garage of another organization, a staging version, an organization with no
      garage, and a range with no active service are each refused or answered as
      themselves, and an actor who is no longer an editor is `:forbidden`.

  Every candidate is composed through the production chain —
  `Blocking.candidate_input/3` for the reads, `Blocking.Generator.run/4` and
  `Blocking.Checks.block_findings/3` for the decisions, and
  `TodsGenerator.preview/2` for the entry — and every day type key comes from the
  fixture's own calendars through `Calendars.list_calendars/3`, never hand-written.
  The permutation case composes through `TodsGenerator.plan_from_inputs/5` with the
  same rows reordered, because `preview/2` reads its own rows and cannot be handed
  an order.

  The 3,001-trip case writes its trips with `Repo.insert_all/3` inside this test's
  SQL Sandbox transaction, which rolls them back.

  Run with:
  `mix test test/gtfs_planner/gtfs/tods_generator/block_plan_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures,
    only: [deactivate_membership_fixture: 1, editor_audit_fixture: 2]

  import GtfsPlanner.BlockingFixtures, only: [calendar_service_fixture: 3]
  import GtfsPlanner.OperationsFixtures, only: [garage_fixture: 1]
  import GtfsPlanner.TodsGeneratorFixtures
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.TodsGenerator

  describe "a candidate composed from the source" do
    test "an unblocked trip becomes one new block carrying the selected garage" do
      world = tods_world_fixture(extra_trips: [weekday_trip()])

      assert {:ok, preview} = preview(world)

      assert [%{block_id: "103", new?: true, garage_id: garage_id}] = preview.blocks
      assert garage_id == world.garage.id
      assert Enum.map(hd(preview.blocks).trips, & &1.trip_id) == ["gen-a"]
      assert preview.counts.new_assignments == 1
      assert preview.counts.new_blocks == 1
      assert preview.counts.preserved_blocks == 2
      assert preview.preserved_block_ids == ["101", "102"]
      assert preview.no_work? == false
    end

    test "a trip in two day types is given one block ID" do
      world = tods_world_fixture(extra_trips: [weekday_trip()])

      assert {:ok, preview} = preview(world)

      # Both day types are in scope for the week's range, and the trip is on the
      # weekday service, which both of them run.
      assert length(preview.day_type_keys) == 2

      assert Enum.sort(preview.day_type_keys) ==
               Enum.sort([world.weekday_day_type, world.monday_day_type])

      assert [block] = preview.blocks
      assert block.day_type_keys == Enum.sort(preview.day_type_keys)
      assert Enum.map(block.trips, & &1.trip_id) == ["gen-a"]

      # One assignment and one block ID, not one per day type: the same trip UUID
      # was frozen after the first day type and kept its block on the second.
      assert map_size(preview.assignments) == 1
      assert Map.values(preview.assignments) == ["103"]
      assert Map.keys(preview.assignments) == [trip_uuid(world, "gen-a")]
    end

    test "a second run over unchanged source produces the same candidate and hash" do
      world = tods_world_fixture(extra_trips: [weekday_trip()])

      assert {:ok, first} = preview(world)
      assert {:ok, second} = preview(world)

      assert second.blocks == first.blocks
      assert second.assignments == first.assignments
      assert second.exclusions == first.exclusions
      assert second.counts == first.counts
      assert second.source_fingerprint == first.source_fingerprint
      assert second.normalized_inputs == first.normalized_inputs
    end

    test "the fingerprint changes when a source fact changes" do
      world = tods_world_fixture(extra_trips: [weekday_trip(), clear_monday_trip()])

      assert {:ok, before} = preview(world)
      assert {:ok, same} = preview(world)
      assert same.source_fingerprint == before.source_fingerprint

      # A rule a preview cannot change but a later save would re-read: moving the
      # selected garage is a different request, and it must not share a hash with
      # the one above. The retiming below is the source-fact half of the claim, and
      # it is asserted through the fingerprint rather than a candidate, because a
      # retiming need not change what the generator would place.
      other = garage_fixture(world.organization.id)
      assert {:ok, moved} = preview(world, %{"garage_id" => other.id})
      refute moved.source_fingerprint == before.source_fingerprint

      retime(world, "gen-a", "04:10:00", "04:40:00")
      assert {:ok, retimed} = preview(world, %{"garage_id" => other.id})
      refute retimed.source_fingerprint == moved.source_fingerprint
    end

    test "the preview writes no trip's block_id" do
      world = tods_world_fixture(extra_trips: [weekday_trip(), clear_monday_trip()])

      assert {:ok, preview} = preview(world)
      assert preview.assignments != %{}

      for {trip_id, block_id} <- preview.assignments do
        assert stored_block_id(world, trip_id) == nil,
               "the preview proposed #{block_id} for a trip the database still holds unassigned"
      end
    end
  end

  describe "source row order" do
    test "a permutation of the row order gives an identical candidate and hash" do
      world = tods_world_fixture(extra_trips: [weekday_trip(), clear_monday_trip()])
      day_types = day_types(world)
      input = normalized_inputs(world)

      assert {:ok, read} = candidate_inputs(world, day_types)
      assert {:ok, reference} = preview(world)

      # Reversal and two seeded shuffles, not one permutation: a candidate that
      # sorted by arrival but not by departure would agree with the identity order
      # and disagree with half of these.
      for reordered <- [
            reverse_rows(read),
            reverse_rows(shuffled_rows(read, 7)),
            shuffled_rows(read, 13)
          ] do
        assert {:ok, {candidate, source}} =
                 TodsGenerator.plan_from_inputs(
                   world.audit,
                   day_types,
                   reordered,
                   input,
                   world.garage.id
                 )

        assert candidate.blocks == reference.blocks
        assert candidate.assignments == reference.assignments
        assert candidate.exclusions == reference.exclusions
        assert candidate.counts == reference.counts
        assert candidate.day_type_keys == reference.day_type_keys

        assert TodsGenerator.fingerprint(source, input, world.garage.id) ==
                 reference.source_fingerprint
      end
    end
  end

  describe "the admission bound" do
    test "3,000 distinct trips are admitted and the 3,001st is refused" do
      world = tods_world_fixture()
      {organization_id, version_id, audit, inputs} = bulk_scope(world)

      bulk_day(organization_id, version_id, 3_000)

      # Admitted and answered: every trip is counted and every one of them is
      # reported rather than dropped, which is what "inside the bound" means. The
      # bulk trips carry no stop times, so the generator holds each as
      # `:unplottable` instead of inventing a chain for it.
      assert {:ok, at_bound} = TodsGenerator.preview(audit, inputs)
      assert length(at_bound.exclusions) == 3_000
      assert Enum.uniq(Enum.map(at_bound.exclusions, & &1.reason)) == [:unplottable]

      insert_chunked!(GtfsPlanner.Gtfs.Trip, [bulk_trip(organization_id, version_id, "B3001")])

      # One trip over the bound refuses the whole scope and costs no candidate.
      assert {:error, {:too_large, 3001}} = TodsGenerator.preview(audit, inputs)
    end

    test "a touched block's out-of-range companion is counted before the bound" do
      world = tods_world_fixture()
      {organization_id, version_id, audit, inputs} = bulk_scope(world)

      bulk_day(organization_id, version_id, 2_998)
      block_with_out_of_range_companion!(organization_id, version_id)

      # The range holds 2,999 of these trips; completing the block one of them is
      # in reaches its December trip, which is the 3,000th.
      assert {:ok, _at_bound} = TodsGenerator.preview(audit, inputs)

      insert_chunked!(GtfsPlanner.Gtfs.Trip, [bulk_trip(organization_id, version_id, "B3001")])

      # The 3,001st distinct trip is the one the range's own dates do not hold: a
      # count of the selected dates alone would see 3,000 and admit it.
      assert {:error, {:too_large, 3001}} = TodsGenerator.preview(audit, inputs)
    end

    test "a trip in two day types is counted once against the bound" do
      world = tods_world_fixture(extra_trips: [weekday_trip()])
      day_types = day_types(world)

      assert {:ok, inputs} = candidate_inputs(world, day_types)

      # The fixture's weekday trip is in both day types' rows, so the union is
      # smaller than the sum of the two lists and is what the bound counts.
      union = TodsGenerator.distinct_trip_count(inputs.rows_by_day_type)

      # Every trip of a day type is also in the other one when both day types run
      # the weekday service, so the summed row lists double-count and the union
      # does not: the difference is exactly the size of that overlap.
      summed = inputs.rows_by_day_type |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

      # Both day types run the weekday service, so their row lists hold the same
      # trips and the union is half the sum.
      assert length(day_type_keys(inputs)) == 2
      assert summed == union * 2
      assert union < sum_trip_count(day_types, inputs)
    end
  end

  describe "the union candidate on every affected day" do
    test "a new block invalid on one affected day loses all of its new moves" do
      # `gen-a` runs on both day types and opens a new block on both. On the Monday
      # day type the run also chains `mon-lay` after it: `mon-lay` sits at its first
      # stop from 04:10, so the gap from `gen-a`'s 04:30 arrival to `mon-lay`'s 04:45
      # departure is 15 minutes and the generator's "can this follow the last trip"
      # test passes. The checks compare `gen-a`'s last departure of 04:30 with
      # `mon-lay`'s first arrival of 04:10 and call it an overlap, so the union is
      # invalid on one affected day.
      world =
        tods_world_fixture(extra_trips: [weekday_trip(), monday_layover_trip()])

      assert {:ok, preview} = preview(world)

      assert preview.blocks == []
      assert preview.assignments == %{}
      assert preview.counts.new_blocks == 0
      assert preview.counts.rejected_blocks == 1

      # Both moves go, on both days. Clipping rather than rejecting would have kept
      # `gen-a` on its own on the weekday day type; half a chain is not a smaller
      # wrong answer, it is the same wrong answer with fewer rows to explain it.
      assert by_trip_id(world, preview.exclusions) == [
               {"gen-a", :invalid_cross_day},
               {"mon-lay", :invalid_cross_day}
             ]

      assert preview.preserved_block_ids == ["101", "102"]
    end

    test "the same chain with no invalid day is kept whole" do
      # The control for the case above: the identical two trips, with the Monday
      # arrival moved out of `gen-a`'s departure, chain validly on both days and
      # are presented as one block carrying both day types.
      world =
        tods_world_fixture(extra_trips: [weekday_trip(), clear_monday_trip()])

      assert {:ok, preview} = preview(world)

      assert [%{block_id: "103", trips: trips, day_type_keys: day_type_keys}] = preview.blocks
      assert Enum.map(trips, & &1.trip_id) == ["gen-a", "mon-clear"]
      assert day_type_keys == Enum.sort(preview.day_type_keys)
      assert preview.counts.rejected_blocks == 0
      assert preview.exclusions == []
      assert preview.counts.new_assignments == 2
    end

    test "an existing block is preserved and takes no new work" do
      world = tods_world_fixture(extra_trips: [weekday_trip()])

      assert {:ok, preview} = preview(world)

      # `preserved_block_ids` names every block the run read, whether or not the
      # checks like it, and the fixture's own blocks are untouched in the database.
      assert preview.preserved_block_ids == ["101", "102"]

      for {_block_id, trips} <- world.blocks, trip <- trips do
        assert stored_block_id(world, trip.id) == trip.block_id
      end
    end

    test "a new move onto a block invalid on a date outside the range is refused" do
      world = tods_world_fixture(extra_trips: [chained_schedule_trip()])
      generator_block_fixture(world)
      out_of_range_block_conflict_fixture(world)

      # Block "201"'s Saturday work overlaps itself, and the selected Monday-to-Friday
      # range holds no Saturday: the day type is *affected* — the block runs on it —
      # without being selected. The weekday move onto "201" goes with the block it
      # would join, which a trip's single stored `block_id` makes unavoidable.
      assert {:ok, preview} = TodsGenerator.preview(world.audit, weekday_inputs(world))

      assert Enum.sort(preview.day_type_keys) ==
               Enum.sort([world.weekday_day_type, world.monday_day_type])

      assert preview.blocks == []
      assert preview.assignments == %{}
      assert preview.counts.rejected_blocks == 1

      assert by_trip_id(world, preview.exclusions) == [{"gen-chain", :invalid_cross_day}]
    end

    test "the same move is accepted when the block is valid on every affected day" do
      # The control for the case above: the identical weekday trip and the identical
      # existing block, in a version whose block "201" has no conflicting Saturday
      # work. The generator chains the trip onto "201", so the refusal above is the
      # out-of-range day and not a move the run would never have made.
      world = tods_world_fixture(extra_trips: [chained_schedule_trip()])
      generator_block_fixture(world)

      assert {:ok, preview} = TodsGenerator.preview(world.audit, weekday_inputs(world))

      assert preview.assignments == %{trip_uuid(world, "gen-chain") => "201"}
      assert preview.counts.new_assignments == 1
      assert preview.counts.rejected_blocks == 0
      assert preview.counts.preserved_blocks == 3
      assert preview.blocks == []
      assert preview.exclusions == []
    end
  end

  describe "refusals" do
    test "a garage of another organization is a field error" do
      world = tods_world_fixture()
      foreign = foreign_scope_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               preview(world, %{"garage_id" => foreign.garage.id})

      assert {"must be a garage in this organization", _opts} = changeset.errors[:garage_id]
    end

    test "a garage of no organization is the same refusal" do
      world = tods_world_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               preview(world, %{"garage_id" => Ecto.UUID.generate()})

      assert {"must be a garage in this organization", _opts} = changeset.errors[:garage_id]
    end

    test "a staging version is :not_found" do
      world = tods_world_fixture()
      staging = staging_version_fixture(world)

      # `Calendars.list_calendars/3` refuses the staging version by rolling its
      # read back, and the snapshot reports that rollback; the reason a page is
      # given is the `:not_found` that refusal means.
      assert {:error, :not_found} = TodsGenerator.preview(staging.audit, tods_inputs(world))
    end

    test "a version of another organization is :not_found" do
      world = tods_world_fixture()
      foreign = foreign_scope_fixture()

      # The foreign actor asking for the world's version: the scope is the actor's
      # organization and the version's organization, and the version is not the
      # former's.
      forged = %AuditContext{
        actor_id: foreign.audit.actor_id,
        organization_id: foreign.organization.id,
        gtfs_version_id: world.version.id
      }

      assert {:error, :not_found} = TodsGenerator.preview(forged, tods_inputs(world))
    end

    test "an organization with no garage is :missing_garages" do
      world = tods_world_fixture()
      scope = garage_less_scope_fixture()

      # The garage is a real one, of the world rather than of the scope: the
      # refusal is that this organization holds no garage at all, not that the
      # named one is foreign.
      inputs = %{tods_inputs(world) | "garage_id" => world.garage.id}

      assert {:error, :missing_garages} = TodsGenerator.preview(scope.audit, inputs)
    end

    test "a range with no active service is an explicit no-work result" do
      world = tods_world_fixture()

      # The fixture's calendars run 2026-01-01 through 2026-12-31, so the Monday
      # week of 2027-01-04 is in no day type at all. Nothing to place is an
      # answer, not a failure.
      inputs = %{
        "start_date" => "2027-01-04",
        "end_date" => "2027-01-10",
        "representative_week" => "2027-01-04",
        "garage_id" => world.garage.id,
        "terminal_relief?" => false
      }

      assert {:ok, preview} = TodsGenerator.preview(world.audit, inputs)

      assert preview.no_work? == true
      assert preview.blocks == []
      assert preview.assignments == %{}
      assert preview.exclusions == []
      assert preview.day_type_keys == []
      assert preview.counts.blocks == 0
    end

    test "an actor who is no longer an editor is :forbidden" do
      world = tods_world_fixture()

      membership = Accounts.get_user_org_membership(world.audit.actor_id, world.organization.id)
      deactivate_membership_fixture(membership)

      assert {:error, :forbidden} = preview(world)
    end
  end

  describe "no writes" do
    test "a preview leaves every table it could reach unchanged" do
      world = tods_world_fixture(extra_trips: [weekday_trip(), clear_monday_trip()])
      before = planning_row_counts(world)

      assert {:ok, _preview} = preview(world)
      assert planning_row_counts(world) == before

      # The refusals write nothing either.
      foreign = foreign_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = preview(world, %{"garage_id" => foreign.garage.id})
      assert planning_row_counts(world) == before

      {organization_id, version_id, audit, inputs} = bulk_scope(world)
      bulk_day(organization_id, version_id, 3_001)
      assert {:error, {:too_large, 3001}} = TodsGenerator.preview(audit, inputs)
      assert planning_row_counts(world) == before
    end
  end

  # --- the fixture's own trips ------------------------------------------------

  # One unblocked weekday trip, before the fixture's earliest existing trip, so no
  # existing block can be chained to it and the generator has to open one. It runs
  # on both derived day types.
  defp weekday_trip, do: {"gen-a", "WK", "RIV", "RIV", "04:00:00", "04:30:00"}

  # A weekday trip the generator chains onto the case's own existing block rather
  # than opening one for it: it is on the extra route, and it departs after that
  # block's last arrival with the drive and the minimum layover in between.
  defp chained_schedule_trip, do: {"gen-chain", "WK", "RIV", "RIV", "15:40:00", "16:10:00"}

  # A Monday trip whose arrival is inside the trip above's span and whose departure
  # is outside it. The generator chains it on the 15-minute gap after `gen-a`, and
  # the checks refuse the overlap: the chain is valid per day and invalid as a union.
  defp monday_layover_trip,
    do: {"mon-lay", "MO", "RIV", "RIV", {"04:10:00", "04:45:00"}, "05:15:00"}

  # The same Monday trip arriving after `gen-a` has finished, so the chain is valid
  # on every day and nothing is refused.
  defp clear_monday_trip, do: {"mon-clear", "MO", "RIV", "RIV", "04:45:00", "05:15:00"}

  # The same canonical map `preview/2` builds internally, read through `Input` so
  # the permutation case compares against the real normalization rather than a
  # hand-written stand-in.
  defp normalized_inputs(world) do
    dates = active_dates(world.organization.id, world.version.id)

    assert {:ok, normalized} =
             TodsGenerator.Input.normalize(
               TodsGenerator.Input.changeset(%TodsGenerator.Input{}, tods_inputs(world), dates)
             )

    normalized
  end

  # The Monday-to-Friday range of the version's first full active week: a range
  # that holds no Saturday, so the fixture's Saturday day type is affected without
  # being selected. The fixture's first active date is a Thursday, so the week its
  # own default range names starts before any Monday has weekday service.
  defp weekday_inputs(world) do
    monday = Date.add(first_active_week(world), 7)

    tods_inputs(world, %{
      "start_date" => Date.to_iso8601(monday),
      "end_date" => Date.to_iso8601(Date.add(monday, 4)),
      "representative_week" => Date.to_iso8601(monday)
    })
  end

  defp day_type_keys(%{rows_by_day_type: rows}), do: rows |> Map.keys() |> Enum.sort()

  defp candidate_inputs(world, day_types) do
    Blocking.candidate_input(
      world.organization.id,
      world.version.id,
      Enum.map(day_types, & &1.key)
    )
  end

  defp stored_block_id(world, trip_id) do
    Repo.one!(
      Ecto.Query.from(t in GtfsPlanner.Gtfs.Trip,
        where: t.id == ^trip_id and t.organization_id == ^world.organization.id,
        select: t.block_id
      )
    )
  end

  defp trip_uuid(world, trip_id), do: Map.fetch!(world.trip_ids, trip_id)

  # Moves a trip's endpoint stop times behind its back, the way a schedule edit
  # outside this feature would. It writes rows this feature does not own, which is
  # what makes the fingerprint's claim about changed source facts testable here.
  defp retime(world, trip_id, first, last) do
    uuid = trip_uuid(world, trip_id)

    {1, nil} =
      Repo.update_all(
        Ecto.Query.from(s in GtfsPlanner.Gtfs.StopTime,
          where: s.trip_id == ^trip_id and s.stop_sequence == 1
        ),
        set: [arrival_time: first, departure_time: first]
      )

    {1, nil} =
      Repo.update_all(
        Ecto.Query.from(s in GtfsPlanner.Gtfs.StopTime,
          where: s.trip_id == ^trip_id and s.stop_sequence == 2
        ),
        set: [arrival_time: last, departure_time: last]
      )

    _ = uuid
  end

  # The exclusions are keyed by trip UUID and sorted by it, which is the identity a
  # consumer looks them up by. This reads them back as the fixture's own `trip_id`
  # strings so the assertion says which trips were refused rather than which
  # opaque UUIDs.
  defp by_trip_id(world, exclusions) do
    names = Map.new(world.trip_ids, fn {trip_id, uuid} -> {uuid, trip_id} end)

    exclusions
    |> Enum.map(fn %{subject: uuid, reason: reason} -> {Map.fetch!(names, uuid), reason} end)
    |> Enum.sort()
  end

  defp sum_trip_count(day_types, inputs) do
    day_types
    |> Enum.map(fn day_type ->
      inputs.rows_by_day_type |> Map.fetch!(day_type.key) |> length()
    end)
    |> Enum.sum()
  end

  defp reverse_rows(%{rows_by_day_type: rows} = inputs),
    do: %{
      inputs
      | rows_by_day_type: Map.new(rows, fn {key, list} -> {key, Enum.reverse(list)} end)
    }

  defp shuffled_rows(%{rows_by_day_type: rows} = inputs, seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    reverse? = rem(seed, 2) == 0

    %{
      inputs
      | rows_by_day_type:
          Map.new(rows, fn {key, list} ->
            shuffled = Enum.sort_by(list, fn _ -> :rand.uniform() end)
            ordered = if(reverse?, do: Enum.reverse(shuffled), else: shuffled)
            {key, ordered}
          end)
    }
  end

  # --- the bound's own scope --------------------------------------------------

  # A version of its own, so the bulk day is the whole scope and nothing the shared
  # world built is counted with it. The garage is the world's, because a version
  # with no garage is refused before the bound is ever reached.
  defp bulk_scope(world) do
    version = gtfs_version_fixture(world.organization.id, %{name: "Bulk"})

    calendar_service_fixture(world.organization.id, version.id, %{
      service_id: "BULK",
      name: "Bulk",
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    inputs = %{
      "start_date" => "2026-01-05",
      "end_date" => "2026-01-11",
      "representative_week" => "2026-01-05",
      "garage_id" => world.garage.id,
      "terminal_relief?" => false
    }

    audit = editor_audit_fixture(world.organization, version)

    {audit.organization_id, version.id, audit, inputs}
  end

  # One trip inside the range and one outside it in the same block: the active
  # trip is what touches the block, the December trip is the one completing it
  # reaches. The December service runs on the default 2026 calendar, so its day
  # type holds no date of the selected January range.
  defp block_with_out_of_range_companion!(organization_id, version_id) do
    calendar_service_fixture(organization_id, version_id, %{
      service_id: "DEC",
      name: "December",
      start_date: ~D[2026-12-01],
      end_date: ~D[2026-12-31]
    })

    insert_chunked!(GtfsPlanner.Gtfs.Trip, [
      organization_id |> bulk_trip(version_id, "BCOMP-A") |> Map.put(:block_id, "BCOMP"),
      organization_id
      |> bulk_trip(version_id, "BCOMP-DEC")
      |> Map.put(:service_id, "DEC")
      |> Map.put(:block_id, "BCOMP")
    ])
  end

  # Trips with no stop times, so the bound is proved on the count rather than on
  # what a 3,000-trip chain would compose. The generator still reads every one of
  # them and reports each; it cannot place them, and it says so per trip.
  defp bulk_day(organization_id, version_id, count) do
    trips = Enum.map(1..count, &bulk_trip(organization_id, version_id, "B#{&1}"))

    insert_chunked!(GtfsPlanner.Gtfs.Trip, trips)
    Repo.query!("ANALYZE trips")

    %{trips: length(trips)}
  end

  defp bulk_trip(organization_id, version_id, trip_id) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: version_id,
      trip_id: trip_id,
      route_id: "BULK_R",
      service_id: "BULK",
      block_id: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp insert_chunked!(schema, rows) do
    rows
    |> Enum.chunk_every(5_000)
    |> Enum.each(fn chunk ->
      {written, nil} = Repo.insert_all(schema, chunk)
      assert written == length(chunk)
    end)
  end
end
