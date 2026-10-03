defmodule GtfsPlannerWeb.Gtfs.FareEditorDrawersTest do
  @moduledoc """
  The three drawers the Prices tab owns — the fare, the rider type and the
  payment method — and the delete dialog that settles a fare's rules.

  Every case drives the real page against the real writers, and asserts on the
  elements the drawer is required to carry, so the suite states which control an
  operator uses rather than which words the page happens to read.

  The version enters its rows the way a user's version does, through the
  production importer of `north_coast_v2` and the production conversion that
  manages it. Expected values are literals worked by hand from that feed: "Local
  ride" is $1.50 adult on the cash method and $1.25 in the NCT Ride app, and it
  holds one `fare_products` row per rider type and payment method — eight rows,
  not one — so editing it has to leave eight rows behind.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo

  setup context do
    organization =
      organization_fixture(%{alias: "fare-drawers-#{System.unique_integer([:positive])}"})

    user = user_fixture(%{email: "fare-drawers-#{Ecto.UUID.generate()}@example.com"})
    version = gtfs_version_fixture(organization.id, %{name: "Fare drawers version"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    import!(organization, version, "north_coast_v2")

    scope = scope(organization, version, user)
    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])

    {:ok,
     conn: log_in_user(context.conn, user, organization: organization),
     organization: organization,
     user: user,
     version: version}
  end

  describe "the fare drawer" do
    test "creating a fare adds a row to the table", ctx do
      view = open_prices(ctx)

      assert view |> element("#create-fare") |> render_click()
      assert has_element?(view, "#fare-drawer")
      assert has_element?(view, "#fare-form")

      html =
        view
        |> element("#fare-form")
        |> render_change(%{
          "fare" => %{
            "name" => "Summer beach shuttle",
            "kind" => "single",
            "media_ids" => ["cash"],
            "prices" => %{"adult" => "1.00"}
          }
        })

      assert html =~ "Summer beach shuttle"

      html =
        view
        |> element("#fare-form")
        |> render_submit(%{
          "fare" => %{
            "name" => "Summer beach shuttle",
            "kind" => "single",
            "media_ids" => ["cash"],
            "prices" => %{"adult" => "1.00"}
          }
        })

      assert html =~ "Summer beach shuttle"
      refute has_element?(view, "#fare-drawer")

      products = fare_products(ctx, "Summer beach shuttle")

      assert [%{amount: amount}] = products
      assert Decimal.equal?(amount, Decimal.new("1.00"))
    end

    test "a blank name refuses the save and names the name field", ctx do
      view = open_prices(ctx)

      view |> element("#create-fare") |> render_click()

      html =
        view
        |> element("#fare-form")
        |> render_submit(%{
          "fare" => %{
            "name" => "",
            "kind" => "single",
            "media_ids" => ["cash"],
            "prices" => %{"adult" => "1.00"}
          }
        })

      assert html =~ ~s(id="error-summary")
      assert html =~ ~s(href="#fare-name")
      assert has_element?(view, "#fare-drawer")
      assert fare_products(ctx, "Summer beach shuttle") == []
    end

    test "an unreadable price names the rider type it belongs to", ctx do
      view = open_prices(ctx)

      view |> element("#create-fare") |> render_click()

      html =
        view
        |> element("#fare-form")
        |> render_submit(%{
          "fare" => %{
            "name" => "Summer beach shuttle",
            "kind" => "single",
            "media_ids" => ["cash"],
            "prices" => %{"adult" => "1.50", "reduced" => "one fifty"}
          }
        })

      assert html =~ ~s(id="error-summary")
      assert html =~ ~s(href="#fare-price-reduced")
      assert fare_products(ctx, "Summer beach shuttle") == []
    end

    test "a fare sold no way at all is refused on the payment method field", ctx do
      view = open_prices(ctx)

      view |> element("#create-fare") |> render_click()

      html =
        view
        |> element("#fare-form")
        |> render_submit(%{
          "fare" => %{
            "name" => "Summer beach shuttle",
            "kind" => "single",
            "media_ids" => [],
            "prices" => %{"adult" => "1.00"}
          }
        })

      assert html =~ ~s(href="#fare-media")
      assert fare_products(ctx, "Summer beach shuttle") == []
    end

    test "an intervening price edit refuses the drawer save and keeps its draft", ctx do
      view = open_prices(ctx)
      view |> element("#fare-open-local_ride") |> render_click()

      assert {:ok, _} =
               Fares.save_prices(scope(ctx.organization, ctx.version, ctx.user), [
                 %{
                   fare_product_id: "local_ride_adult_cash",
                   rider_category_id: "adult",
                   fare_media_id: "cash",
                   reviewed: Decimal.new("1.50"),
                   amount: "2.00"
                 }
               ])

      view
      |> element("#fare-form")
      |> render_submit(%{
        "fare" => %{
          "name" => "My unsaved name",
          "kind" => "single",
          "media_ids" => ["cash", "app"],
          "prices" => %{"adult" => "1.60"},
          "reviewed_snapshot" => Fares.reviewed_snapshot(ctx.organization.id, ctx.version.id)
        }
      })

      assert has_element?(view, "#fare-drawer")
      assert has_element?(view, "#fare-name[value='My unsaved name']")
      assert has_element?(view, "#fare-note", "changed since this dialog opened")
      refute fare_products(ctx, "Local ride") == []

      assert fare_product_amount(fare_products(ctx, "Local ride"), "local_ride_adult_cash") ==
               "2.00"

      assert fare_products(ctx, "My unsaved name") == []
    end

    test "editing a fare keeps each price on the row it already wrote", ctx do
      view = open_prices(ctx)

      view |> element("#fare-open-local_ride") |> render_click()

      assert has_element?(view, "#fare-drawer")
      assert has_element?(view, "#fare-delete")
      assert has_element?(view, "#fare-name[value='Local ride']")

      html =
        view
        |> element("#fare-form")
        |> render_submit(%{
          "fare" => %{
            "name" => "Local ride",
            "kind" => "single",
            "media_ids" => ["cash", "app"],
            "differ" => "true",
            "prices" => %{"adult" => "1.60", "reduced" => "0.80", "youth" => "1.00"},
            "media_prices" => %{
              "app" => %{"adult" => "1.30", "reduced" => "0.65", "youth" => "0.80"}
            }
          }
        })

      refute html =~ ~s(id="fare-drawer")

      products = fare_products(ctx, "Local ride")

      # The imported fare holds one row per rider type and payment method, so a
      # save must keep eight rows rather than collapse them onto one.
      assert length(products) == 8
      assert fare_product_amount(products, "local_ride_adult_cash") == "1.60"
      assert fare_product_amount(products, "local_ride_adult_app") == "1.30"
      assert fare_product_amount(products, "local_ride_reduced_cash") == "0.80"
      assert fare_product_amount(products, "local_ride_reduced_app") == "0.65"
      assert fare_product_amount(products, "local_ride_child_cash") == "0.00"
    end
  end

  describe "the fare delete dialog" do
    test "a priced fare will not be deleted without saying what replaces it", ctx do
      view = open_delete_fare(ctx)

      assert has_element?(view, "#fare-delete-dialog")
      assert has_element?(view, "#fare-delete-replacement")
      assert has_element?(view, "#fare-delete-rules")

      view |> element("#fare-delete-dialog-confirm") |> render_click()

      assert has_element?(view, "#fare-delete-dialog")
      assert render(view) =~ "Choose what these rides charge instead."
      assert fare_products(ctx, "Valley ride") != []
    end

    test "choosing a replacement deletes the fare and moves its rules", ctx do
      view = open_delete_fare(ctx)

      view
      |> element("#fare-delete-replacement-form")
      |> render_change(%{"replacement" => "coast_ride_adult_cash"})

      view |> element("#fare-delete-dialog-confirm") |> render_click()

      refute has_element?(view, "#fare-delete-dialog")
      assert fare_products(ctx, "Valley ride") == []

      rules = fare_leg_rules(ctx)

      # Every rule that named a Valley ride row now names the Coast ride row for
      # the same rider type, and the conditions are the ones Valley ride had.
      assert Enum.all?(rules, &(&1.fare_product_id not in ~w(
               valley_ride_adult_cash
               valley_ride_reduced_cash
               valley_ride_youth_cash
               valley_ride_child_cash
             )))

      moved = Enum.filter(rules, &(&1.fare_product_id == "coast_ride_reduced_cash"))

      assert Enum.any?(moved, &(&1.from_area_id == "NPT" and &1.to_area_id == "TOL"))
    end

    test "choosing no fare removes the rules instead of moving them", ctx do
      view = open_delete_fare(ctx)

      view
      |> element("#fare-delete-replacement-form")
      |> render_change(%{"replacement" => "none"})

      view |> element("#fare-delete-dialog-confirm") |> render_click()

      assert fare_products(ctx, "Valley ride") == []

      rules = fare_leg_rules(ctx)

      refute Enum.any?(rules, &String.starts_with?(&1.fare_product_id, "valley_ride_"))
    end
  end

  describe "the rider type drawer" do
    test "the rider type shown first offers no delete action", ctx do
      view = open_prices(ctx)

      view |> element("#rider-edit-adult") |> render_click()

      assert has_element?(view, "#rider-drawer")
      assert has_element?(view, "#rider-name[value='Adult']")
      refute has_element?(view, "#rider-delete")
      assert has_element?(view, "#rider-default[disabled]")
    end

    test "another rider type does offer one", ctx do
      view = open_prices(ctx)

      view |> element("#rider-edit-reduced") |> render_click()

      assert has_element?(view, "#rider-delete")
      assert has_element?(view, "#rider-name[value='Reduced fare']")
    end

    test "a blank name refuses the save and names the name field", ctx do
      view = open_prices(ctx)

      view |> element("#create-rider") |> render_click()

      html =
        view
        |> element("#rider-form")
        |> render_submit(%{"rider" => %{"name" => "", "starting" => "half"}})

      assert html =~ ~s(id="error-summary")
      assert html =~ ~s(href="#rider-name")
    end

    test "creating a rider type adds its prices to every fare", ctx do
      view = open_prices(ctx)

      view |> element("#create-rider") |> render_click()

      assert has_element?(view, "#rider-starting")
      assert has_element?(view, "#rider-starting-preview")

      view
      |> element("#rider-form")
      |> render_submit(%{"rider" => %{"name" => "Senior (65+)", "starting" => "same"}})

      refute has_element?(view, "#rider-drawer")

      products = fare_products(ctx, "Local ride")
      senior = Enum.filter(products, &(&1.rider_category_id == "senior_65"))

      assert senior != []
      assert Decimal.equal?(hd(senior).amount, Decimal.new("1.50"))
    end

    test "deleting a rider type removes its prices", ctx do
      view = open_prices(ctx)

      view |> element("#rider-edit-reduced") |> render_click()
      view |> element("#rider-delete") |> render_click()

      assert has_element?(view, "#rider-delete-dialog")

      view |> element("#rider-delete-dialog-confirm") |> render_click()

      refute has_element?(view, "#rider-delete-dialog")

      products = fare_products(ctx, "Local ride")
      refute Enum.any?(products, &(&1.rider_category_id == "reduced"))
    end
  end

  describe "the payment method drawer" do
    test "creating one offers the five GTFS kinds", ctx do
      view = open_prices(ctx)

      view |> element("#create-media") |> render_click()

      assert has_element?(view, "#media-drawer")

      for value <- ~w(0 1 2 3 4) do
        assert has_element?(view, "#media-kind-#{value}")
      end
    end

    test "a blank name refuses the save and names the name field", ctx do
      view = open_prices(ctx)

      view |> element("#create-media") |> render_click()

      html =
        view
        |> element("#media-form")
        |> render_submit(%{"media" => %{"name" => "", "fare_media_type" => "4"}})

      assert html =~ ~s(id="error-summary")
      assert html =~ ~s(href="#media-name")
    end

    test "a new payment method is accepted for the fares ticked", ctx do
      view = open_prices(ctx)

      view |> element("#create-media") |> render_click()

      view
      |> element("#media-form")
      |> render_submit(%{
        "media" => %{
          "name" => "NCT Ride app",
          "fare_media_type" => "4",
          "accepted_products" => ["local_ride_adult_cash"]
        }
      })

      refute has_element?(view, "#media-drawer")

      products = fare_products(ctx, "Local ride")

      assert Enum.any?(products, &(&1.fare_media_id == "app"))
    end

    test "deleting one removes every price that named it", ctx do
      view = open_prices(ctx)

      view |> element("#media-open-app") |> render_click()
      view |> element("#media-delete") |> render_click()

      assert has_element?(view, "#media-delete-dialog")

      view |> element("#media-delete-dialog-confirm") |> render_click()

      refute has_element?(view, "#media-delete-dialog")

      products = fare_products(ctx, "Local ride")
      refute Enum.any?(products, &(&1.fare_media_id == "app"))
    end
  end

  defp open_prices(ctx) do
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{ctx.version.id}/settings/fares")

    # The shell's connected mount owns the load, so the grid only renders once
    # the workspace has arrived.
    assert render(view) =~ "fare-table"
    view
  end

  defp open_delete_fare(ctx) do
    view = open_prices(ctx)

    view |> element("#fare-open-valley_ride") |> render_click()
    view |> element("#fare-delete") |> render_click()
    view
  end

  defp fare_products(ctx, name) do
    organization_id = ctx.organization.id
    version_id = ctx.version.id

    FareProduct
    |> where(
      [product],
      product.organization_id == ^organization_id and
        product.gtfs_version_id == ^version_id and product.fare_product_name == ^name
    )
    |> order_by([product], asc: product.fare_product_id)
    |> Repo.all()
  end

  defp fare_product_amount(products, product_id) do
    case Enum.find(products, &(&1.fare_product_id == product_id)) do
      nil -> nil
      product -> Decimal.to_string(product.amount, :normal)
    end
  end

  defp fare_leg_rules(ctx) do
    organization_id = ctx.organization.id
    version_id = ctx.version.id

    FareLegRule
    |> where(
      [rule],
      rule.organization_id == ^organization_id and rule.gtfs_version_id == ^version_id
    )
    |> Repo.all()
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
end
