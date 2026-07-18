defmodule GtfsPlanner.Gtfs.Import.RunTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.OrganizationsFixtures

  @count_allowlist ~w(
    agencies feed_info levels areas networks fare_media rider_categories booking_rules
    locations routes calendars calendar_dates route_patterns route_networks
    fare_attributes fare_rules fare_products timeframes trips stops pathways
    transfers stop_areas frequencies attributions fare_leg_rules
    fare_leg_join_rules fare_transfer_rules translations stop_times shapes
    extensions_stop_coordinates extensions_stop_levels extensions_route_flags
    extensions_images
  )a

  describe "state accessors" do
    test "states/0 returns the full documented set" do
      assert Run.states() ==
               ~w(pending running failed partial interrupted publication_failed published cleaning cleanup_failed cleaned)
    end

    test "recoverable_states/0 excludes pending, running, published, and cleaned" do
      assert Run.recoverable_states() ==
               ~w(failed partial interrupted publication_failed cleaning cleanup_failed)
    end

    test "active_states/0 is the lease-holding states" do
      assert Run.active_states() == ~w(pending running cleaning)
    end
  end

  describe "changeset/2 committed_counts validation" do
    setup do
      org = OrganizationsFixtures.organization_fixture()
      run = %Run{organization_id: org.id}
      %{run: run}
    end

    test "rejects an unsupported committed_counts key", %{run: run} do
      changeset = Run.changeset(run, %{committed_counts: %{bogus_key: 3}})

      refute changeset.valid?
      assert "contains unsupported key(s)" in errors_on(changeset).committed_counts
    end

    test "accepts every allowed committed_counts key", %{run: run} do
      counts = Map.new(@count_allowlist, fn key -> {key, 0} end)
      changeset = Run.changeset(run, %{committed_counts: counts})

      assert changeset.valid?, inspect(errors_on(changeset))
    end

    test "rejects a negative committed count value", %{run: run} do
      changeset = Run.changeset(run, %{committed_counts: %{routes: -1}})

      refute changeset.valid?
      assert "values must be non-negative integers" in errors_on(changeset).committed_counts
    end

    test "rejects failed_row <= 0 when present", %{run: run} do
      changeset = Run.changeset(run, %{failed_row: 0})

      refute changeset.valid?
      assert "must be positive" in errors_on(changeset).failed_row
    end

    test "accepts a positive failed_row", %{run: run} do
      changeset = Run.changeset(run, %{failed_row: 42})
      assert changeset.valid?, inspect(errors_on(changeset))
    end

    test "enforces sanitized field length bounds", %{run: run} do
      long = String.duplicate("a", 256)

      changeset = Run.changeset(run, %{reason_code: long, actor_email: long, phase: long})
      errors = errors_on(changeset)

      assert errors[:reason_code]
      assert errors[:actor_email]
      assert errors[:phase]
    end

    test "accepts bounded field values", %{run: run} do
      changeset =
        Run.changeset(run, %{
          reason_code: "phase_2_error",
          actor_email: "ops@example.com",
          phase: "phase_2"
        })

      assert changeset.valid?, inspect(errors_on(changeset))
    end
  end
end
