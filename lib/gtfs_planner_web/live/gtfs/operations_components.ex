defmodule GtfsPlannerWeb.Gtfs.OperationsComponents do
  @moduledoc """
  Function components shared by the Garages and Fleet pages.

  Garages, vehicle types and vehicles belong to the organization rather than to a
  GTFS version, so both pages carry the same all-versions scope note next to
  their introduction.
  """

  use GtfsPlannerWeb, :html

  @doc """
  Renders the shared-scope note naming the organization these assets belong to.

  ## Examples

      <.scope_note organization_name={@current_organization.name} class="mt-2" />
  """
  attr :organization_name, :string, required: true
  attr :class, :any, default: nil

  def scope_note(assigns) do
    ~H"""
    <p class={["text-sm text-base-content/70", @class]}>
      <span class="mr-1 text-brand" aria-hidden="true">●</span>Shared across all service versions for {@organization_name}.
    </p>
    """
  end
end
