defmodule GtfsPlanner.Alerts.Feed do
  @moduledoc """
  Encodes one organization's accepted Alerts as a GTFS-Realtime feed, in both
  the protobuf and the JSON representation of the same message.

  The input is a list of *snapshots*: the sanitized public intent an accepted
  revision captured, already reduced to GTFS identities and absolute instants by
  the commands that accept a publication request. This module never reads the
  database, never receives an `Ecto` struct and never resolves a row UUID, so
  there is no path from an authoring draft to a rider-facing selector: a
  snapshot is a plain map with exactly the keys below, and anything else in it —
  a script key, a fact digest, an actor, a revision history, a draft answer — is
  simply never read.

  ## The snapshot contract

  Each snapshot is a map shaped like:

      %{
        public_entity_id: "6f1c...",          # the stable public entity id
        accepted_revision: 3,
        notice_at: 1_792_000_000,             # UTC seconds
        periods: [%{start: 1_792_003_600, end: 1_792_010_800}],
        effect: :no_service,
        cause: :weather,
        cause_detail: "ice",
        header: "No service on Route 12",
        description: "...",
        url: "https://example.org/alerts",
        scope: %{
          shape: :routes,
          direction_id: 0,
          agencies: ["Metro Transit"],
          routes: ["12", "12X"],
          stops: [],
          route_stops: [%{route_id: "12", stop_id: "STOP1"}],
          trips: [%{trip_id: "T1", start_date: ~D[2026-10-05], start_time: "08:00:00"}]
        }
      }

  Every identity in `scope` is a GTFS feed identifier captured from the trusted
  source, never a row UUID. `start_time` is the trip instance's own first
  departure, spelled the way `frequencies.txt` spells one and possibly past
  `24:00:00`; it is only present when the source actually had one, and it is
  normalized through `GtfsPlanner.Gtfs.GtfsTime` rather than passed through
  unchecked.

  The scope `shape` decides which identities become informed entities:

    * `:system` names the captured agencies. The organization's short name is
      never an `agency_id`, so a scope with no captured agency is refused.
    * `:routes` names the captured routes, which is how a mode selector reaches
      the feed: a mode is expanded to the explicit route identifiers of the
      routes that have that mode, and a snapshot whose routes are empty is
      refused rather than published as a guessed `route_type`.
    * `:stop_all_routes` names the captured stops.
    * `:route_stops` emits one selector per pair carrying *both* the route and
      the stop, because a consumer that honours informed entities intersects the
      fields of a single selector: two separate selectors would widen the alert
      to the whole route and to the whole stop.
    * `:trips` emits a dated trip descriptor, with the frequency start time
      when the source had one.

  ## When an entity is included

  Inclusion is decided against `generated_at` alone, so the same snapshots
  always produce the same feed for the same header timestamp:

    * A snapshot is omitted until its `notice_at` has passed. An accepted
      future period therefore appears once notice begins.
    * A snapshot whose every period has already ended is omitted, and a feed
      with no eligible snapshot is a valid feed: the header, no entities.

  Periods are carried as accepted, so the wire content of an alert a rider can
  see is exactly what was accepted and is never recomputed at refresh time. Only
  the header timestamp moves.

  ## Refusals

  `encode/2` refuses rather than publishing something narrower or vaguer than
  what was accepted:

    * `:selector_source_required` — the scope names no usable GTFS identity, or a
      trip is missing its trip id or its service date. This is the same reason
      the acceptance commands report, so an unpublishable scope is refused at
      both boundaries for one cause.
    * `:invalid_snapshot` — the snapshot is structurally unusable: no public
      entity id, no periods, no header text, an effect or cause outside
      `GtfsPlanner.Alerts.Alert`'s own vocabulary, or two snapshots claiming one
      public entity id.
    * `:too_large` — either representation exceeds `max_bytes/0`.

  Nothing is truncated. An organization that cannot be published whole is not
  published partially, because a partial feed looks complete to a consumer.

  ## How the two representations relate

  Both come from one `TransitRealtime.FeedMessage`, so they cannot disagree in
  meaning. They do not look identical, because the JSON follows the canonical
  protobuf JSON mapping:

    * A 64-bit field is a JSON *string*, so the header timestamp and every
      period's `start`/`end` read as `"1792000000"` rather than a number. That
      is the mapping GTFS-Realtime JSON consumers expect, and a JSON parser
      that rounds a large integer is the reason it exists.
    * A field left at its `proto2` declared default is omitted, so the
      `incrementality` key is absent rather than `"FULL_DATASET"`. Absent means
      the declared default, which is `FULL_DATASET`; `feed_version` is absent
      for the same shape of reason and carries no such default.

  Emitting every field with `emit_unpopulated: true` was rejected: it would
  publish nulls and empty strings for message types an alert never uses
  (`VehiclePosition`, `TripUpdate`, `Shape`), which is noise a consumer has to
  learn to ignore.
  """

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Gtfs.GtfsTime

  @max_bytes 16 * 1_024 * 1_024
  @realtime_version "2.0"
  @service_date_format "%Y%m%d"

  @typedoc "One instant, in UTC seconds since the Unix epoch."
  @type instant :: integer()

  @typedoc """
  One accepted period. A nil `end` is an open period, which an unknown,
  estimated or check-in-only end always produces.
  """
  @type period :: %{start: instant(), end: instant() | nil}

  @typedoc "The scope selector an accepted snapshot captured, in GTFS identities."
  @type scope :: %{
          shape: atom(),
          direction_id: 0 | 1 | nil,
          agencies: [String.t()],
          routes: [String.t()],
          stops: [String.t()],
          route_stops: [%{route_id: String.t(), stop_id: String.t()}],
          trips: [%{trip_id: String.t(), start_date: Date.t(), start_time: String.t() | nil}]
        }

  @typedoc "One accepted snapshot: the whole public intent of one alert."
  @type snapshot :: %{
          public_entity_id: String.t(),
          accepted_revision: pos_integer(),
          notice_at: instant(),
          periods: [period()],
          effect: atom() | nil,
          cause: atom() | nil,
          cause_detail: String.t() | nil,
          header: String.t() | nil,
          description: String.t() | nil,
          url: String.t() | nil,
          scope: scope()
        }

  @doc """
  The byte ceiling either representation must stay under.

  The 16 MiB budget is a documented initial ceiling rather than a measured
  workload, so it is named here instead of being repeated by every caller that
  has to check it.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Encodes the eligible snapshots as one `FULL_DATASET` feed message, in both
  representations.

  `generated_at` is the header timestamp in UTC seconds, and the only clock this
  module reads, so a caller decides notice and expiry by when it calls rather
  than through a hidden dependency. Both representations come from the same
  `TransitRealtime.FeedMessage` struct, so they cannot disagree.

  `included` maps each included `public_entity_id` to the `accepted_revision` it
  was built from, which is what lets a receipt name the revision a served feed
  actually contains.
  """
  @spec encode([snapshot()], instant()) ::
          {:ok, %{pb: binary(), json: binary(), included: %{String.t() => pos_integer()}}}
          | {:error, atom()}
  def encode(snapshots, generated_at)
      when is_list(snapshots) and is_integer(generated_at) and generated_at >= 0 do
    with {:ok, eligible} <- eligible(snapshots, generated_at),
         {:ok, entities, included} <- entities(eligible),
         {:ok, message} <- message(entities, generated_at) do
      encode_message(message, included)
    end
  end

  def encode(_snapshots, _generated_at), do: {:error, :invalid_snapshot}

  defp encode_message(message, included) do
    pb = Protobuf.encode(message)

    case Protobuf.JSON.encode(message) do
      {:ok, json} ->
        if byte_size(pb) <= @max_bytes and byte_size(json) <= @max_bytes do
          {:ok, %{pb: pb, json: json, included: included}}
        else
          {:error, :too_large}
        end

      {:error, _reason} ->
        {:error, :invalid_snapshot}
    end
  end

  # An entity is included once notice has begun and while at least one of its
  # periods is still open. Future periods stay: an accepted period that has not
  # started is part of the same alert, and dropping it would tell riders the
  # disruption ends before it does.
  defp eligible(snapshots, generated_at) do
    Enum.reduce_while(snapshots, {:ok, []}, fn snapshot, {:ok, kept} ->
      case include?(snapshot, generated_at) do
        {:ok, true} -> {:cont, {:ok, [snapshot | kept]}}
        {:ok, false} -> {:cont, {:ok, kept}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp include?(%{notice_at: notice_at, periods: periods}, generated_at)
       when is_integer(notice_at) and is_list(periods) and periods != [] do
    {:ok, notice_at <= generated_at and Enum.any?(periods, &open?(&1, generated_at))}
  end

  defp include?(_snapshot, _generated_at), do: {:error, :invalid_snapshot}

  defp open?(%{end: nil}, _generated_at), do: true
  defp open?(%{end: end_at}, generated_at) when is_integer(end_at), do: end_at > generated_at
  defp open?(_period, _generated_at), do: false

  defp entities(snapshots) do
    Enum.reduce_while(snapshots, {:ok, [], %{}}, fn snapshot, {:ok, built, included} ->
      with {:ok, id} <- public_entity_id(snapshot),
           {:ok, alert} <- alert(snapshot),
           false <- Map.has_key?(included, id) do
        entity = %TransitRealtime.FeedEntity{id: id, alert: alert}
        {:cont, {:ok, [entity | built], Map.put(included, id, snapshot.accepted_revision)}}
      else
        true -> {:halt, {:error, :invalid_snapshot}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, built, included} -> {:ok, Enum.reverse(built), included}
      {:error, reason} -> {:error, reason}
    end
  end

  defp public_entity_id(%{public_entity_id: id}) when is_binary(id) do
    case String.trim(id) do
      "" -> {:error, :invalid_snapshot}
      trimmed -> {:ok, trimmed}
    end
  end

  defp public_entity_id(_snapshot), do: {:error, :invalid_snapshot}

  defp alert(snapshot) do
    with {:ok, header} <- header(snapshot),
         {:ok, effect} <- effect(snapshot),
         {:ok, cause} <- cause(snapshot),
         {:ok, informed} <- informed_entities(snapshot),
         {:ok, impact} <- impact_periods(snapshot) do
      {:ok,
       %TransitRealtime.Alert{
         informed_entity: informed,
         impact_period: impact,
         cause: cause,
         effect: effect,
         url: optional_text(snapshot[:url]),
         header_text: header,
         description_text: optional_text(snapshot[:description]),
         cause_detail: cause_detail(cause, snapshot[:cause_detail])
       }}
    end
  end

  # A cause detail is the agency's own wording for a cause, so it rides along
  # with a cause and is dropped without one: the proto requires `Cause` whenever
  # `cause_detail` is set, and a detail alone would read as a different,
  # machine-defaulted cause.
  defp cause_detail(nil, _detail), do: nil
  defp cause_detail(_cause, detail), do: optional_text(detail)

  # A rider-facing alert with no text says nothing, so it is refused rather than
  # published as a bare entity.
  defp header(%{header: header}) when is_binary(header) do
    case String.trim(header) do
      "" -> {:error, :invalid_snapshot}
      trimmed -> {:ok, text(trimmed)}
    end
  end

  defp header(_snapshot), do: {:error, :invalid_snapshot}

  defp effect(%{effect: nil}), do: {:ok, nil}

  defp effect(%{effect: effect}),
    do: enum_value(TransitRealtime.Alert.Effect, Alert.effects(), effect)

  defp effect(_snapshot), do: {:error, :invalid_snapshot}

  defp cause(%{cause: nil}), do: {:ok, nil}
  defp cause(%{cause: cause}), do: enum_value(TransitRealtime.Alert.Cause, Alert.causes(), cause)
  defp cause(_snapshot), do: {:error, :invalid_snapshot}

  # An effect or cause outside the alert's own vocabulary is refused rather than
  # defaulted, so an unrecognized value can never publish as `UNKNOWN_EFFECT` and
  # read to a rider as a different fact.
  defp enum_value(module, allowed, value) do
    wanted = value |> Atom.to_string() |> String.upcase() |> String.to_atom()

    if is_atom(value) and value in allowed and Map.has_key?(struct(module), wanted) do
      {:ok, wanted}
    else
      {:error, :invalid_snapshot}
    end
  end

  defp impact_periods(%{periods: periods}) when is_list(periods) and periods != [] do
    Enum.reduce_while(periods, {:ok, []}, fn
      %{start: start} = period, {:ok, built} when is_integer(start) ->
        {:cont, {:ok, [%TransitRealtime.TimeRange{start: start, end: period[:end]} | built]}}

      _period, _built ->
        {:halt, {:error, :invalid_snapshot}}
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp impact_periods(_snapshot), do: {:error, :invalid_snapshot}

  defp informed_entities(snapshot) do
    case snapshot[:scope] do
      %{shape: shape} = scope when is_atom(shape) -> selectors(scope)
      _other -> {:error, :selector_source_required}
    end
  end

  # `:system` names agencies, never the organization's short name.
  defp selectors(%{shape: :system, agencies: agencies}) do
    case present_ids(agencies) do
      [] -> {:error, :selector_source_required}
      ids -> {:ok, Enum.map(ids, &%TransitRealtime.EntitySelector{agency_id: &1})}
    end
  end

  # A mode reaches the feed as the explicit routes it was expanded to, and a
  # direction is only meaningful on a selector that also names a route.
  defp selectors(%{shape: :routes, routes: routes} = scope) do
    case present_ids(routes) do
      [] ->
        {:error, :selector_source_required}

      ids ->
        direction_id = direction(scope)

        {:ok,
         Enum.map(
           ids,
           &%TransitRealtime.EntitySelector{
             route_id: &1,
             direction_id: direction_id
           }
         )}
    end
  end

  defp selectors(%{shape: :stop_all_routes, stops: stops}) do
    case present_ids(stops) do
      [] -> {:error, :selector_source_required}
      ids -> {:ok, Enum.map(ids, &%TransitRealtime.EntitySelector{stop_id: &1})}
    end
  end

  # One selector carries both ends of the pair. Splitting them would widen the
  # alert to every stop on the route and to every route at the stop.
  defp selectors(%{shape: :route_stops, route_stops: route_stops}) do
    pairs =
      route_stops
      |> List.wrap()
      |> Enum.map(&route_stop_selector/1)
      |> Enum.reject(&is_nil/1)

    case pairs do
      [] -> {:error, :selector_source_required}
      _pairs -> {:ok, pairs}
    end
  end

  defp selectors(%{shape: :trips, trips: trips}) do
    trips
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn trip, {:ok, built} ->
      case trip_selector(trip) do
        {:ok, selector} -> {:cont, {:ok, [selector | built]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :selector_source_required}
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp selectors(_scope), do: {:error, :selector_source_required}

  defp route_stop_selector(%{route_id: route_id, stop_id: stop_id}) do
    with route when route != "" <- trim(route_id),
         stop when stop != "" <- trim(stop_id) do
      %TransitRealtime.EntitySelector{route_id: route, stop_id: stop}
    else
      _blank -> nil
    end
  end

  defp route_stop_selector(_pair), do: nil

  # A trip repeats across its service dates, so its service date is part of its
  # identity and a descriptor without one is not a selector a consumer can
  # apply. A frequency-based trip additionally needs its actual start time, which
  # is carried when the source had one and omitted when it did not.
  defp trip_selector(%{trip_id: trip_id, start_date: %Date{} = start_date} = trip)
       when is_binary(trip_id) do
    case trim(trip_id) do
      "" -> {:error, :selector_source_required}
      trimmed -> trip_entity(trimmed, start_date, trip[:start_time])
    end
  end

  defp trip_selector(_trip), do: {:error, :selector_source_required}

  defp trip_entity(trip_id, start_date, start_time) do
    with {:ok, formatted} <- start_time(start_time) do
      {:ok,
       %TransitRealtime.EntitySelector{
         trip: %TransitRealtime.TripDescriptor{
           trip_id: trip_id,
           start_date: Calendar.strftime(start_date, @service_date_format),
           start_time: formatted
         }
       }}
    end
  end

  defp start_time(nil), do: {:ok, nil}

  defp start_time(value) when is_binary(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> {:ok, GtfsTime.format(seconds)}
      {:error, :invalid_time} -> {:error, :selector_source_required}
    end
  end

  defp start_time(_value), do: {:error, :selector_source_required}

  defp direction(%{direction_id: direction_id}) when direction_id in [0, 1], do: direction_id
  defp direction(_scope), do: nil

  defp present_ids(nil), do: []
  defp present_ids([]), do: []

  defp present_ids(ids) when is_list(ids) do
    ids |> Enum.map(&trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp present_ids(_ids), do: []

  defp message(entities, generated_at) do
    {:ok,
     %TransitRealtime.FeedMessage{
       header: %TransitRealtime.FeedHeader{
         gtfs_realtime_version: @realtime_version,
         incrementality: :FULL_DATASET,
         timestamp: generated_at
       },
       entity: entities
     }}
  end

  defp text(value) when is_binary(value) do
    %TransitRealtime.TranslatedString{
      translation: [%TransitRealtime.TranslatedString.Translation{text: value}]
    }
  end

  defp text(_value), do: nil

  defp optional_text(value) when value in [nil, ""], do: nil
  defp optional_text(value) when is_binary(value), do: text(value)
  defp optional_text(_value), do: nil

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
