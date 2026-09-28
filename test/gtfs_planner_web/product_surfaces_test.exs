defmodule GtfsPlannerWeb.ProductSurfacesTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlannerWeb.ProductSurfaces

  describe "visible?/2 for a Pathways organization" do
    test "hides exactly the ten user-listed surfaces" do
      org = %Organization{product: :pathways}

      refute ProductSurfaces.visible?(org, :operations)
      refute ProductSurfaces.visible?(org, :flex)
      refute ProductSurfaces.visible?(org, :feed_details)
      refute ProductSurfaces.visible?(org, :agencies)
      refute ProductSurfaces.visible?(org, :fares)
      refute ProductSurfaces.visible?(org, :export_defaults)
      refute ProductSurfaces.visible?(org, :feed_url)
      refute ProductSurfaces.visible?(org, :garages)
      refute ProductSurfaces.visible?(org, :fleet)
      refute ProductSurfaces.visible?(org, :operations_export)
    end

    test "keeps every Pathways surface visible" do
      org = %Organization{product: :pathways}

      assert ProductSurfaces.visible?(org, :routes)
      assert ProductSurfaces.visible?(org, :calendars)
      assert ProductSurfaces.visible?(org, :stops)
      assert ProductSurfaces.visible?(org, :gtfs)
    end
  end

  describe "visible?/2 for Planner and nil organizations" do
    test "a Planner organization shows all fourteen surfaces" do
      org = %Organization{product: :planner}

      assert ProductSurfaces.visible?(org, :operations)
      assert ProductSurfaces.visible?(org, :flex)
      assert ProductSurfaces.visible?(org, :feed_details)
      assert ProductSurfaces.visible?(org, :agencies)
      assert ProductSurfaces.visible?(org, :fares)
      assert ProductSurfaces.visible?(org, :export_defaults)
      assert ProductSurfaces.visible?(org, :feed_url)
      assert ProductSurfaces.visible?(org, :garages)
      assert ProductSurfaces.visible?(org, :fleet)
      assert ProductSurfaces.visible?(org, :operations_export)
      assert ProductSurfaces.visible?(org, :routes)
      assert ProductSurfaces.visible?(org, :calendars)
      assert ProductSurfaces.visible?(org, :stops)
      assert ProductSurfaces.visible?(org, :gtfs)
    end

    test "a nil organization shows all fourteen surfaces" do
      assert ProductSurfaces.visible?(nil, :operations)
      assert ProductSurfaces.visible?(nil, :flex)
      assert ProductSurfaces.visible?(nil, :feed_details)
      assert ProductSurfaces.visible?(nil, :agencies)
      assert ProductSurfaces.visible?(nil, :fares)
      assert ProductSurfaces.visible?(nil, :export_defaults)
      assert ProductSurfaces.visible?(nil, :feed_url)
      assert ProductSurfaces.visible?(nil, :garages)
      assert ProductSurfaces.visible?(nil, :fleet)
      assert ProductSurfaces.visible?(nil, :operations_export)
      assert ProductSurfaces.visible?(nil, :routes)
      assert ProductSurfaces.visible?(nil, :calendars)
      assert ProductSurfaces.visible?(nil, :stops)
      assert ProductSurfaces.visible?(nil, :gtfs)
    end
  end

  describe "brand/1, name/1 and logo_path/1" do
    test "nil brands as Planner; names and logo paths match the spec literals" do
      assert ProductSurfaces.brand(nil) == :planner

      assert ProductSurfaces.brand(%Organization{product: :planner}) == :planner
      assert ProductSurfaces.brand(%Organization{product: :pathways}) == :pathways

      assert ProductSurfaces.name(:planner) == "GTFS Planner"
      assert ProductSurfaces.name(:pathways) == "Pathways Studio"

      assert ProductSurfaces.logo_path(:planner) == "/images/gtfs-planner-logo.svg"
      assert ProductSurfaces.logo_path(:pathways) == "/images/pathways-studio-logo.svg"
    end
  end
end
