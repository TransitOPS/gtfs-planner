defmodule GtfsPlannerWeb.Components.TransitPresentation do
  @moduledoc """
  Small GTFS presentation components shared by station-facing interfaces.

  These components translate already-resolved display values only; they do not alter
  stored accessibility values or inherit values across GTFS records.
  """
  use Phoenix.Component

  alias GtfsPlanner.Gtfs.Pathway

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]

  attr :status, :atom, required: true, values: [:accessible, :not_accessible, :unknown]
  attr :class, :any, default: nil

  @doc "Renders the explicit accessibility state for a transit entity."
  def accessibility_status(assigns) do
    {label, tone} = accessibility_copy(assigns.status)
    assigns = assigns |> assign(:label, label) |> assign(:tone, tone)

    ~H"""
    <span
      class={["inline-flex items-center gap-1 text-sm font-medium", @tone, @class]}
      data-accessibility={@status}
    >
      <.icon name="hero-information-circle" class="size-4" />
      {@label}
    </span>
    """
  end

  attr :pathway, :map, required: true
  attr :class, :any, default: nil

  @doc "Renders mode, travel direction, and the metrics applicable to a pathway."
  def pathway_summary(assigns) do
    pathway = assigns.pathway
    mode = Map.get(pathway, :pathway_mode)

    assigns =
      assigns
      |> assign(:mode_label, Pathway.mode_label(mode))
      |> assign(
        :direction,
        if(Map.get(pathway, :is_bidirectional, true), do: "Bidirectional", else: "One way")
      )
      |> assign(:metrics, pathway_metrics(pathway, mode))

    ~H"""
    <span
      class={[
        "inline-flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-base-content/80",
        @class
      ]}
      data-pathway-summary
    >
      <span class="font-medium text-base-content">{@mode_label}</span>
      <span aria-hidden="true">·</span>
      <span>{@direction}</span>
      <span :for={metric <- @metrics} class="inline-flex items-center gap-2">
        <span aria-hidden="true">·</span>
        <span>{metric}</span>
      </span>
    </span>
    """
  end

  defp accessibility_copy(:accessible), do: {"Accessible", "text-success"}
  defp accessibility_copy(:not_accessible), do: {"Not accessible", "text-error"}
  defp accessibility_copy(:unknown), do: {"Accessibility unknown", "text-base-content/70"}

  defp pathway_metrics(pathway, mode) do
    []
    |> maybe_add(
      mode == 2 && present?(Map.get(pathway, :stair_count)),
      "#{Map.get(pathway, :stair_count)} stairs"
    )
    |> maybe_add(
      present?(Map.get(pathway, :length)),
      "#{decimal_string(Map.get(pathway, :length))} m"
    )
    |> maybe_add(
      present?(Map.get(pathway, :traversal_time)),
      "#{Map.get(pathway, :traversal_time)} sec"
    )
  end

  defp maybe_add(metrics, true, metric), do: metrics ++ [metric]
  defp maybe_add(metrics, false, _metric), do: metrics
  defp present?(value) when is_integer(value), do: true
  defp present?(value) when is_float(value), do: true
  defp present?(%Decimal{}), do: true
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(value), do: to_string(value)
end
