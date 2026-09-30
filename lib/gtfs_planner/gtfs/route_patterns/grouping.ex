defmodule GtfsPlanner.Gtfs.RoutePatterns.Grouping do
  @moduledoc """
  The pure rules behind the left-out trip grouping review.

  Grouping never reads or writes the database. It takes the trip vectors a
  caller has already loaded, groups them by stop order, and answers the four
  questions the review asks before an editor confirms anything: which direction
  a group's stop order is exported as, which existing pattern a group should
  join, what a new timing would be called, and whether the review the editor is
  looking at is still current.

  The rules are the spec's rules 4 to 7: a direction is suggested only when the
  route's own patterns decide it, joining an existing pattern is ordered
  deterministically, editor-created timings are named after their services, and
  the review carries a fingerprint of every trip's linkage so a concurrent
  change can be detected.
  """

  @fingerprint_fields [
    :pattern_derivation_state,
    :route_pattern_id,
    :timed_pattern_id,
    :direction_id,
    :updated_at
  ]

  @type vector :: %{
          id: Ecto.UUID.t(),
          trip_id: String.t(),
          direction_id: 0 | 1 | nil,
          route_pattern_id: String.t() | nil,
          service_id: String.t(),
          shape_id: String.t() | nil,
          stop_ids: [String.t()]
        }

  @type pattern_ref :: %{
          id: Ecto.UUID.t(),
          route_pattern_id: String.t(),
          direction_id: 0 | 1,
          stop_ids: [String.t()],
          derivation_key: String.t() | nil,
          linked_trip_count: non_neg_integer(),
          label_pattern_id: Ecto.UUID.t() | nil
        }

  @type group :: %{
          key: String.t(),
          stop_ids: [String.t()],
          supplied_route_pattern_id: String.t() | nil,
          direction_id: 0 | 1 | nil,
          trip_ids: [Ecto.UUID.t()],
          services: %{String.t() => pos_integer()},
          shapes: %{String.t() => pos_integer()}
        }

  @type suggestion ::
          {:suggested, 0 | 1, {:same_endpoints | :within, Ecto.UUID.t()}}
          | {:paired, String.t()}
          | :none

  @doc """
  Groups left-out trip vectors by supplied `route_pattern_id` and ordered stop
  IDs.

  Each group's `key` is the supplied pattern ID (or `""`) joined to the SHA-256
  of its stop IDs, so the same stop order offered to two editors is the same
  selection. Groups are returned in key order and each group's trip IDs are
  sorted, so a preview and a later apply see one stable collection.
  """
  @spec group([vector()]) :: [group()]
  def group(vectors) do
    vectors
    |> Enum.group_by(fn vector -> {vector.route_pattern_id || "", vector.stop_ids} end)
    |> Enum.map(fn {{supplied, stop_ids}, rows} ->
      %{
        key: group_key(supplied, stop_ids),
        stop_ids: stop_ids,
        supplied_route_pattern_id: nil_if_blank(supplied),
        direction_id: shared_direction(rows),
        trip_ids: rows |> Enum.map(& &1.id) |> Enum.sort(),
        services: counts(rows, :service_id),
        shapes: counts(rows, :shape_id)
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Suggests the exported direction of one group, or `:none` when the route's own
  patterns do not decide it.

  A suggestion is made only when the group's stop order starts and ends at the
  same stops, in the same order, as a pattern (`{:same_endpoints, pattern}`) or
  runs within one pattern's stop order (`{:within, pattern}`). A group that
  shares just one terminal with a pattern matches neither rule, so it gets no
  suggestion and the editor is asked instead.

  A label child is answered by its owner: a labelled pattern and its owner share
  organisation, version, route and direction, so the answer is the owner's, and
  the owner is preferred when both are offered.

  Groups whose first and last stops are each other's are returned as
  `{:paired, pair_key}` with one shared `pair_key`, so "Which way is Direction
  0?" is asked once for the pair. Pairing is the last resort: a group the
  patterns already answer is never paired.
  """
  @spec suggest_direction(group(), [group()], [pattern_ref()]) :: suggestion()
  def suggest_direction(%{stop_ids: stop_ids} = group, groups, pattern_refs) do
    case pattern_suggestion(stop_ids, pattern_refs) do
      nil -> paired(group, groups)
      suggestion -> suggestion
    end
  end

  @doc """
  Orders the existing patterns a group with `direction_id` could join.

  A candidate is a pattern on the same route with the same direction and the
  same ordered stop IDs. Rule 5 preference decides the order: a pattern carrying
  a `derivation_key` first (so a hand-made copy is offered, never the target),
  then more linked trips, then the lowest `route_pattern_id`.
  """
  @spec candidates(group(), 0 | 1, [pattern_ref()]) :: [pattern_ref()]
  def candidates(%{stop_ids: stop_ids}, direction_id, pattern_refs) do
    pattern_refs
    |> Enum.filter(&(&1.direction_id == direction_id and &1.stop_ids == stop_ids))
    |> order_refs()
  end

  @doc """
  Names a timing that grouping or linking would create.

  One service is named after it, two are joined with "and". Any other number
  falls back to the caller's `RoutePatterns.next_timing_name/1`, so naming never
  invents a name the route does not already own. A name already taken on the
  pattern gets " 2", " 3" and so on, compared case-insensitively like
  `next_timing_name/1`.

  The caller's order is the display order, so it passes a deterministically
  ordered list of service names.
  """
  @spec timing_name([String.t()], MapSet.t(String.t())) :: String.t() | :fallback
  def timing_name(names, taken) do
    case names do
      [name] -> available_name(name, taken)
      [first, second] -> available_name("#{first} and #{second}", taken)
      _ -> :fallback
    end
  end

  @doc """
  Fingerprints the linkage of the trips a review was built from.

  Each row contributes its `id` plus its `pattern_derivation_state`,
  `route_pattern_id`, `timed_pattern_id`, `direction_id` and `updated_at`, sorted
  by `id`, so the value does not depend on the order the rows arrived in. An
  apply that changes any of these produces a different fingerprint, which is how
  a second editor's apply is turned away as stale.
  """
  @spec fingerprint([map()]) :: String.t()
  def fingerprint(rows) do
    rows
    |> Enum.sort_by(& &1.id)
    |> Enum.map_join(<<0>>, fn row ->
      fields = [row.id | Enum.map(@fingerprint_fields, &Map.get(row, &1))]
      Enum.map_join(fields, <<0>>, &inspect/1)
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # A taken name gets " 2", " 3" and so on. Comparison is case-insensitive, the
  # way `next_timing_name/1` avoids offering a name the pattern already has.
  defp available_name(name, taken) do
    taken = MapSet.new(taken, &String.downcase/1)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = if index == 1, do: name, else: "#{name} #{index}"
      unless MapSet.member?(taken, String.downcase(candidate)), do: candidate
    end)
  end

  # A group is answered by the patterns the route already exports. Two stops is
  # the shortest order with two ends: a one-stop group shares a single terminal
  # with many patterns, which rule 4 must leave to the editor.
  defp pattern_suggestion(stop_ids, _pattern_refs) when length(stop_ids) < 2, do: nil

  defp pattern_suggestion(stop_ids, pattern_refs) do
    case order_refs(answering_patterns(pattern_refs, stop_ids)) do
      [] ->
        nil

      [pattern | _] ->
        reason = if same_endpoints?(pattern, stop_ids), do: :same_endpoints, else: :within
        {:suggested, pattern.direction_id, {reason, pattern.id}}
    end
  end

  # A labelled child is answered by its owner, so one pattern never produces two
  # answers. The child stands in only when its owner is not on offer.
  defp answering_patterns(pattern_refs, stop_ids) do
    owners =
      pattern_refs
      |> Enum.filter(&(not is_nil(&1.label_pattern_id)))
      |> MapSet.new(& &1.label_pattern_id)

    Enum.filter(pattern_refs, fn pattern ->
      ownerless? = is_nil(pattern.label_pattern_id) or not MapSet.member?(owners, pattern.id)
      ownerless? and (same_endpoints?(pattern, stop_ids) or within?(pattern, stop_ids))
    end)
  end

  defp same_endpoints?(%{stop_ids: pattern_stops}, stop_ids) do
    length(pattern_stops) == length(stop_ids) and
      List.first(pattern_stops) == List.first(stop_ids) and
      List.last(pattern_stops) == List.last(stop_ids)
  end

  defp within?(%{stop_ids: pattern_stops}, stop_ids), do: in_order?(stop_ids, pattern_stops)

  defp paired(%{key: key, stop_ids: stop_ids}, groups) do
    if length(stop_ids) < 2 do
      :none
    else
      partner =
        groups
        |> Enum.reject(&(&1.key == key))
        |> Enum.filter(&reverses?(stop_ids, &1.stop_ids))
        |> Enum.min_by(& &1.key, fn -> nil end)

      if partner, do: {:paired, pair_key(key, partner.key)}, else: :none
    end
  end

  # A pair shares one question, so both groups report the same key. It is built
  # from the two group keys in sorted order, so the pair does not depend on which
  # group was asked first.
  defp pair_key(left, right), do: Enum.sort([left, right]) |> Enum.join("|")

  # A group pairs with the group whose order runs the other way: the partner's
  # first stop is this group's last, and the partner's last is this group's first.
  # Length is part of the test, so a full order never pairs with a short turn.
  defp reverses?([first | _] = stops, [partner_first | _] = partner) do
    length(stops) == length(partner) and partner_first == List.last(stops) and
      List.last(partner) == first
  end

  # Rule 5 preference, also the tie-break between two patterns that would answer
  # the same group, so suggestions are as deterministic as candidate order.
  defp order_refs(pattern_refs) do
    Enum.sort_by(pattern_refs, fn pattern ->
      {derived_rank(pattern), -pattern.linked_trip_count, pattern.route_pattern_id, pattern.id}
    end)
  end

  defp derived_rank(%{derivation_key: nil}), do: 1
  defp derived_rank(%{derivation_key: _key}), do: 0

  defp in_order?([], _pattern_stops), do: true

  defp in_order?([stop | stops], pattern_stops),
    do: Enum.member?(pattern_stops, stop) and in_order?(stops, pattern_stops)

  defp group_key(supplied, stop_ids) do
    sequence_hash =
      :crypto.hash(:sha256, Enum.join(stop_ids, <<0>>)) |> Base.encode16(case: :lower)

    supplied <> ":" <> sequence_hash
  end

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(supplied), do: supplied

  defp shared_direction(rows) do
    case rows |> Enum.map(& &1.direction_id) |> Enum.uniq() do
      [direction] when not is_nil(direction) -> direction
      _ -> nil
    end
  end

  defp counts(rows, field) do
    rows
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end
end
