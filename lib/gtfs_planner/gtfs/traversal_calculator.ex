defmodule GtfsPlanner.Gtfs.TraversalCalculator do
  @moduledoc """
  Estimates traversal burden for a single pathway segment.
  """

  @walk_speed 1.4
  @escalator_speed 0.5
  @elevator_board_slack 12.0
  @elevator_hop_time 8.0
  @stair_step_meters 0.17

  @type result :: %{
          time_seconds: number(),
          distance_meters: number() | nil,
          calculation_method: atom()
        }

  @spec calculate(map(), number() | nil) :: result()
  def calculate(pathway, level_diff) do
    case normalize_mode(pathway.pathway_mode) do
      4 -> escalator_result(pathway)
      5 -> elevator_result(pathway, level_diff)
      _ -> default_result(pathway)
    end
  end

  defp default_result(pathway) do
    traversal_time = normalize_number(pathway.traversal_time)
    length_meters = normalize_number(pathway.length)
    stair_count = normalize_number(pathway.stair_count)

    cond do
      positive?(traversal_time) ->
        %{
          time_seconds: traversal_time,
          distance_meters: positive_or_nil(length_meters),
          calculation_method: :traversal_time
        }

      positive?(length_meters) ->
        %{
          time_seconds: length_meters / @walk_speed,
          distance_meters: length_meters,
          calculation_method: :length_walk_speed
        }

      positive?(stair_count) ->
        distance_meters = stair_count * @stair_step_meters

        %{
          time_seconds: distance_meters / @walk_speed,
          distance_meters: distance_meters,
          calculation_method: :stair_count_estimate
        }

      true ->
        %{time_seconds: 0.0, distance_meters: nil, calculation_method: :default_zero}
    end
  end

  defp escalator_result(pathway) do
    traversal_time = normalize_number(pathway.traversal_time)
    length_meters = normalize_number(pathway.length)

    cond do
      positive?(traversal_time) ->
        %{
          time_seconds: traversal_time,
          distance_meters: positive_or_nil(length_meters),
          calculation_method: :escalator_traversal_time
        }

      positive?(length_meters) ->
        %{
          time_seconds: length_meters / @escalator_speed,
          distance_meters: length_meters,
          calculation_method: :escalator_length_speed
        }

      true ->
        %{time_seconds: 0.0, distance_meters: nil, calculation_method: :escalator_default_zero}
    end
  end

  defp elevator_result(pathway, level_diff) do
    traversal_time = normalize_number(pathway.traversal_time)
    normalized_level_diff = normalize_number(level_diff)

    hop_time =
      cond do
        positive?(traversal_time) -> traversal_time
        positive?(normalized_level_diff) -> normalized_level_diff * @elevator_hop_time
        true -> @elevator_hop_time
      end

    method =
      cond do
        positive?(traversal_time) -> :elevator_traversal_time
        positive?(normalized_level_diff) -> :elevator_level_diff_estimate
        true -> :elevator_single_level_estimate
      end

    %{
      time_seconds: @elevator_board_slack + hop_time,
      distance_meters: nil,
      calculation_method: method
    }
  end

  defp positive?(value) when is_number(value), do: value > 0
  defp positive?(_), do: false

  defp positive_or_nil(value) when is_number(value) and value > 0, do: value
  defp positive_or_nil(_), do: nil

  defp normalize_number(%Decimal{} = value), do: Decimal.to_float(value)
  defp normalize_number(value) when is_integer(value), do: value * 1.0
  defp normalize_number(value) when is_float(value), do: value
  defp normalize_number(_), do: nil

  defp normalize_mode(%Decimal{} = value), do: value |> Decimal.to_float() |> round()
  defp normalize_mode(value) when is_integer(value), do: value
  defp normalize_mode(value) when is_float(value), do: round(value)
  defp normalize_mode(_), do: nil
end
