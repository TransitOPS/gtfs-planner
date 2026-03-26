defmodule GtfsPlannerWeb.Gtfs.StationReport2Components do
  @moduledoc """
  Function components for the station report 2 dashboard.
  Each section is an independent placeholder awaiting implementation.
  """
  use Phoenix.Component

  attr :report, :map, default: nil

  def station_inventory_section(assigns) do
    ~H"""
    <section id="report2-station-inventory">
      <h2 class="text-lg font-semibold">Station Inventory</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :report, :map, default: nil

  def data_quality_section(assigns) do
    ~H"""
    <section id="report2-data-quality">
      <h2 class="text-lg font-semibold">Data Quality</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :report, :map, default: nil

  def gps_checks_section(assigns) do
    ~H"""
    <section id="report2-gps-checks">
      <h2 class="text-lg font-semibold">GPS Checks</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :report, :map, default: nil

  def naming_conventions_section(assigns) do
    ~H"""
    <section id="report2-naming-conventions">
      <h2 class="text-lg font-semibold">Naming Conventions</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :report, :map, default: nil

  def reachability_connectivity_section(assigns) do
    ~H"""
    <section id="report2-reachability-connectivity">
      <h2 class="text-lg font-semibold">Reachability & Connectivity</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :report, :map, default: nil

  def pathway_field_completeness_section(assigns) do
    ~H"""
    <section id="report2-pathway-field-completeness">
      <h2 class="text-lg font-semibold">Pathway Field Completeness</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end

  attr :report, :map, default: nil

  def accessibility_section(assigns) do
    ~H"""
    <section id="report2-accessibility">
      <h2 class="text-lg font-semibold">Accessibility</h2>
      <p class="text-base-content/60">Not yet implemented.</p>
    </section>
    """
  end
end
