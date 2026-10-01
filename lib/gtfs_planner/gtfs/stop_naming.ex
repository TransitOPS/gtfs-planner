defmodule GtfsPlanner.Gtfs.StopNaming do
  @moduledoc """
  What a stop placed on a map should be called, and what might be wrong with a
  name once it is typed.

  Naming is the last thing a stop editor does and the thing riders read, so this
  module does two separable jobs. It proposes a name from what reverse geocoding
  found, with the alternatives a person might have meant. And it advises on a
  name that has problems — shouting, a stop code pasted into the name, a
  direction word that will not match the sign — because those are the mistakes
  that survive into a published feed and are expensive to find later.

  Both are pure. Where a name comes from — the reverse geocoder, the nearby
  stops query — is the caller's concern; what makes a good one is here.

  The connector is a parameter rather than a constant because it varies by feed:
  "Main St & 3rd Ave" and "Main St at 3rd Ave" are both correct, and a version's
  existing stops are the only evidence of which this one uses.
  """

  # The default when a version has no stops to learn from. " & " is what US
  # transit feeds overwhelmingly use, and the two-street form reads "On & Cross".
  @default_connector " & "

  # How close an amenity has to be for its name to be worth offering as a place
  # name. Tighter than the neighbour radius: an amenity's name describes a
  # building, so offering it as a street name is only sensible when the stop is
  # essentially at that building.
  @amenity_metres 90.0

  # GTFS stop names have no length limit, but a name past this is not a name a
  # rider can read on a sign or a display.
  @max_name_length 50

  # `next_stop_id/3` falls back to a slug rather than a number when the version
  # has no numeric IDs at all, and the slug needs a limit of its own.
  @max_slug_length 64

  @type place :: %{
          optional(:street) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:distance_m) => float() | nil
        }

  @type fallback :: {0..4, String.t()}

  @doc """
  The connector this version's stops use, or the default when it has none.

  The most common one wins rather than the first one seen: a feed is usually
  consistent, so the mode is the real answer and a single odd stop cannot
  change it. Ties keep the earlier value, so the result is stable.
  """
  @spec connector([String.t()]) :: String.t()
  def connector([]), do: @default_connector

  def connector(names) do
    names
    |> Enum.map(&connector_in/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_connector, count} -> -count end)
    |> case do
      [{most_common, _count} | _rest] -> most_common
      [] -> @default_connector
    end
  end

  @doc """
  The connector inside a single stop name, or nil when it has none.
  """
  @spec connector_in(String.t()) :: String.t() | nil
  def connector_in(name) when is_binary(name) do
    cond do
      String.contains?(name, " & ") -> " & "
      String.contains?(name, " at ") -> " at "
      String.contains?(name, " and ") -> " and "
      true -> nil
    end
  end

  def connector_in(_name), do: nil

  @doc """
  A proposed name for a placed stop, and the alternatives worth offering.

  Every street reverse geocoding matched goes in the name, joined by this
  version's connector, because a stop at an intersection is named for both
  streets. The alternatives are the other things that might have been meant: the
  names of neighbouring stops, and an amenity within `@amenity_metres` when the
  editor has asked for amenities.

  `neighbour_names` arrives already filtered. The radius that decides which stops
  count as neighbours belongs with the query that finds them, in the Map view,
  so this function takes the names rather than the coordinates and
  re-deciding the distance here would put a threshold in two places.

  The name is `nil` rather than a guess when reverse geocoding found nothing,
  so the caller shows an empty field instead of a wrong one.
  """
  @spec suggestions([place()], [String.t()], String.t()) ::
          %{name: String.t() | nil, alternatives: [String.t()]}
  def suggestions(places, neighbour_names, connector) do
    streets = places |> Enum.map(&place_street/1) |> Enum.reject(&blank?/1) |> Enum.uniq()

    alternatives =
      nearby_amenity(streets ++ neighbour_names, places)
      |> Enum.uniq()
      |> Kernel.--(streets)

    %{name: join_streets(streets, connector), alternatives: alternatives}
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_other), do: true

  # A place with a street is a street; a place with only a name is a point of
  # interest, which belongs in the alternatives rather than the name.
  defp place_street(%{street: street}) when is_binary(street), do: String.trim(street)
  defp place_street(_place), do: nil

  # An amenity's name describes a building, so it is only worth offering when the
  # stop is essentially at that building — much tighter than the neighbour
  # radius, and tighter still than the `:amenities` request that found it.
  defp nearby_amenity(candidates, places) do
    case Enum.find(places, &nearby_amenity?/1) do
      nil -> candidates
      place -> [place.name | candidates]
    end
  end

  defp nearby_amenity?(%{street: street, name: name, distance_m: distance})
       when is_binary(name) and is_number(distance) do
    (is_nil(street) or street == "") and distance <= @amenity_metres
  end

  defp nearby_amenity?(_place), do: false

  defp join_streets([], _connector), do: nil
  defp join_streets([street], _connector), do: street
  defp join_streets(streets, connector), do: Enum.join(streets, connector)

  @doc """
  A stop ID for a newly placed stop that does not collide with an existing one.

  A version with numeric IDs gets the highest plus one, never filling a gap: a
  gap means an ID was retired, and reusing it would make a retired stop's
  history point at a live one. Garage IDs are skipped for the same reason — a
  garage is not a stop, but it occupies a number in the same series.

  A version with no numeric IDs at all (slugs like `platform_main_st`) has no
  series to continue, so the name becomes the ID, which is unique by
  construction and is what `Stop.generate_stop_id/2` already produces.
  """
  @spec next_stop_id([String.t()], [String.t()], fallback()) :: String.t()
  def next_stop_id(existing_ids, garage_ids, fallback) do
    taken = MapSet.new(existing_ids ++ garage_ids)

    case highest_numeric_id(existing_ids ++ garage_ids) do
      nil -> slug_fallback(fallback, taken)
      highest -> next_free(highest + 1, taken)
    end
  end

  defp highest_numeric_id(ids) do
    ids
    |> Enum.map(&Integer.parse/1)
    |> Enum.flat_map(fn
      {integer, ""} -> [integer]
      _otherwise -> []
    end)
    |> case do
      [] -> nil
      integers -> Enum.max(integers)
    end
  end

  # A taken number is skipped rather than reused, so a gap left by a retired
  # garage or a deleted stop stays a gap.
  defp next_free(candidate, taken) do
    if MapSet.member?(taken, Integer.to_string(candidate)) do
      next_free(candidate + 1, taken)
    else
      Integer.to_string(candidate)
    end
  end

  defp slug_fallback({location_type, name}, taken) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.replace(~r/_{2,}/, "_")
      |> String.trim("_")
      |> String.slice(0, @max_slug_length)

    base = location_type_slug(location_type) <> "_" <> slug

    if slug == "" or MapSet.member?(taken, base) do
      unique_slug(base, taken)
    else
      base
    end
  end

  defp unique_slug(base, taken), do: unique_slug(base, taken, 2)

  defp unique_slug(base, taken, suffix) do
    candidate = "#{base}_#{suffix}"

    if MapSet.member?(taken, candidate) do
      unique_slug(base, taken, suffix + 1)
    else
      candidate
    end
  end

  defp location_type_slug(0), do: "platform"
  defp location_type_slug(1), do: "station"
  defp location_type_slug(2), do: "entrance"
  defp location_type_slug(3), do: "node"
  defp location_type_slug(4), do: "boarding"
  defp location_type_slug(_other), do: "stop"

  @doc """
  The share of stops whose sign code is simply their ID repeated.

  A feed where every `stop_code` equals its `stop_id` has no sign numbering at
  all, which means a sign conflict cannot be resolved by the code and every stop
  needs a code chosen for it. A feed with a low share is doing sign numbering
  properly, and a caller can rely on the code to disambiguate.
  """
  @spec code_is_id_share([%{stop_id: String.t(), stop_code: String.t() | nil}]) :: float()
  def code_is_id_share([]), do: 0.0

  def code_is_id_share(stops) do
    with_codes = Enum.filter(stops, &(is_binary(&1[:stop_code]) and &1[:stop_code] != ""))

    case with_codes do
      [] -> 0.0
      _ -> Enum.count(with_codes, &(&1.stop_code == &1.stop_id)) / length(with_codes)
    end
  end

  @doc """
  The name of another stop already using this sign number, or nil.

  A sign number identifies a stop to a rider, so two stops sharing one is a real
  conflict and the editor has to pick another. `except_stop_id` is the stop being
  edited, which is expected to match itself.
  """
  @spec sign_conflict(
          String.t() | nil,
          [%{stop_id: String.t(), stop_code: String.t() | nil}],
          String.t() | nil
        ) :: String.t() | nil
  def sign_conflict(nil, _stops, _except_stop_id), do: nil
  def sign_conflict("", _stops, _except_stop_id), do: nil

  def sign_conflict(code, stops, except_stop_id) do
    stops
    |> Enum.find(fn stop ->
      stop[:stop_code] == code and stop[:stop_id] != except_stop_id
    end)
    |> case do
      nil -> nil
      stop -> stop_name(stop) || stop[:stop_id]
    end
  end

  defp stop_name(%{stop_name: name}) when is_binary(name) and name != "", do: name
  defp stop_name(_stop), do: nil

  @doc """
  What might be wrong with a stop name, as a list of sentences.

  Each check is a mistake that survives into a published feed and is expensive
  to find once riders have the data. The order is the order an editor should fix
  them: what the name says, then what it repeats, then how it is written.
  """
  @spec advice(String.t(), String.t() | nil, String.t() | nil, String.t()) :: [String.t()]
  def advice(name, code, description, connector) when is_binary(name) do
    []
    |> direction_advice(name)
    |> connector_advice(name, connector)
    |> capital_advice(name)
    |> code_advice(name, code)
    |> length_advice(name)
    |> description_advice(name, description)
  end

  def advice(_name, _code, _description, _connector), do: []

  @doc "The direction words a name uses, which belong in the headsign instead."
  @spec direction_words() :: [String.t()]
  def direction_words,
    do: ~w(northbound southbound eastbound westbound nb sb eb wb inbound outbound n s e w)

  defp direction_advice(advice, name) do
    words = name |> String.downcase() |> String.split(~r/[^a-z]+/) |> Enum.filter(&(&1 != ""))

    case Enum.filter(words, &(&1 in direction_words())) do
      [] ->
        advice

      found ->
        ["#{direction_phrase(found)} reads as a direction; riders look for it on the sign."]
    end
  end

  defp direction_phrase([one]), do: "'#{String.upcase(one)}'"
  defp direction_phrase(found), do: "'#{Enum.map_join(found, "', '", &String.upcase(&1))}'"

  # A name that does not use this version's connector is a name that will not
  # match how the rest of the feed is written.
  defp connector_advice(advice, name, connector) do
    other = Enum.reject([connector, " & ", " at ", " and "], &(&1 == connector))

    case Enum.find(other, &String.contains?(name, &1)) do
      nil ->
        advice

      found ->
        [
          "This version joins streets with #{inspect(connector)}; this name uses #{inspect(found)}."
        ]
    end
  end

  # A name in capitals cannot be read aloud, and riders read stop names from
  # announcements and displays where capitals are shouted.
  defp capital_advice(advice, name) do
    letters = String.replace(name, ~r/[^A-Za-z]/, "")

    if letters != "" and letters == String.upcase(letters) and String.length(letters) > 1 do
      advice ++ ["The name is all capitals; riders cannot read it comfortably."]
    else
      advice
    end
  end

  # A stop code pasted into the name is the most common import mistake: the field
  # is right there, so the name becomes "1434 Main St & SE 1st St".
  defp code_advice(advice, name, code) when is_binary(code) and code != "",
    do: advice ++ sign_number_advice(name, code)

  defp code_advice(advice, _name, _code), do: advice

  defp sign_number_advice(name, code) do
    if String.contains?(name, code) do
      ["The sign number #{code} is in the name; it belongs in the stop code."]
    else
      []
    end
  end

  defp length_advice(advice, name) do
    if String.length(name) > @max_name_length do
      [
        "The name is #{String.length(name)} characters; a sign is readable to about #{@max_name_length}."
      ]
    else
      advice
    end
  end

  # A description repeating the name adds nothing a rider can act on.
  defp description_advice(advice, name, description) when is_binary(description) do
    trimmed = String.trim(description)

    cond do
      trimmed == "" ->
        advice

      String.downcase(trimmed) == String.downcase(String.trim(name)) ->
        advice ++ ["The description repeats the name; say what a rider needs to find it instead."]

      String.contains?(description, "stop") or String.contains?(description, "station") ->
        advice ++ ["The description says stop or station; that is what every stop is."]

      true ->
        advice
    end
  end

  defp description_advice(advice, _name, _description), do: advice
end
