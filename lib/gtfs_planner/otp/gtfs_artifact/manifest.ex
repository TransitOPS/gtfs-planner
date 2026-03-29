defmodule GtfsPlanner.Otp.Manifest do
  @moduledoc """
  OTP GTFS manifest policy for required and optional export specs.

  Required policy:
    * `agency.txt`, `stops.txt`, `routes.txt`, `trips.txt`,
      `stop_times.txt`, `pathways.txt`
    * at least one of `calendar.txt` or `calendar_dates.txt`

  Optional policy:
    * `levels.txt` and `attributions.txt` when present
  """

  alias GtfsPlanner.Gtfs.Export.FileSpec

  @type file_requirement :: %{
          required: [String.t()],
          one_of: [String.t()],
          optional: [String.t()]
        }

  @spec required_base_specs() :: [map()]
  def required_base_specs do
    [
      FileSpec.agency_spec(),
      FileSpec.stops_spec(),
      FileSpec.routes_spec(),
      FileSpec.trips_spec(),
      FileSpec.stop_times_spec(),
      FileSpec.pathways_spec()
    ]
  end

  @spec calendar_alternative_specs() :: [map()]
  def calendar_alternative_specs do
    [
      FileSpec.calendar_spec(),
      FileSpec.calendar_dates_spec()
    ]
  end

  @spec optional_specs() :: [map()]
  def optional_specs do
    [
      FileSpec.levels_spec(),
      FileSpec.attributions_spec()
    ]
  end

  @spec file_requirements() :: file_requirement()
  def file_requirements do
    %{
      required: Enum.map(required_base_specs(), & &1.filename),
      one_of: Enum.map(calendar_alternative_specs(), & &1.filename),
      optional: Enum.map(optional_specs(), & &1.filename)
    }
  end
end
