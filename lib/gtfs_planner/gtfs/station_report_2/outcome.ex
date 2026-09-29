defmodule GtfsPlanner.Gtfs.StationReport2.Outcome do
  @moduledoc """
  The station report's outcome: its issue items and their status counts.

  The report header and the station board both summarize a report by counting
  items with `status == :fail`, and the header also shows the pass, warn and
  info totals. Keeping the item composition and the tally here means the board
  cannot disagree with the report it links to.
  """

  alias GtfsPlanner.Gtfs.{Pathway, Stop}

  alias GtfsPlanner.Gtfs.StationReport2.{DataQuality, Gps, NamingConventions}

  @type item :: %{required(:status) => :pass | :warn | :fail | :info, optional(atom()) => term()}

  @type counts :: %{
          passed: non_neg_integer(),
          warnings: non_neg_integer(),
          failed: non_neg_integer(),
          info: non_neg_integer()
        }

  @doc """
  Builds the report's issue items: data quality, GPS, then naming conventions.
  """
  @spec report_items(%{station: Stop.t(), child_stops: [Stop.t()], pathways: [Pathway.t()]}) ::
          [item()]
  def report_items(snapshot) do
    DataQuality.build(snapshot) ++ Gps.build(snapshot) ++ NamingConventions.build(snapshot)
  end

  @doc """
  Counts items by status.
  """
  @spec counts([item()]) :: counts()
  def counts(items) do
    frequencies = Enum.frequencies_by(items, & &1.status)

    %{
      passed: Map.get(frequencies, :pass, 0),
      warnings: Map.get(frequencies, :warn, 0),
      failed: Map.get(frequencies, :fail, 0),
      info: Map.get(frequencies, :info, 0)
    }
  end
end
