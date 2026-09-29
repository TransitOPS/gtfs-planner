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
  call. The `planning?` field is `false` only for the layover-only context
  (`layover_only/1`), which reproduces spec 05's behaviour exactly.

  `digest/1` fingerprints every field of a context into one lowercase SHA-256
  string, so a review can name the inputs it read and a later write can prove
  they have not changed under it (INV-7, R12). The digest deliberately covers the
  whole context rather than the inputs one plan happened to read: an over-stale
  preview costs a regeneration, while a fingerprint that missed a changed input
  would apply a plan nobody reviewed.

  `layover_only/1` builds the one context that is not a planning context. It
  carries the minimum layover and nothing else, and `planning?` is `false` so a
  consumer can tell the difference between "the version has no garage set" and
  "there was no planning read at all". Spec 05's findings, reviews and
  fingerprints are reproduced through it exactly (CR-2).

  Step 8 adds `resolve_block/3`.
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

  @type resolve_result :: %{
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil,
          garage_source: :attribute | :route | :default | :none,
          conflict:
            nil
            | [
                %{
                  service_id: String.t(),
                  garage_id: Ecto.UUID.t() | nil,
                  vehicle_type_id: Ecto.UUID.t() | nil
                }
              ]
        }

  @doc """
  Returns the context that reproduces spec 05's behaviour: a layover and nothing
  else.

  `min_layover_minutes` is the value the settings carry; every other field keeps
  the struct's default, so the maps are empty, the marked-stop set is empty and
  the fleet and trip distances are empty lists and maps. `planning?` is `false`,
  which is what distinguishes this context from a version that has genuinely
  planned nothing (CR-2).
  """
  @spec layover_only(0..120) :: t()
  def layover_only(min_layover_minutes) when is_integer(min_layover_minutes) do
    %__MODULE__{min_layover_minutes: min_layover_minutes, planning?: false}
  end

  @doc """
  Returns the fingerprint of every field of `context`, as lowercase SHA-256 hex.

  The value is a canonical encoding of the whole struct, so two equal contexts
  digest alike however their maps were built, and any change to any field
  digests differently. That includes fields the calling plan did not read: a
  garage coordinate, a fleet count or an attribute row for a service the day does
  not use all change the digest, and the *absence* of such a row is part of what
  is encoded rather than an absence that compares equal to one (INV-7).

  The over-invalidation is the point, not a side effect. A preview invalidated by
  an unrelated planning input costs one regeneration; a fingerprint that omitted
  an input the plan would act on would let a write through that nobody reviewed
  (R12, critique Must 2).

  Map entries are sorted and each key is canonicalized in its own right, because
  this context is keyed by tuples - `{service_id, block_id}` and `{ref, ref}` -
  that no stringified-key encoding can represent. A `MapSet` is hashed as its
  sorted members rather than as its internal map, a `Decimal` as its normalized
  string, and a float is kept as the float it is.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = context) do
    context
    |> Map.from_struct()
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # A decimal is hashed as its normalized value, so a stored `1.30` and a `1.3`
  # are the number they are rather than two of them. `Decimal.to_string/2` alone
  # keeps the stored scale, which is how the two earlier copies of this canonical
  # form in `Gtfs.Calendars` and `Gtfs.RoutePatterns` read it; normalizing is one
  # call more and removes a class of spurious staleness. No field of a context
  # built by `Blocking` holds a decimal — coordinates and circuity arrive as
  # floats — so this clause is reached only by a hand-assembled struct.
  defp canonical(%Decimal{} = value) do
    {:decimal, value |> Decimal.normalize() |> Decimal.to_string(:normal)}
  end

  defp canonical(%MapSet{} = value), do: {:mapset, value |> MapSet.to_list() |> canonical()}

  defp canonical(%_{} = value), do: value |> Map.from_struct() |> canonical()

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, entry} -> {canonical(key), canonical(entry)} end)
    |> Enum.sort()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&canonical/1) |> List.to_tuple()
  end

  defp canonical(value), do: value
end
