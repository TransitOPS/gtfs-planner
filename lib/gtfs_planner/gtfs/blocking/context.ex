defmodule GtfsPlanner.Gtfs.Blocking.Context do
  @moduledoc """
  The planning inputs of one GTFS version, gathered once and handed to the pure
  planning modules.

  Every field is a planning input rather than a derived result: settings, the
  garages and vehicle types they name, per-route operating settings, per-service
  block attributes, entered driving times, marked relief points, a fleet summary
  and per-trip distances. Movements, checks, relief windows and the plan are
  derived from this struct; they are never stored in it and never re-read from
  the database by the modules that consume it.

  The struct itself makes no repository, clock, file or network call. The private
  builder that fills it from a version's reads lives in `GtfsPlanner.Gtfs.Blocking`
  so that `Blocking`, `Blocking.Queries` and `Operations` keep every database
  call. `planning?/0` is `false` only for the layover-only context
  (`layover_only/1`), which reproduces spec 05's behaviour exactly.

  Created by step 4 with the fields and defaults of the Key contracts so the pure
  `Blocking.DeadheadTimes` has a context to read. Step 7 adds the builder,
  `layover_only/1` and `digest/1`; step 8 adds `resolve_block/3`.
  """

  @type ref :: {:stop, String.t()} | {:garage, Ecto.UUID.t()}

  @type garage :: %{
          id: Ecto.UUID.t(),
          garage_id: String.t(),
          name: String.t(),
          lat: float(),
          lon: float()
        }

  @type vehicle_type :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          max_out_minutes: pos_integer() | nil
        }

  @type attribute :: %{garage_id: Ecto.UUID.t() | nil, vehicle_type_id: Ecto.UUID.t() | nil}

  @type fleet_bucket :: %{
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil,
          count: pos_integer()
        }

  @type t :: %__MODULE__{
          min_layover_minutes: 0..120,
          max_block_minutes: non_neg_integer() | nil,
          pull_out_buffer_minutes: non_neg_integer(),
          interlining: :any | :same_stop | :none,
          default_garage_id: Ecto.UUID.t() | nil,
          deadhead_speed_kmh: non_neg_integer(),
          deadhead_circuity: float(),
          max_piece_minutes: non_neg_integer() | nil,
          garages: %{Ecto.UUID.t() => garage()},
          vehicle_types: %{Ecto.UUID.t() => vehicle_type()},
          route_settings: %{
            String.t() => %{
              optional(:garage_id) => Ecto.UUID.t(),
              optional(:required_vehicle_type_id) => Ecto.UUID.t()
            }
          },
          attributes: %{{String.t(), String.t()} => attribute()},
          entered_minutes: %{{ref(), ref()} => non_neg_integer()},
          relief_stop_ids: MapSet.t(String.t()),
          fleet: [fleet_bucket()],
          trip_km: %{Ecto.UUID.t() => {float(), :shape | :path}},
          planning?: boolean()
        }

  @enforce_keys [:min_layover_minutes]
  defstruct min_layover_minutes: 5,
            max_block_minutes: nil,
            pull_out_buffer_minutes: 0,
            interlining: :any,
            default_garage_id: nil,
            deadhead_speed_kmh: 30,
            deadhead_circuity: 1.3,
            max_piece_minutes: nil,
            garages: %{},
            vehicle_types: %{},
            route_settings: %{},
            attributes: %{},
            entered_minutes: %{},
            relief_stop_ids: MapSet.new(),
            fleet: [],
            trip_km: %{},
            planning?: true
end
