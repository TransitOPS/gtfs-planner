defmodule GtfsPlanner.Agents.Packs.OperationsBlockProjectionTest do
  @moduledoc """
  The block-day projection's observable contract: the payload an operations helper
  session reads over one loaded Blocks day.

  `GtfsPlanner.Gtfs.OperationsAssistance.block_day/2` is called on the real
  `GtfsPlanner.Gtfs.Blocking.load_day/3` result, so every expected code, severity,
  detail value and second below is the domain's own answer, read through the
  production load and the production checks. Nothing here derives an expectation
  from the projection itself: the seconds are the clock values the fixtures
  store, the 600-second gap is the two endpoint clocks' difference, and the
  unknown drive is the unknown a stop without coordinates produces.

  The cases follow the step's own obligations:

  - block 101's two services disagreeing about its garage is one
    `:block_attributes_conflict` warning whose rows are the stored attribute
    rows, and route 30 requiring the diesel against the block's own Cutaway is a
    `:type_mismatch` error on each of the block's trips; block 9's move between
    two stops with no coordinates keeps its `:repositions` notice with
    `drive: :unknown` and raises no reach claim about it;
  - a frequency-based trip and an unplottable trip stay explicit exclusions and
    keep their notice codes, and a sentinel employee field planted in the loaded
    input - on a trip row, on a finding, in the settings - is absent from the
    serialized payload, so the copy is an allowlist rather than the loaded day;
  - the weekday and school day types of one version project distinct day refs,
    distinct trip refs for the same trip and distinct source digests, while a
    day with no selected day type, a value that is not a loaded day, and a forged
    or malformed selection are each `:unavailable` rather than another scope;
  - a selection of block 101 alone is an explicitly scoped subset: its own
    totals, its own completeness, the exact refs it keeps, and block 9 and its
    trips named as `outside_scope` exclusions rather than dropped.

  Rows are created inside the SQL Sandbox transaction and rolled back. The focused
  gate command is handed to branch review:
  `mix test test/gtfs_planner/agents/packs/operations_block_projection_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.OperationsAssistance

  # The two school weekdays inside `WEEKDAY`'s Mon-Fri year, so the version derives
  # `{SCHOOL, WEEKDAY}` on those two dates and `{WEEKDAY}` on every other weekday.
  @school_dates [~D[2026-09-01], ~D[2026-09-02]]

  @sentinel "OPERATOR-SENTINEL"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "30", route_short_name: "30"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      name: "Weekday",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SCHOOL",
      name: "School",
      dates: @school_dates
    })

    # One stop every trip of block 101 uses, so its gap is a layover at the same
    # stop and the block's findings are the type and attribute ones under test.
    stop_fixture(organization.id, version.id, %{stop_id: "S1"})

    # The two stops of block 9 carry no coordinates, which is what makes its move
    # an unknown one rather than a measured empty move.
    for stop_id <- ["UNK_A", "UNK_B"] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_lat: nil, stop_lon: nil})
    end

    main = garage(organization, "Main")
    yard = garage(organization, "Yard")
    cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})
    diesel = vehicle_type_fixture(organization.id, %{"name" => "35-ft diesel"})

    # Route 30 requires the diesel, so block 101 - a Cutaway in Main on the
    # weekday and in Yard on the school day - is one type mismatch per trip and
    # one attribute conflict over the two disagreeing rows.
    route_operating_setting_fixture(organization.id, version.id, %{
      route_id: "30",
      required_vehicle_type_id: diesel.id
    })

    block_attribute_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      block_id: "101",
      garage_id: main.id,
      vehicle_type_id: cutaway.id
    })

    block_attribute_fixture(organization.id, version.id, %{
      service_id: "SCHOOL",
      block_id: "101",
      garage_id: yard.id,
      vehicle_type_id: cutaway.id
    })

    %{
      organization: organization,
      version: version,
      route: route,
      main: main,
      yard: yard,
      cutaway: cutaway,
      diesel: diesel,
      school_key: DayTypes.key(["SCHOOL", "WEEKDAY"]),
      weekday_key: DayTypes.key(["WEEKDAY"])
    }
  end

  describe "a garage and type conflict over the loaded findings" do
    test "copies the exact code, severity and detail of every finding", context do
      seed_conflicting_block(context)

      payload = project!(load_day!(context, context.school_key), %{})

      assert payload["schema_version"] == 1
      assert payload["section"] == "blocks"
      assert payload["day_key"] == context.school_key
      assert payload["completeness"] == "complete"
      assert payload["scope"]["mode"] == "whole_day"
      assert payload["plan"] == nil

      # One type mismatch per trip of the block, each naming its own trip.
      assert [first, second] = issues(payload, "type_mismatch")
      assert first["severity"] == "error"
      assert second["severity"] == "error"
      assert first["trip_refs"] != second["trip_refs"]

      block_trip_refs =
        Enum.map([trip_entity(payload, "wk_1"), trip_entity(payload, "sc_1")], & &1["trip_ref"])

      for issue <- [first, second] do
        assert issue["block_id"] == "101"

        assert issue["detail"] == %{
                 "vehicle_type_id" => context.cutaway.id,
                 "required_vehicle_type_id" => context.diesel.id
               }

        assert length(issue["trip_refs"]) == 1
        assert issue["trip_refs"] in Enum.map(block_trip_refs, &[&1])
      end

      assert Enum.sort(first["trip_refs"] ++ second["trip_refs"]) == Enum.sort(block_trip_refs)

      # The two disagreeing attribute rows are one conflict warning naming the
      # rows themselves, in `Context.resolve_block/3`'s own `service_id` order.
      assert [conflict] = issues(payload, "block_attributes_conflict")
      assert conflict["severity"] == "warning"
      assert conflict["block_id"] == "101"

      assert conflict["detail"] == %{
               "rows" => [
                 %{
                   "garage_id" => context.yard.id,
                   "service_id" => "SCHOOL",
                   "vehicle_type_id" => context.cutaway.id
                 },
                 %{
                   "garage_id" => context.main.id,
                   "service_id" => "WEEKDAY",
                   "vehicle_type_id" => context.cutaway.id
                 }
               ]
             }

      # An unknown drive keeps its unknown status and its gap: it is never turned
      # into a measured second, and the day raises no reach claim about it.
      assert [unknown] = issues(payload, "repositions")
      assert unknown["severity"] == "notice"
      assert unknown["block_id"] == "9"
      assert unknown["detail"] == %{"gap_secs" => 600, "meters" => nil, "drive" => "unknown"}
      refute "cannot_reach" in Enum.map(payload["issues"], & &1["code"])

      assert payload["totals"] == %{
               "block_attributes_conflict" => 1,
               "repositions" => 1,
               "type_mismatch" => 2
             }

      # The stored rules and the ids the findings resolve against travel with the
      # copy, and the block's own resolution is the one the checks used.
      assert payload["constraints"]["planning_inputs"] == true
      assert payload["constraints"]["settings"]["min_layover_minutes"] == 5
      assert payload["constraints"]["settings"]["interlining"] == "any"

      assert Enum.sort(payload["constraints"]["garages"]) ==
               Enum.sort([
                 %{"garage_id" => context.main.id},
                 %{"garage_id" => context.yard.id}
               ])

      assert block_entity(payload, "101")["garage_id"] == context.main.id
      assert block_entity(payload, "101")["vehicle_type_id"] == context.cutaway.id
      assert block_entity(payload, "101")["garage_source"] == "attribute"
      assert block_entity(payload, "9")["garage_id"] == nil

      # The trips' exact parsed seconds, in service-day seconds.
      weekday_trip = trip_entity(payload, "wk_1")
      assert weekday_trip["service_id"] == "WEEKDAY"
      assert weekday_trip["route_id"] == "30"
      assert weekday_trip["block_ref"] == block_entity(payload, "101")["block_ref"]

      assert {weekday_trip["first_departure_secs"], weekday_trip["last_arrival_secs"]} ==
               {8 * 3600, 9 * 3600}

      school_trip = trip_entity(payload, "sc_1")

      assert {school_trip["first_departure_secs"], school_trip["last_arrival_secs"]} ==
               {12 * 3600, 13 * 3600}

      assert payload["day_ref"] =~ ~r/\Aday_[0-9a-f]{32}\z/
      assert payload["source_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "an explicit selection scopes the evidence and discloses what it leaves out", context do
      seed_conflicting_block(context)

      payload = project!(load_day!(context, context.school_key), %{selected_block_ids: ["101"]})

      assert payload["completeness"] == "scoped"

      assert payload["selection"] == %{
               "selected_block_refs" => [block_entity(payload, "101")["block_ref"]],
               "selected_trip_refs" => []
             }

      assert payload["scope"] == %{
               "mode" => "explicit_subset",
               "block_refs" => [block_entity(payload, "101")["block_ref"]],
               "trip_refs" => []
             }

      assert payload["totals"] == %{"block_attributes_conflict" => 1, "type_mismatch" => 2}
      assert Enum.map(payload["issues"], & &1["block_id"]) == ["101", "101", "101"]
      assert Enum.map(payload["entities"]["blocks"], & &1["block_id"]) == ["101"]
      assert Enum.map(payload["entities"]["trips"], & &1["trip_id"]) == ["wk_1", "sc_1"]

      excluded_blocks = Enum.filter(payload["exclusions"], &Map.has_key?(&1, "block_ref"))
      excluded_trips = Enum.filter(payload["exclusions"], &Map.has_key?(&1, "trip_ref"))

      # The excluded block keeps a receipt of its own and no entity: a ref outside
      # this scope resolves to nothing in it.
      assert [%{"kind" => "outside_scope", "block_ref" => excluded_block_ref}] = excluded_blocks
      assert is_binary(excluded_block_ref)
      refute Enum.any?(payload["entities"]["blocks"], &(&1["block_ref"] == excluded_block_ref))

      # A trip outside the scope has no entity here, so its receipt is checked
      # against the whole-day projection of the same day, which names it.
      whole = project!(load_day!(context, context.school_key), %{})
      unknown_refs = Enum.map(["unknown_a", "unknown_b"], &trip_entity(whole, &1)["trip_ref"])

      assert Enum.all?(unknown_refs, &is_binary/1)
      assert Enum.map(excluded_trips, & &1["trip_ref"]) == unknown_refs
    end

    test "the pool and a selected loose trip are named by non-null refs", context do
      seed_conflicting_block(context)
      seed_repeat_and_untimed(context)

      day = load_day!(context, context.school_key)
      whole = project!(day, %{})
      untimed_ref = trip_entity(whole, "untimed")["trip_ref"]

      # The whole day's scope lists the pool - the trips no block holds - by the
      # same refs its trip entities carry.
      assert is_binary(untimed_ref)
      assert whole["scope"]["trip_refs"] == [untimed_ref]

      scoped = project!(day, %{selected_trip_ids: ["untimed"]})

      assert scoped["selection"]["selected_trip_refs"] == [untimed_ref]
      assert scoped["scope"]["trip_refs"] == [untimed_ref]
      assert Enum.map(scoped["entities"]["trips"], & &1["trip_ref"]) == [untimed_ref]

      # The selected trip is unplottable, so it is named once as such and never
      # as outside its own scope.
      assert Enum.filter(scoped["exclusions"], &(&1["trip_ref"] == untimed_ref)) == [
               %{"kind" => "unplottable", "trip_ref" => untimed_ref, "block_ref" => nil}
             ]
    end

    test "a subset names trips outside it once, as outside its scope", context do
      seed_conflicting_block(context)
      seed_repeat_and_untimed(context)

      day = load_day!(context, context.school_key)
      whole = project!(day, %{})
      scoped = project!(day, %{selected_block_ids: ["9"]})

      # The repeated and the untimed trip are not in block 9, so the subset lists
      # neither as unsequenced: each is one `outside_scope` exclusion.
      kinds = scoped["exclusions"] |> Enum.map(& &1["kind"]) |> Enum.uniq()
      assert kinds == ["outside_scope"]

      for trip_id <- ["repeat", "untimed"] do
        ref = trip_entity(whole, trip_id)["trip_ref"]

        assert Enum.filter(scoped["exclusions"], &(&1["trip_ref"] == ref)) == [
                 %{"kind" => "outside_scope", "trip_ref" => ref}
               ]
      end
    end
  end

  describe "a stay-on-board record into another day type" do
    test "a weekday trip continuing into Saturday keeps the weekday day readable", context do
      calendar_service_fixture(context.organization.id, context.version.id, %{
        service_id: "SATURDAY",
        name: "Saturday",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 0
      })

      friday =
        trip(context, %{trip_id: "fri_night", block_id: "7", first: "23:00:00", last: "23:50:00"})

      saturday =
        trip(context, %{
          trip_id: "sat_early",
          service_id: "SATURDAY",
          block_id: "8",
          first: "00:10:00",
          last: "01:00:00"
        })

      in_seat_transfer_fixture(context.organization.id, context.version.id, friday, saturday)

      # The two trips share no date and Saturday runs the day after a weekday,
      # so the record is `{:unconfirmed, :next_service_day}` on the weekday.
      payload = project!(load_day!(context, context.weekday_key), %{})

      assert [record] = issues(payload, "in_seat_unconfirmed")
      assert record["detail"] == %{"reason" => "next_service_day"}
      assert record["trip_refs"] == [trip_entity(payload, "fri_night")["trip_ref"]]
      assert record["other_day_trip_ids"] == ["sat_early"]
      refute trip_entity(payload, "sat_early")
    end
  end

  describe "trips no block sequence can carry" do
    test "a frequency trip and an unplottable trip stay explicit exclusions", context do
      seed_conflicting_block(context)
      seed_repeat_and_untimed(context)

      payload = project!(load_day!(context, context.school_key), %{})

      assert [repetition] = issues(payload, "frequency_trip")
      assert repetition["severity"] == "notice"
      assert repetition["block_id"] == "101"
      assert repetition["detail"] == %{"headway_secs" => 1_800}
      assert repetition["trip_refs"] == [trip_entity(payload, "repeat")["trip_ref"]]

      assert [missing] = issues(payload, "unplottable")
      assert missing["severity"] == "notice"
      assert missing["block_id"] == nil
      assert missing["detail"] == %{}
      assert missing["trip_refs"] == [trip_entity(payload, "untimed")["trip_ref"]]

      assert Enum.filter(payload["exclusions"], &(&1["kind"] == "frequency_trip")) == [
               %{
                 "kind" => "frequency_trip",
                 "trip_ref" => trip_entity(payload, "repeat")["trip_ref"],
                 "block_ref" => block_entity(payload, "101")["block_ref"],
                 "headway_secs" => 1_800
               }
             ]

      assert [%{"kind" => "unplottable", "trip_ref" => untimed_ref, "block_ref" => nil}] =
               Enum.filter(payload["exclusions"], &(&1["kind"] == "unplottable"))

      assert untimed_ref == trip_entity(payload, "untimed")["trip_ref"]

      # The repeated trip is a trip of the day like any other: it is carried as an
      # entity and named as one, and the block's own checks still exclude it.
      assert trip_entity(payload, "repeat")["frequency?"] == true

      assert trip_entity(payload, "repeat")["block_ref"] ==
               block_entity(payload, "101")["block_ref"]

      assert trip_entity(payload, "untimed")["plottable?"] == false
    end

    test "an employee field planted in the loaded input never reaches the payload", context do
      seed_conflicting_block(context)
      seed_repeat_and_untimed(context)

      day = load_day!(context, context.school_key)

      # The sentinels stand in for the personnel an operator change record or an
      # arbitrary metadata note would carry if the copy were the loaded day.
      seeded =
        day
        |> Map.update!(:settings, &Map.put(&1, :operator_note, @sentinel))
        |> Map.update!(:findings, fn findings ->
          Enum.map(findings, fn finding ->
            finding
            |> Map.put(:employee_name, @sentinel)
            |> put_in([:detail, :employee_id], @sentinel)
          end)
        end)
        |> Map.update!(:pool, fn pool ->
          Enum.map(pool, &Map.put(&1, :employee_name, @sentinel))
        end)
        |> Map.update!(:blocks, fn blocks ->
          Enum.map(blocks, fn block ->
            %{
              block
              | trips: [Map.put(hd(block.trips), :employee_name, @sentinel) | tl(block.trips)]
            }
          end)
        end)

      payload = project!(seeded, %{})
      encoded = Jason.encode!(payload)

      refute encoded =~ @sentinel
      refute encoded =~ "employee"
      refute encoded =~ "operator_note"
    end
  end

  describe "the day the session is bound to" do
    test "a weekday and a school day project distinct refs and digests", context do
      seed_conflicting_block(context)

      school = project!(load_day!(context, context.school_key), %{})
      weekday = project!(load_day!(context, context.weekday_key), %{})

      assert school["day_key"] == context.school_key
      assert weekday["day_key"] == context.weekday_key
      assert school["day_ref"] != weekday["day_ref"]
      assert school["source_digest"] != weekday["source_digest"]

      # The same trip, in the two day types, is two different receipts.
      assert trip_entity(weekday, "wk_1")["trip_ref"] != trip_entity(school, "wk_1")["trip_ref"]
      assert block_entity(weekday, "101")["block_ref"] != block_entity(school, "101")["block_ref"]

      # The school day type carries the one trip the weekday day type does not,
      # and its attribute rows agree with each other, so it raises no conflict.
      assert trip_entity(school, "sc_1")
      refute trip_entity(weekday, "sc_1")
      assert length(school["entities"]["trips"]) == length(weekday["entities"]["trips"]) + 1
      assert weekday["totals"]["type_mismatch"] == 1
      refute Map.has_key?(weekday["totals"], "block_attributes_conflict")
    end

    test "a day with no selected day type, and a selection the day cannot answer for, are unavailable",
         context do
      seed_conflicting_block(context)

      day = load_day!(context, context.school_key)

      # `load_day/3` selects the first day type for a nil key and returns
      # `day_type: nil` for a version whose calendars derive none; the helper
      # refuses both rather than naming another day.
      assert {:ok, first} = Blocking.load_day(context.organization.id, context.version.id, nil)
      assert first.day_type.key == context.school_key

      assert OperationsAssistance.block_day(Map.put(day, :day_type, nil), %{}) ==
               {:error, :unavailable}

      assert {:error, {:unknown_day_type, day_types}} =
               Blocking.load_day(context.organization.id, context.version.id, "no-such-day")

      assert [school_key, weekday_key] = Enum.map(day_types, & &1.key)
      assert {school_key, weekday_key} == {context.school_key, context.weekday_key}

      assert OperationsAssistance.block_day(Map.delete(day, :settings), %{}) ==
               {:error, :unavailable}

      assert OperationsAssistance.block_day(:not_a_day, %{}) == {:error, :unavailable}

      # A forged selection and a malformed one are refused, not repaired.
      assert OperationsAssistance.block_day(day, %{selected_block_ids: ["404"]}) ==
               {:error, :unavailable}

      assert OperationsAssistance.block_day(day, %{selected_trip_ids: ["nope"]}) ==
               {:error, :unavailable}

      assert OperationsAssistance.block_day(day, %{selected_block_ids: "101"}) ==
               {:error, :unavailable}

      assert OperationsAssistance.block_day(day, %{
               "block_ids" => ["101"],
               selected_block_ids: ["101"]
             }) ==
               {:error, :unavailable}

      assert OperationsAssistance.block_day(day, nil) == {:error, :unavailable}
    end
  end

  # --- fixtures ----------------------------------------------------------

  # Block 101 runs two services at two times of the day - its weekday and school
  # trips disagree about its garage, which is the conflict under test - and block 9
  # moves between two stops with no coordinates, which is the unknown drive.
  defp seed_conflicting_block(context) do
    trip(context, %{
      trip_id: "wk_1",
      service_id: "WEEKDAY",
      block_id: "101",
      first: "08:00:00",
      last: "09:00:00"
    })

    trip(context, %{
      trip_id: "sc_1",
      service_id: "SCHOOL",
      block_id: "101",
      first: "12:00:00",
      last: "13:00:00"
    })

    trip(context, %{
      trip_id: "unknown_a",
      block_id: "9",
      first_stop: "UNK_A",
      last_stop: "UNK_A",
      first: "08:00:00",
      last: "09:00:00"
    })

    trip(context, %{
      trip_id: "unknown_b",
      block_id: "9",
      first_stop: "UNK_B",
      last_stop: "UNK_B",
      first: "09:10:00",
      last: "10:00:00"
    })
  end

  # One trip a frequency row makes a repeat and one trip with no last time, which
  # is the two kinds of trip no block sequence carries.
  defp seed_repeat_and_untimed(context) do
    repeat =
      trip(context, %{trip_id: "repeat", block_id: "101", first: "16:00:00", last: "16:30:00"})

    trip(context, %{trip_id: "untimed", first: "08:00:00", last: nil})

    frequency_row_fixture(context.organization.id, context.version.id, %{
      trip_id: repeat.trip_id,
      headway_secs: 1_800
    })
  end

  defp trip(context, attrs) do
    attrs = Map.new(attrs)
    {first, attrs} = Map.pop(attrs, :first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.route.route_id,
      attrs
      |> Map.put_new(:service_id, "WEEKDAY")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  defp garage(organization, name) do
    garage_fixture(organization.id, %{
      "name" => name,
      "lat" => Decimal.new("40.0400"),
      "lon" => Decimal.new("-74.0")
    })
  end

  # --- reads --------------------------------------------------------------

  defp load_day!(context, day_key) do
    assert {:ok, day} = Blocking.load_day(context.organization.id, context.version.id, day_key)
    day
  end

  defp project!(day, selection) do
    assert {:ok, payload} = OperationsAssistance.block_day(day, selection)
    payload
  end

  defp issues(payload, code), do: Enum.filter(payload["issues"], &(&1["code"] == code))

  defp trip_entity(payload, trip_id), do: entity(payload["entities"]["trips"], "trip_id", trip_id)

  defp block_entity(payload, block_id),
    do: entity(payload["entities"]["blocks"], "block_id", block_id)

  defp entity(rows, key, technical_id) do
    Enum.find(rows, &(Map.get(&1, key) == technical_id))
  end
end
