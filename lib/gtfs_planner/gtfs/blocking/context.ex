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

  `resolve_block/3` is the one place a block's garage and vehicle type are
  decided (R4, INV-9). Every consumer — checks, the day load, the generator, the
  export and the page — reads this result rather than repeating the rule, so a
  block that runs from two garages is described the same way everywhere, and the
  block that names two different garages is reported rather than silently
  resolved to whichever row happened to be read first.
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks

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
  Returns the garage, the vehicle type and any disagreement for one block.

  R4 decides both values in the same order, and the rows keyed
  `{service_id, block_id}` come first because they are the only per-block
  statement an operator has made: the row belonging to the first trip's service
  names the block's garage, and its type. Failing that the first trip's route
  home garage and the route's required type; failing that the version's default
  garage; and failing that nothing. `garage_source` names which of the four
  answered, so a page can show "from route" against a garage an operator never
  set for this block.

  "The first trip" is the head of `Checks.sequence/1` — the earliest plottable,
  non-frequency trip — because that is the order the whole block is planned,
  checked and moved in. A block whose trips are all frequency-based or all
  unplottable has no sequence, so the trip with the smallest `trip_id` stands in:
  the fallback is arbitrary, and the sequence's own last tiebreak, but a block
  still has one first trip rather than none. A block with no trips at all
  resolves to `nil` and `:none`.

  Rows naming a garage or a vehicle type that the context does not carry resolve
  as `nil`, and the resolution falls through to the next source. A deleted
  garage is not a garage the block can pull out of, and a type from another
  organization is not this block's type; reporting a UUID nothing can act on
  would put a dead identifier in every downstream plan.

  `conflict` is not filtered the same way on purpose. It is the data problem a
  user has to fix, and a row naming a garage that has since been deleted is
  exactly what they need to see beside the row that names a live one, so `conflict`
  compares the stored values. It is a list of every row for the block's services
  — not only the disagreeing ones — because the answer to "which garage is this
  block in on Saturday?" is the whole table, and because a report that listed
  only the rows that disagreed would not say what a calendar resolves to when it
  is not the first trip's.

  Rows are returned in `service_id` order. R4 already says which row is used
  (the first trip's service's), so the list is a report and not a ranking, and
  sorting it keeps the answer independent of the order the trips arrived in.

  The function reads its arguments only: no `Repo`, clock, file or network call
  (CR-1), which is what lets the checks, the generator and the export resolve a
  block without re-reading the rows they were built from.
  """
  @spec resolve_block(t(), String.t(), [Checks.trip_row()]) :: resolve_result()
  def resolve_block(%__MODULE__{} = context, block_id, trips)
      when is_binary(block_id) and is_list(trips) do
    first = first_trip(trips)
    rows = block_rows(context, block_id, trips)

    {garage_id, garage_source} = resolve_garage(context, first, rows)

    %{
      garage_id: garage_id,
      vehicle_type_id: resolve_vehicle_type(context, first, rows),
      garage_source: garage_source,
      conflict: conflict(rows)
    }
  end

  # `Checks.sequence/1` is the order the block is planned in, so the trip that
  # pulls out is the one that pulls out first. When nothing sequences — every
  # trip frequency-based, or every trip without usable endpoint times — the block
  # still has a first trip for R4 to read, and the smallest `trip_id` is the
  # same tiebreak `Checks.sequence/1` ends on, so the fallback is at least
  # consistent with it.
  defp first_trip(trips) do
    case Checks.sequence(trips) do
      [first | _] -> first
      [] -> Enum.min_by(trips, & &1.trip_id, fn -> nil end)
    end
  end

  # The rows for `{service_id, block_id}` of every service the block's trips run
  # on, in `service_id` order. A row for a service this block has no trip on is
  # not read: it belongs to another day type's plan for the same number, and R4
  # scopes a block to the services it actually runs.
  defp block_rows(context, block_id, trips) do
    trips
    |> Enum.map(& &1.service_id)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn service_id ->
      case Map.fetch(context.attributes, {service_id, block_id}) do
        {:ok, row} -> [Map.put(row, :service_id, service_id)]
        :error -> []
      end
    end)
  end

  defp resolve_garage(context, first, rows) do
    case attribute_garage(context, first, rows) do
      nil -> fallback_garage(context, first)
      garage_id -> {garage_id, :attribute}
    end
  end

  defp fallback_garage(context, first) do
    case route_garage(context, first) do
      nil ->
        case known_garage(context, context.default_garage_id) do
          nil -> {nil, :none}
          garage_id -> {garage_id, :default}
        end

      garage_id ->
        {garage_id, :route}
    end
  end

  # A row that sets no type does not answer, exactly as a row that sets no garage
  # does, and the route's required type is consulted next. "Else the first trip's
  # route required type" is the same sentence for both values, so the two resolve
  # the same way.
  defp resolve_vehicle_type(context, first, rows) do
    case attribute_vehicle_type(context, first, rows) do
      nil -> route_vehicle_type(context, first)
      type_id -> type_id
    end
  end

  # R4 uses the row of the first trip's service, not any row. A block whose trips
  # span two services has one garage, and the spec names the one that decides it.
  defp attribute_garage(context, first, rows) do
    case first_row(first, rows) do
      %{garage_id: garage_id} -> known_garage(context, garage_id)
      nil -> nil
    end
  end

  defp attribute_vehicle_type(context, first, rows) do
    case first_row(first, rows) do
      %{vehicle_type_id: type_id} -> known_vehicle_type(context, type_id)
      nil -> nil
    end
  end

  defp first_row(nil, _rows), do: nil

  defp first_row(%{service_id: service_id}, rows),
    do: Enum.find(rows, &(&1.service_id == service_id))

  defp route_garage(_context, nil), do: nil

  defp route_garage(context, first) do
    case Map.get(context.route_settings, first.route_id) do
      %{garage_id: garage_id} -> known_garage(context, garage_id)
      nil -> nil
    end
  end

  defp route_vehicle_type(_context, nil), do: nil

  defp route_vehicle_type(context, first) do
    case Map.get(context.route_settings, first.route_id) do
      %{required_vehicle_type_id: type_id} -> known_vehicle_type(context, type_id)
      nil -> nil
    end
  end

  # A UUID the context does not carry is not a garage or a type this version can
  # run, so it answers `nil` and the resolution moves on. `Map.get/3` rather than
  # `nil` checks, because the context's map values are non-nil and an absent key
  # is the same answer as a rejected ID.
  defp known_garage(context, garage_id),
    do: if(Map.get(context.garages, garage_id), do: garage_id)

  defp known_vehicle_type(context, type_id),
    do: if(Map.get(context.vehicle_types, type_id), do: type_id)

  defp conflict([]), do: nil

  defp conflict(rows) do
    garages = rows |> Enum.map(& &1.garage_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    types = rows |> Enum.map(& &1.vehicle_type_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if length(garages) > 1 or length(types) > 1 do
      Enum.map(rows, &Map.take(&1, [:service_id, :garage_id, :vehicle_type_id]))
    end
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
