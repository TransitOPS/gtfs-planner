defmodule GtfsPlanner.Gtfs.StationReport2.PathwayFieldCompleteness do
  @moduledoc """
  Pure builder: snapshot pathways -> ordered mode groups with field stats.
  """

  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.StationReport2.Helpers

  @type status :: :pass | :warn | :fail

  @type field_stat :: %{
          field: atom(),
          label: String.t(),
          present: non_neg_integer(),
          total: non_neg_integer(),
          percent: non_neg_integer(),
          status: status()
        }

  @type mode_group :: %{
          mode: 1..7,
          mode_label: String.t(),
          fields: [field_stat()]
        }

  @mode_fields %{
    1 => [:length],
    2 => [:stair_count],
    3 => [:traversal_time, :length, :min_width],
    4 => [:traversal_time],
    5 => [:min_width, :traversal_time],
    6 => [:min_width],
    7 => [:min_width]
  }

  @mode_order [1, 2, 4, 5, 6, 7, 3]

  @spec build(%{pathways: [map()]}) :: [mode_group()]
  def build(%{pathways: pathways}) do
    grouped =
      pathways
      |> Enum.group_by(&normalize_pathway_mode/1)
      |> Map.drop([nil])

    @mode_order
    |> Enum.filter(&Map.has_key?(grouped, &1))
    |> Enum.map(fn mode ->
      mode_pathways = Map.fetch!(grouped, mode)
      fields = Map.fetch!(@mode_fields, mode)

      %{
        mode: mode,
        mode_label: Pathway.mode_label(mode),
        fields: Enum.map(fields, &field_stat(&1, mode_pathways))
      }
    end)
  end

  defp field_stat(field, pathways) do
    total = length(pathways)
    present = Enum.count(pathways, &Helpers.present?(Map.get(&1, field)))

    %{
      field: field,
      label: field_label(field),
      present: present,
      total: total,
      percent: percent(present, total),
      status: derive_status(present, total)
    }
  end

  defp derive_status(_present, 0), do: :fail
  defp derive_status(total, total), do: :pass
  defp derive_status(0, _total), do: :fail
  defp derive_status(_present, _total), do: :warn

  defp percent(_present, 0), do: 0
  defp percent(present, total), do: round(present / total * 100)

  defp normalize_pathway_mode(%{pathway_mode: mode}) when is_integer(mode) and mode in 1..7,
    do: mode

  defp normalize_pathway_mode(_), do: nil

  defp field_label(:length), do: "Length"
  defp field_label(:stair_count), do: "Stair count"
  defp field_label(:traversal_time), do: "Traversal time"
  defp field_label(:min_width), do: "Min width"

  defp field_label(field),
    do: field |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
