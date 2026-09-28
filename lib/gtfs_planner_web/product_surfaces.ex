defmodule GtfsPlannerWeb.ProductSurfaces do
  @moduledoc "Which product-specific surfaces an organization shows. Hiding only; never an access check."

  alias GtfsPlanner.Organizations.Organization

  @type surface ::
          :operations
          | :flex
          | :feed_details
          | :agencies
          | :fares
          | :export_defaults
          | :feed_url
          | :garages
          | :fleet
          | :operations_export
          | atom()

  @pathways_hidden ~w(operations flex feed_details agencies fares export_defaults feed_url garages fleet operations_export)a

  @spec visible?(Organization.t() | nil, surface()) :: boolean()
  def visible?(%Organization{product: :pathways}, surface), do: surface not in @pathways_hidden
  def visible?(_org, _surface), do: true

  @spec brand(Organization.t() | nil) :: :planner | :pathways
  def brand(nil), do: :planner
  def brand(%Organization{product: product}), do: product

  @spec name(:planner | :pathways) :: String.t()
  def name(:planner), do: "GTFS Planner"
  def name(:pathways), do: "Pathways Studio"

  @spec logo_path(:planner | :pathways) :: String.t()
  def logo_path(:planner), do: "/images/gtfs-planner-logo.svg"
  def logo_path(:pathways), do: "/images/pathways-studio-logo.svg"
end
