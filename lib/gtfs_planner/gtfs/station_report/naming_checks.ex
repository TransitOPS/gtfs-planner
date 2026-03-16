defmodule GtfsPlanner.Gtfs.StationReport.NamingChecks do
  @moduledoc """
  Naming convention checks for station report.

  Validates title case, jargon usage, and stop_id prefix conventions
  for generic nodes and boarding areas.
  """

  alias GtfsPlanner.Gtfs.StationReport.Helpers

  @jargon_keywords ~w[paid unpaid fareline fare_line mezzanine_paid mezzanine_unpaid]

  @doc """
  Returns naming convention validation items for a station and its child stops.
  """
  @spec validate(map(), [map()]) :: [map()]
  def validate(station, child_stops) do
    all_stops = [station | child_stops]

    [
      title_case_check(all_stops),
      jargon_check(all_stops),
      node_prefix_check(child_stops),
      boarding_prefix_check(child_stops)
    ]
  end

  defp title_case_check(stops) do
    flagged =
      stops
      |> Enum.filter(&Helpers.present?(&1.stop_name))
      |> Enum.map(fn stop ->
        expected = Helpers.title_case(stop.stop_name)
        {stop.stop_id, stop.stop_name, expected}
      end)
      |> Enum.filter(fn {_id, actual, expected} -> actual != expected end)
      |> Enum.map(fn {id, _actual, expected} ->
        %{id: id, reason: "expected \"#{expected}\""}
      end)

    Helpers.item(
      "naming_title_case",
      "Stop names use title case",
      if(flagged == [], do: :pass, else: :warn),
      :convention,
      length(flagged),
      flagged
    )
  end

  defp jargon_check(stops) do
    flagged =
      stops
      |> Enum.filter(&Helpers.present?(&1.stop_name))
      |> Enum.map(fn stop ->
        lowered = String.downcase(stop.stop_name)

        matches =
          @jargon_keywords
          |> Enum.filter(&String.contains?(lowered, &1))

        {stop.stop_id, matches}
      end)
      |> Enum.filter(fn {_id, matches} -> matches != [] end)
      |> Enum.map(fn {id, matches} ->
        %{id: id, reason: "contains: #{Enum.join(matches, ", ")}"}
      end)

    Helpers.item(
      "naming_jargon",
      "Stop names avoid internal jargon",
      if(flagged == [], do: :pass, else: :warn),
      :convention,
      length(flagged),
      flagged
    )
  end

  defp node_prefix_check(child_stops) do
    flagged =
      child_stops
      |> Enum.filter(&(&1.location_type == 3))
      |> Enum.reject(&String.starts_with?(&1.stop_id, "node_"))
      |> Enum.map(& &1.stop_id)

    Helpers.item(
      "naming_node_prefix",
      "Generic nodes use node_ prefix",
      if(flagged == [], do: :pass, else: :warn),
      :convention,
      length(flagged),
      flagged
    )
  end

  defp boarding_prefix_check(child_stops) do
    flagged =
      child_stops
      |> Enum.filter(&(&1.location_type == 4))
      |> Enum.reject(&String.starts_with?(&1.stop_id, "boarding_"))
      |> Enum.map(& &1.stop_id)

    Helpers.item(
      "naming_boarding_prefix",
      "Boarding areas use boarding_ prefix",
      if(flagged == [], do: :pass, else: :warn),
      :convention,
      length(flagged),
      flagged
    )
  end
end
