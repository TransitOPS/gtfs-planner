defmodule GtfsPlanner.Gtfs.Fares.SetupTest do
  @moduledoc """
  Merge evidence (EV-12) for `Fares.Conversion.setup/2` and `Fares.undo/3`, the
  first-use setup that turns the editor's four answers into a managed fare set
  (AC-10).

  Every expected value is worked by hand from the spec and from the answers the
  test gives, not read back from the code under test: half of $1.50 rounded to
  the nearest nickel is $0.75, a child pays nothing, 90 minutes is 5400 seconds,
  `transfer_count` -1 is every change, and a route structure's second group gets
  no routes because the operator assigns them on the next screen.

  The version enters rows the way a user's version does — through the production
  importer of `test/fixtures/gtfs/fares/no_fare`, which is the sample feed with no
  fare files — and the write itself runs through
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/2`, the same transaction every
  later writer uses.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 1, gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Normalize
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Repo

  # A fare row is scoped by its organization and its version. This is a macro so
  # each schema's query is built with that schema known at compile time, which a
  # function taking the schema as a variable cannot do.
  defmacro scoped!(schema, context) do
    quote do
      organization_id = unquote(context).organization.id
      gtfs_version_id = unquote(context).version.id

      Repo.all(
        from(row in unquote(schema),
          where:
            row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id
        )
      )
    end
  end

  setup do
    organization = organization_fixture(%{alias: "fares-setup-#{unique_alias()}"})
    actor = editor_fixture(organization)
    version = gtfs_version_fixture(organization.id, %{name: "Fare setup version"})
    import!(organization, version, "no_fare")

    %{
      organization: organization,
      version: version,
      scope: %{
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
    }
  end

  test "setup refuses an actor without editor membership before writing fares", context do
    outsider = GtfsPlanner.AccountsFixtures.user_fixture()

    audit = context.scope.audit

    scope = %{
      context.scope
      | audit: %{audit | actor_id: outsider.id, actor_email: outsider.email}
    }

    assert {:error, :forbidden} = Fares.Conversion.setup(scope, flat_answers())

    assert {:error, :forbidden} =
             Fares.Conversion.setup(
               %{context.scope | organization_id: Ecto.UUID.generate()},
               flat_answers()
             )

    refute Fares.managed?(context.organization.id, context.version.id)
    assert [] = scoped!(FareProduct, context)
  end

  describe "a flat structure" do
    test "creates one product sold at the adult price, half and free", context do
      assert {:ok, result} = run_setup(context, flat_answers())
      assert {:ok, _workspace} = Fares.load_workspace(context.organization.id, context.version.id)

      assert Fares.managed?(context.organization.id, context.version.id)

      # A row's order is Postgres's, so the fare is read by rider type id.
      products = scoped!(FareProduct, context) |> Enum.sort_by(& &1.rider_category_id)

      assert Enum.map(products, & &1.rider_category_id) == ["adult", "child", "reduced"]

      # Half of $1.50 rounded to the nearest nickel is $0.75; a child rides free.
      assert amounts_equal?(
               prices(products),
               [Decimal.new("1.50"), Decimal.new("0.00"), Decimal.new("0.75")]
             )

      # Every row of one fare carries its name, so the grid reads them as one.
      assert products |> Enum.map(& &1.fare_product_name) |> Enum.uniq() == ["Local ride"]
      assert products |> Enum.map(& &1.fare_product_id) |> Enum.uniq() == ["local_ride"]
      assert products |> Enum.map(& &1.fare_media_id) |> Enum.uniq() == ["cash"]

      assert default_rider_id(context) == "adult"
      # `riders/1` sorts by rider type id, so "child" precedes "reduced".
      assert Enum.map(riders(context), & &1.rider_category_id) == ["adult", "child", "reduced"]

      assert [detail] = scoped!(FareProductDetail, context)
      assert detail.kind == "single"

      # One rule per product, and Normalize gave it its priority and leg group.
      assert [rule] = scoped!(FareLegRule, context)
      assert rule.fare_product_id == "local_ride"
      assert rule.network_id == nil
      assert rule.leg_group_id == "all_routes"
      assert rule.rule_priority == 0

      assert [transfer] = scoped!(FareTransferRule, context)
      assert transfer.from_leg_group_id == "all_routes"
      assert transfer.to_leg_group_id == "all_routes"
      assert transfer.transfer_count == -1
      assert transfer.duration_limit == 5400
      assert transfer.duration_limit_type == 1
      assert transfer.fare_transfer_type == 0

      # The version is managed, its settings row names the entry this write made.
      settings = Fares.settings(context.organization.id, context.version.id)
      assert %FareVersionSetting{older_format: "derived", managed_at: managed_at} = settings
      assert managed_at
      assert settings.conversion_operation_id == result.operation_id
    end

    test "records one fare_version change-log entry naming the operation", context do
      assert {:ok, result} = run_setup(context, flat_answers())

      assert [entry] = fare_logs(context, "created")
      assert entry.id == result.operation_id
      assert entry.entity_type == "fare_version"
      assert entry.entity_external_id == "fares"
      assert entry.changed_fields["operation_id"] == result.operation_id
      assert entry.changed_fields["before"] == nil
      assert entry.changed_fields["after"]["kind"] == "flat"
      assert entry.changed_fields["after"]["fare_products"] == 3
      assert entry.changed_fields["after"]["fare_transfer_rules"] == 1
      assert entry.actor_email == context.scope.audit.actor_email
    end

    test "leaves every leg rule matching R3 with no implied row of its own", context do
      assert {:ok, _result} = run_setup(context, flat_answers())

      # Normalize ran inside the write, so re-running it changes nothing (INV-1).
      assert Normalize.run!(context.organization.id, context.version.id) == :ok
      assert length(scoped!(FareLegRule, context)) == 1
      assert length(scoped!(FareTransferRule, context)) == 1
    end
  end

  describe "a route structure" do
    test "creates one fare and one network per group, every route in the first", context do
      answers = %{
        kind: :route,
        groups: [{"Local", Decimal.new("1.50")}, {"Intercity", Decimal.new("6.00")}],
        reduced: false,
        youth: false,
        child: false,
        transfer_minutes: nil
      }

      assert {:ok, _result} = run_setup(context, answers)

      networks = scoped!(Network, context) |> Enum.sort_by(& &1.network_id)

      assert Enum.map(networks, &{&1.network_id, &1.network_name}) == [
               {"intercity", "Intercity"},
               {"local", "Local"}
             ]

      # The 14 routes of the sample feed all start in the first group; the second
      # group is empty until the operator assigns routes to it.
      route_networks = scoped!(RouteNetwork, context)
      assert length(route_networks) == 14
      assert route_networks |> Enum.map(& &1.network_id) |> Enum.uniq() == ["local"]

      products = scoped!(FareProduct, context) |> Enum.sort_by(& &1.fare_product_id)

      assert Enum.map(products, & &1.fare_product_id) == ["intercity_ride", "local_ride"]

      assert amounts_equal?(
               Enum.map(products, &price/1),
               [Decimal.new("6.00"), Decimal.new("1.50")]
             )

      rules = scoped!(FareLegRule, context) |> Enum.sort_by(& &1.fare_product_id)

      assert Enum.map(rules, &{&1.fare_product_id, &1.network_id, &1.leg_group_id}) ==
               [{"intercity_ride", "intercity", "intercity"}, {"local_ride", "local", "local"}]

      assert scoped!(FareTransferRule, context) == []
    end

    test "prices reduced, youth and child off each group's own adult price", context do
      answers = %{
        kind: :route,
        groups: [{"Local", "1.50"}, {"Valley", "2.50"}],
        reduced: true,
        youth: true,
        child: true,
        transfer_minutes: nil
      }

      assert {:ok, _result} = run_setup(context, answers)

      # Half of $1.50 and of $2.50 are both exact, so neither rounds.
      amounts =
        FareProduct
        |> where([p], p.fare_product_id == "local_ride")
        |> Repo.all()
        |> Map.new(&{&1.rider_category_id, &1.amount})

      assert Enum.sort(amounts) ==
               [
                 {"adult", Decimal.new("1.50")},
                 {"child", Decimal.new(0)},
                 {"reduced", Decimal.new("0.75")},
                 {"youth", Decimal.new("0.75")}
               ]

      assert amounts_equal?(Map.values(amounts), [
               Decimal.new("1.50"),
               Decimal.new(0),
               Decimal.new("0.75"),
               Decimal.new("0.75")
             ])
    end

    test "rounds a half price to the nearest nickel", context do
      # Half of $2.53 is $1.265, which no fare machine takes; $1.25 and $1.30 are
      # the two nickels around it and $1.25 is nearer.
      answers = %{kind: :flat, adult: "2.53", reduced: true, transfer_minutes: nil}

      assert {:ok, _result} = run_setup(context, answers)

      assert reduced_amount(context) == Decimal.new("1.25")
    end

    test "refuses a repeated group name, a blank one and no group at all", context do
      assert {:error, :duplicate_group} =
               run_setup(context, route_answers([{"Local", "1.50"}, {"Local", "2.00"}]))

      assert {:error, :invalid_group} = run_setup(context, route_answers([{"  ", "1.50"}]))
      assert {:error, :no_groups} = run_setup(context, route_answers([]))
      assert {:error, :invalid_price} = run_setup(context, route_answers([{"Local", "$"}]))

      # Two slugs that differ only in punctuation are the same network id.
      assert {:error, :duplicate_group} =
               run_setup(context, route_answers([{"Local", "1.50"}, {"local!", "2.00"}]))

      assert no_fare_rows?(context)
      refute Fares.managed?(context.organization.id, context.version.id)
    end
  end

  describe "a free structure" do
    test "creates one free product for the Adult rider type and no transfer", context do
      answers = %{
        kind: :free,
        adult: Decimal.new("1.50"),
        reduced: true,
        youth: true,
        child: true,
        transfer_minutes: 90
      }

      assert {:ok, _result} = run_setup(context, answers)
      assert Fares.managed?(context.organization.id, context.version.id)

      assert [product] = scoped!(FareProduct, context)
      assert product.fare_product_id == "free_ride"
      assert product.fare_product_name == "Free ride"
      assert product.rider_category_id == "adult"
      assert Decimal.equal?(product.amount, Decimal.new(0))

      # A free system is asked no rider question, so it sells to the Adult rider
      # type alone even when the form carried the other answers.
      assert Enum.map(riders(context), & &1.rider_category_id) == ["adult"]
      assert default_rider_id(context) == "adult"

      assert [rule] = scoped!(FareLegRule, context)
      assert rule.network_id == nil
      assert rule.leg_group_id == "all_routes"

      assert scoped!(FareTransferRule, context) == []
      assert Fares.managed?(context.organization.id, context.version.id)
    end
  end

  describe "a zone structure" do
    test "creates the Local ride fare with no zone rule yet", context do
      answers = %{
        kind: :zone,
        adult: Decimal.new("1.50"),
        reduced: true,
        child: true,
        transfer_minutes: 45
      }

      assert {:ok, _result} = run_setup(context, answers)

      assert [rule] = scoped!(FareLegRule, context)
      assert rule.fare_product_id == "local_ride"
      assert rule.network_id == nil
      assert rule.from_area_id == nil
      assert rule.to_area_id == nil

      assert scoped!(Network, context) == []
      assert scoped!(RouteNetwork, context) == []
      assert [transfer] = scoped!(FareTransferRule, context)
      assert transfer.duration_limit == 2700
    end
  end

  describe "a version that already holds fares" do
    test "answers {:error, :has_fares} and writes nothing", context do
      other = gtfs_version_fixture(context.organization.id, %{name: "Imported fares"})
      import!(context.organization, other, "north_coast_v2")

      scope = scope_for(context, other.id)
      organization_id = context.organization.id

      assert {:error, :has_fares} = Fares.Conversion.setup(scope, flat_answers())

      # Nothing of the imported version was touched, and the version that already
      # holds fares is unchanged.
      assert length(version_route_ids(other.id)) == 14

      assert Repo.aggregate(
               from(s in FareVersionSetting, where: s.organization_id == ^organization_id),
               :count
             ) == 0

      assert fare_logs(context, "created") == []
      refute Fares.managed?(context.organization.id, other.id)
      assert Fares.settings(context.organization.id, other.id) == nil
    end

    test "refuses once this setup's own rows exist", context do
      assert {:ok, _result} = run_setup(context, flat_answers())

      assert {:error, :has_fares} = run_setup(context, flat_answers())
    end
  end

  describe "the version lock" do
    test "a version that is not published is refused with nothing written", context do
      {:ok, staging} =
        GtfsPlanner.Versions.create_staging_gtfs_version(context.organization.id, %{
          name: "Staging fares"
        })

      scope = scope_for(context, staging.id)

      assert {:error, :not_found} = Fares.Conversion.setup(scope, flat_answers())
      assert no_fare_rows?(context)
    end

    test "another organization's version is refused with nothing written", context do
      other = organization_fixture(%{alias: "fares-setup-other-#{unique_alias()}"})
      version = gtfs_version_fixture(other.id)
      import!(other, version, "no_fare")

      scope = scope_for(context, version.id)

      assert {:error, :not_found} = Fares.Conversion.setup(scope, flat_answers())

      organization_id = context.organization.id

      assert Repo.aggregate(
               from(p in FareProduct, where: p.organization_id == ^organization_id),
               :count
             ) == 0

      assert Fares.settings(other.id, version.id) == nil
    end
  end

  describe "undo" do
    test "removes every row the setup created and leaves the version unmanaged", context do
      assert {:ok, result} = run_setup(context, flat_answers())
      assert Fares.managed?(context.organization.id, context.version.id)

      assert {:ok, _undone} = Fares.undo(context.scope, result.operation_id, result.inverse)

      assert no_fare_rows?(context)
      refute Fares.managed?(context.organization.id, context.version.id)
      assert Fares.settings(context.organization.id, context.version.id) == nil

      # The settings row is gone, so a second undo of the same operation is stale.
      assert {:error, :stale} =
               Fares.undo(context.scope, result.operation_id, result.inverse)
    end

    test "records a rolled_back entry pointing at the setup's entry", context do
      assert {:ok, result} = run_setup(context, flat_answers())
      assert {:ok, _undone} = Fares.undo(context.scope, result.operation_id, result.inverse)

      assert [rolled_back] = fare_logs(context, "rolled_back")
      assert rolled_back.rolled_back_to_log_id == result.operation_id
      assert rolled_back.changed_fields["operation_id"] == result.operation_id
    end

    test "removes a route structure's networks and route groups too", context do
      assert {:ok, result} =
               run_setup(context, route_answers([{"Local", "1.50"}, {"Intercity", "6.00"}]))

      assert {:ok, _undone} = Fares.undo(context.scope, result.operation_id, result.inverse)

      assert no_fare_rows?(context)
    end

    test "refuses an inverse no writer of this package produced", context do
      assert {:error, :unknown_inverse} =
               Fares.undo(context.scope, Ecto.UUID.generate(), :whatever)
    end
  end

  describe "the editor's read side" do
    test "reads the setup's version as a managed workspace with one fare", context do
      assert {:ok, _result} = run_setup(context, flat_answers())

      {:ok, workspace} =
        Fares.load_workspace(context.organization.id, context.version.id)

      assert workspace.managed?
      assert workspace.unmanaged == nil
      assert workspace.older_format == "derived"

      # The workspace lists rider types by id, so the grid's columns read in that
      # order rather than in the order they were created.
      assert Enum.map(workspace.riders, & &1.rider_category_id) == ["adult", "child", "reduced"]

      assert [fare] = workspace.fares
      assert fare.name == "Local ride"
      assert fare.kind == "single"

      # Half of $1.50 is $0.75 and a child rides free (AC-10).
      assert fare.prices |> Map.keys() |> Enum.sort() == ["adult", "child", "reduced"]

      assert amounts_equal?(Enum.sort(Map.values(fare.prices)), [
               Decimal.new("0"),
               Decimal.new("0.75"),
               Decimal.new("1.50")
             ])

      assert Enum.map(workspace.media, & &1.fare_media_id) == ["cash"]
      assert workspace.transfers != []
    end
  end

  # -- helpers ------------------------------------------------------------------

  # A per-run alias suffix, so this file's organizations never collide with rows
  # another run left on the shared test partition.
  defp unique_alias do
    "s29-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp run_setup(context, answers), do: Fares.Conversion.setup(context.scope, answers)

  # The setup's own scope for another version of the same organization, so a
  # refusal can be asked of that version.
  defp scope_for(context, gtfs_version_id) do
    %{
      context.scope
      | gtfs_version_id: gtfs_version_id,
        audit: %{context.scope.audit | gtfs_version_id: gtfs_version_id}
    }
  end

  defp flat_answers do
    %{
      kind: :flat,
      adult: Decimal.new("1.50"),
      reduced: true,
      youth: false,
      child: true,
      transfer_minutes: 90
    }
  end

  defp route_answers(groups) do
    %{
      kind: :route,
      groups: groups,
      reduced: false,
      youth: false,
      child: false,
      transfer_minutes: nil
    }
  end

  # `numeric` columns keep no scale, so a stored zero reads back as `0` and not
  # as `0.00`. `Decimal.equal?/2` compares the amount a test cares about rather
  # than the scale Postgres happened to store it with.
  defp amounts_equal?(amounts, expected) do
    Enum.zip(amounts, expected)
    |> Enum.all?(fn {amount, want} -> Decimal.equal?(amount, want) end)
  end

  defp price(row), do: row.amount

  defp prices(rows), do: Enum.map(rows, &price/1)

  defp riders(context) do
    organization_id = context.organization.id
    gtfs_version_id = context.version.id

    RiderCategory
    |> where(
      [r],
      r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
    |> Enum.sort_by(& &1.rider_category_id)
  end

  defp default_rider_id(context) do
    case riders(context) |> Enum.filter(&(&1.is_default_fare_category == 1)) do
      [%RiderCategory{rider_category_id: id}] -> id
    end
  end

  defp reduced_amount(context) do
    organization_id = context.organization.id
    gtfs_version_id = context.version.id

    FareProduct
    |> where(
      [p],
      p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id and
        p.rider_category_id == "reduced"
    )
    |> Repo.one()
    |> Map.fetch!(:amount)
  end

  defp fare_logs(context, action) do
    organization_id = context.organization.id
    gtfs_version_id = context.version.id

    ChangeLog
    |> where(
      [log],
      log.organization_id == ^organization_id and log.gtfs_version_id == ^gtfs_version_id and
        log.entity_type == "fare_version" and log.action == ^action
    )
    |> Repo.all()
  end

  defp version_route_ids(gtfs_version_id) do
    Repo.all(
      from(r in Route,
        where: r.gtfs_version_id == ^gtfs_version_id,
        select: r.route_id
      )
    )
  end

  # No fare row of this organization at all, in any table setup or an import of a
  # fare file writes.
  defp no_fare_rows?(context) do
    organization_id = context.organization.id

    Enum.all?(
      [
        FareProduct,
        FareLegRule,
        FareTransferRule,
        RiderCategory,
        FareMedia,
        FareVersionSetting,
        Network
      ],
      fn schema ->
        Repo.aggregate(
          from(row in schema, where: row.organization_id == ^organization_id),
          :count
        ) == 0
      end
    )
  end
end
