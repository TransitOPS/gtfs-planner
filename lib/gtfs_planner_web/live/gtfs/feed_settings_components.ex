defmodule GtfsPlannerWeb.Gtfs.FeedSettingsComponents do
  @moduledoc """
  Form controls shared by the Feed details and Agencies settings drawers.

  `language_select/1` renders a language choice as the repository's
  `.input type="select"`. The option groups come from
  `GtfsPlanner.Gtfs.LanguageCodes.options/1`, so the feed language adds `mul`,
  the agency and default languages do not, and a stored code the list omits
  keeps its own "Current value" entry instead of being silently replaced (R12).
  One control means the page and every drawer label a code the same way.

  The component carries no state: the caller supplies the form field, and the
  current value is read from it, so an imported code outside the list stays
  selected when the drawer opens.
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.LanguageCodes

  @doc """
  Renders a language select for `field`.

  Pass `include_mul: true` for the feed language, the only field that accepts
  `mul`. `optional: true` moves the "(optional)" suffix into the visible label,
  which every caller would otherwise spell itself.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :include_mul, :boolean, default: false
  attr :optional, :boolean, default: false
  attr :help, :string, default: nil

  def language_select(assigns) do
    assigns =
      assigns
      |> assign(
        :options,
        LanguageCodes.options(include_mul: assigns.include_mul, current: assigns.field.value)
      )
      |> assign(:label, label_with_optional(assigns.label, assigns.optional))

    ~H"""
    <.input
      field={@field}
      type="select"
      label={@label}
      options={@options}
      prompt="Choose language"
      help={@help}
    />
    """
  end

  defp label_with_optional(label, true), do: "#{label} (optional)"
  defp label_with_optional(label, false), do: label
end
