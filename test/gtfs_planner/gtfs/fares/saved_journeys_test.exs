defmodule GtfsPlanner.Gtfs.Fares.SavedJourneysTest do
  @moduledoc """
  Merge evidence (EV-25) for `Fares.save_journey/2`,
  `Fares.accept_journey_price/3` and `Fares.delete_journey/2` (AC-33, R15, FH-25).

  Every expected value is worked by hand from
  `test/fixtures/gtfs/fares/north_coast_v2` and the GTFS reference, never read
  back from the code under test (CR-2):

  - Toledo (TOL) to Corvallis (COR) is the sample's Local-then-Intercity change
    on a Monday: Route 4 from `TOLEDO` to `NTC` is `Valley ride` at $2.50, and
    Route 10 from `NTC` to `CORVALLIS` is `Intercity ride` at $6.00. The change
    is paid as the difference R5's `N_LOCAL -> N_INTERCITY` row allows, which the
    setup writes through the production transfer writer, so the journey totals
    the Intercity fare, $6.00, not $8.50.
  - raising the Intercity ride to $7.00 for the adult paying cash moves that
    same journey to $7.00, because the difference the change pays is the new
    Intercity fare less the $2.50 already paid, and $7.00 covers it.
  - a ride on a route the version has no fare for is unpriced, so a journey
    holding one has no total to store as its expected amount.

  The version enters rows through the production importer and the production v2
  conversion, and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/3` with `Fares.Normalize.run!/2`
  before the commit, which is the path every writer of this package takes
  (INV-1). Every read here filters by `organization_id` and `gtfs_version_id`
  together (INV-5).
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlanner.Gtfs.FareSavedJourney
  alias GtfsPlanner.Repo

  # A Monday inside the sample's calendar span.
  @monday ~D[2026-10-05]

  # R5's `N_LOCAL -> N_INTERCITY` policy the sample's fares are edited under: the
  # change from Local routes to Intercity pays the difference, for 90 minutes
  # (`duration_limit` 5400, basis 1). R6 allows it because the Intercity fare of
  # $6.00 covers every origin amount, $5.00 being the largest.
  @difference %{pay: :difference, minutes: 90}

  setup do
    organization =
      organization_fixture(%{alias: "fares-journeys-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      user_fixture(%{
        email: "fares-journeys-#{System.unique_integer([:positive])}@example.com"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast fares editor"})
    import!(organization, version, "north_coast_v2")

    context = %{organization: organization, version: version}
    scope = scope(organization, version, actor)

    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])

    # The converted version carries the sample's single-group policies only, so
    # the Local-to-Intercity change this journey makes is written here, through
    # the production transfer writer, before the journey is priced.
    {:ok, _difference} = Transfers.save(scope, "N_LOCAL", "N_INTERCITY", @difference, nil)

    context
    |> Map.put(:scope, scope)
    |> Map.put(:actor, actor)
  end

  describe "saving a journey" do
    test "stores the journey with the total it priced", context do
      assert {:ok, result} = Fares.save_journey(context.scope, toledo_to_corvallis())
      assert result.operation_id

      saved = stored(context)
      assert saved.id == result.journey.id
      assert saved.name == "Toledo to Corvallis"
      assert saved.rider_category_id == "adult"
      assert saved.fare_media_id == "cash"
      assert saved.service_date == @monday

      # The journey prices $6.00: $2.50 for the Valley ride plus the $3.50 the
      # Intercity ride adds, not the $8.50 the two fares sum to.
      assert saved.expected_amount == Decimal.new("6.00")

      # The legs are stored whole, so the journey can be priced again without
      # being rebuilt.
      assert [%{"route_id" => "4"}, %{"route_id" => "10"}] = saved.legs

      assert [entry] = entries(context, result.operation_id)
      assert entry.entity_type == "fare_version"
      assert entry.action == "created"

      assert entry.changed_fields["summary"] == "Saved Toledo to Corvallis"

      assert entry.changed_fields["before"] == []

      assert entry.changed_fields["after"] == [
               %{
                 "fare_saved_journeys_id" => saved.id,
                 "name" => "Toledo to Corvallis",
                 "expected_amount" => "6.00"
               }
             ]
    end

    test "a journey no fare covers is refused and stores nothing", context do
      entries_before = entry_count(context)

      assert {:error, :no_price} =
               Fares.save_journey(
                 context.scope,
                 toledo_to_corvallis() |> Map.put(:legs, [unpriced_ride()])
               )

      assert stored(context) == nil

      # A journey with no rides at all prices nothing either, so it is refused
      # the same way rather than stored as an expected total of zero.
      assert {:error, :no_price} =
               Fares.save_journey(
                 context.scope,
                 toledo_to_corvallis() |> Map.put(:legs, [])
               )

      assert stored(context) == nil
      assert entry_count(context) == entries_before
    end

    test "a version that is not managed answers :unmanaged and stores nothing", context do
      organization = context.organization
      version = gtfs_version_fixture(organization.id, %{name: "Imported, never converted"})
      import!(organization, version, "north_coast_v2")

      other = Map.put(context, :version, version)

      assert {:error, :unmanaged} =
               Fares.save_journey(
                 scope(organization, version, context.actor),
                 toledo_to_corvallis()
               )

      assert stored(other) == nil
      assert entry_count(other) == 0
    end
  end

  describe "accepting a price after an edit" do
    test "stores the new total the journey now prices", context do
      assert {:ok, saved} = Fares.save_journey(context.scope, toledo_to_corvallis())
      assert saved.journey.expected_amount == Decimal.new("6.00")

      # The Intercity ride the second leg pays goes from $6.00 to $7.00, which
      # moves the journey with it: the difference is the new Intercity fare less
      # the $2.50 already paid, so the journey totals $7.00.
      assert {:ok, _changed} =
               Fares.save_prices(context.scope, [
                 %{
                   fare_product_id: "intercity_ride_adult_cash",
                   rider_category_id: "adult",
                   fare_media_id: "cash",
                   reviewed: Decimal.new("6.00"),
                   amount: Decimal.new("7.00")
                 }
               ])

      # The stored expectation is the old price, which is what makes the journey
      # read as `Price changed` until it is accepted.
      assert stored(context).expected_amount == Decimal.new("6.00")

      assert {:ok, accepted} =
               Fares.accept_journey_price(
                 context.scope,
                 saved.journey.id,
                 Decimal.new("7.00")
               )

      assert accepted.journey.expected_amount == Decimal.new("7.00")
      assert stored(context).expected_amount == Decimal.new("7.00")

      assert [entry] = entries(context, accepted.operation_id)

      assert entry.changed_fields["summary"] ==
               "Accepted the new price of \"Toledo to Corvallis\""

      assert entry.changed_fields["before"] == [
               %{
                 "fare_saved_journeys_id" => saved.journey.id,
                 "name" => "Toledo to Corvallis",
                 "expected_amount" => "6.00"
               }
             ]

      assert entry.changed_fields["after"] == [
               %{
                 "fare_saved_journeys_id" => saved.journey.id,
                 "name" => "Toledo to Corvallis",
                 "expected_amount" => "7.00"
               }
             ]
    end

    test "undoing an acceptance puts the previous amount back", context do
      assert {:ok, saved} = Fares.save_journey(context.scope, toledo_to_corvallis())

      assert {:ok, accepted} =
               Fares.accept_journey_price(
                 context.scope,
                 saved.journey.id,
                 Decimal.new("7.00")
               )

      assert {:ok, undone} =
               Fares.undo(context.scope, accepted.operation_id, accepted.inverse)

      assert undone.operation_id == accepted.operation_id
      assert stored(context).expected_amount == Decimal.new("6.00")
    end

    test "an acceptance made since is not reverted", context do
      assert {:ok, saved} = Fares.save_journey(context.scope, toledo_to_corvallis())
      id = saved.journey.id

      assert {:ok, first} =
               Fares.accept_journey_price(context.scope, id, Decimal.new("7.00"))

      assert {:ok, second} =
               Fares.accept_journey_price(context.scope, id, Decimal.new("8.00"))

      # The row no longer holds the $7.00 the first acceptance left, so that
      # acceptance cannot be undone over the one that replaced it (R15).
      assert {:error, :stale} =
               Fares.undo(context.scope, first.operation_id, first.inverse)

      assert stored(context).expected_amount == Decimal.new("8.00")

      assert {:ok, _undone} =
               Fares.undo(context.scope, second.operation_id, second.inverse)

      assert stored(context).expected_amount == Decimal.new("7.00")
    end
  end

  describe "deleting a journey" do
    test "removes the row and undo puts it back whole", context do
      assert {:ok, saved} = Fares.save_journey(context.scope, toledo_to_corvallis())
      id = saved.journey.id

      assert {:ok, deleted} = Fares.delete_journey(context.scope, id)
      assert stored(context) == nil

      assert [entry] = entries(context, deleted.operation_id)
      assert entry.action == "deleted"
      assert entry.changed_fields["summary"] == "Deleted \"Toledo to Corvallis\""

      assert entry.changed_fields["before"] == [
               %{
                 "fare_saved_journeys_id" => id,
                 "name" => "Toledo to Corvallis",
                 "expected_amount" => "6.00"
               }
             ]

      assert entry.changed_fields["after"] == []

      assert {:ok, undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      assert undone.operation_id == deleted.operation_id
      restored = stored(context)
      assert restored.id == id
      assert restored.expected_amount == Decimal.new("6.00")
      assert [%{"route_id" => "4"}, %{"route_id" => "10"}] = restored.legs
    end

    test "undoing a save deletes the row again", context do
      assert {:ok, saved} = Fares.save_journey(context.scope, toledo_to_corvallis())

      assert {:ok, undone} =
               Fares.undo(context.scope, saved.operation_id, saved.inverse)

      assert undone.operation_id == saved.operation_id
      assert stored(context) == nil
    end
  end

  describe "a journey of another version" do
    setup context do
      organization = context.organization
      version = gtfs_version_fixture(organization.id, %{name: "Second North Coast"})
      import!(organization, version, "north_coast_v2")

      scope = scope(organization, version, context.actor)
      {:ok, plan} = Conversion.preview(organization.id, version.id)
      {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])
      {:ok, _difference} = Transfers.save(scope, "N_LOCAL", "N_INTERCITY", @difference, nil)

      context
      |> Map.put(:other, %{
        organization: organization,
        version: version,
        scope: scope
      })
    end

    test "is not found by the first version's scope, and stays stored", context do
      entries_before = entry_count(context)

      assert {:ok, saved} = Fares.save_journey(context.other.scope, toledo_to_corvallis())
      id = saved.journey.id

      assert {:error, :not_found} =
               Fares.accept_journey_price(context.scope, id, Decimal.new("7.00"))

      assert {:error, :not_found} = Fares.delete_journey(context.scope, id)

      # The refusal wrote nothing: the journey is still the other version's row,
      # still holding the total that version priced.
      assert stored(context.other).id == id
      assert stored(context.other).expected_amount == Decimal.new("6.00")
      assert entry_count(context) == entries_before
    end
  end

  # Toledo City Hall to Corvallis Transit Center: the sample's Local-then-Intercity
  # change on a Monday, 07:40 boarding and a 10:20 arrival.
  defp toledo_to_corvallis do
    %{
      name: "Toledo to Corvallis",
      rider_category_id: "adult",
      fare_media_id: "cash",
      service_date: @monday,
      legs: [
        %{
          route_id: "4",
          from_stop_id: "TOLEDO",
          to_stop_id: "NTC",
          departs: 7 * 3600 + 40 * 60,
          arrives: 8 * 3600 + 55 * 60
        },
        %{
          route_id: "10",
          from_stop_id: "NTC",
          to_stop_id: "CORVALLIS",
          departs: 8 * 3600 + 20 * 60,
          arrives: 10 * 3600 + 20 * 60
        }
      ]
    }
  end

  # A route the version holds no fare for, so a journey holding this ride has no
  # total to store.
  defp unpriced_ride do
    %{
      route_id: "no-such-route",
      from_stop_id: "TOLEDO",
      to_stop_id: "NTC",
      departs: 7 * 3600 + 40 * 60,
      arrives: 8 * 3600 + 55 * 60
    }
  end

  defp scope(organization, version, actor) do
    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp stored(context) do
    FareSavedJourney
    |> where(
      [row],
      row.organization_id == ^context.organization.id and
        row.gtfs_version_id == ^context.version.id
    )
    |> Repo.one()
  end

  defp entries(context, operation_id) do
    context
    |> fare_entries()
    |> where([entry], fragment("?->>?", entry.changed_fields, "operation_id") == ^operation_id)
    |> Repo.all()
  end

  defp entry_count(context) do
    context
    |> fare_entries()
    |> Repo.aggregate(:count)
  end

  # The version's own `fare_version` entries, which every change-log read here is
  # a subset of.
  defp fare_entries(context) do
    ChangeLog
    |> where(
      [entry],
      entry.organization_id == ^context.organization.id and
        entry.gtfs_version_id == ^context.version.id and entry.entity_type == "fare_version"
    )
  end
end
