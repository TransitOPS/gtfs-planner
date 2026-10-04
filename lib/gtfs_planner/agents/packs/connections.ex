defmodule GtfsPlanner.Agents.Packs.Connections do
  @moduledoc """
  The Schedule connections helper pack: the read-only comparison of the exact
  connection margins the Schedules page approved.

  The pack is registered here because `RouteSchedulesLive` offers it beside
  `service_queries` and the panel refuses to mount a selector naming a pack the
  application does not ship. It reads nothing but the immutable snapshot the
  Schedules page admitted through `GtfsPlanner.Agents.Scope.with_source_snapshot/2`,
  so a conversation without an approved `connections` source is refused before any
  request, tool read, delivered result or prepared lookup (INV-1, INV-2).

  `compare_connection_margins` takes no arguments at all. The date, the pairs,
  their endpoints, each minimum and every supplied candidate clock are the page's,
  so a model can neither move the comparison to another date nor choose which pair
  is measured, restate a minimum or invent a clock (FH-9). The only answer is
  `GtfsPlanner.Gtfs.ConnectionComparison.compare/4` over exactly those inputs, so
  every number, category and provenance below is arithmetic this server performed
  on one read-only snapshot; model prose only explains it (CR-4).

  There is no preparation here and none is reachable: this pack returns
  `{:ok, result, evidence}` or an error, never a command, and it names no
  schedule or transfer writer.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ConnectionComparison

  @source_kind "connections"
  @schema_version 1
  @source_ref "gtfs_connections"

  # An engineering ceiling, not a product limit: the panel's one result and its
  # evidence travel together inside the dispatch result bound, so a 500-pair
  # approval is answered with a bounded witness list whose totals still describe
  # every approved pair rather than refused whole or truncated silently.
  @max_witness_rows 25

  # The page card is bounded separately from the model's witness: an approval
  # may hold more pairs than a card can usefully list, and the counts above
  # always cover every pair that was admitted.
  @max_card_rows 10

  @skill_path Path.expand("../../../../priv/agents/packs/connections/SKILL.md", __DIR__)
  @external_resource @skill_path

  @skill @skill_path
         |> File.read!()
         |> String.split("\n")
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.join("\n")
         |> String.trim()

  @impl true
  def id, do: @source_kind

  @impl true
  def title, do: "Connection helper"

  @impl true
  def intro do
    "I can compare the exact connection times you approved on this page against the minimum the service version states. I can't change trips, calendars, stops or transfers."
  end

  @impl true
  def examples do
    [
      "Can riders make the connection I approved?",
      "How much slack does the approved connection leave?"
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "compare_connection_margins",
        description:
          "Compare the approved connections on this page against the minimum the service version states, and report the supplied candidate times beside the current ones. Every date, pair, stop, trip, minimum and candidate clock is the one the person approved, so this tool takes no arguments: call it whenever the person asks whether a connection can be made, how much time is available, or how a candidate compares. Each pair comes back classified as comparable, unresolved, not applicable or prohibited, with the reason when it has no exact margin.",
        activity: "Compared the approved connections",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        }
      }
    ]
  end

  # The admission rule the whole helper rests on: the page's own approved
  # snapshot, every endpoint of every approved pair resolvable inside this
  # organization and version, and the route this conversation is bound to among
  # the routes the person approved. A missing, deleted, foreign or out-of-approval
  # reference is refused here — before the provider request — with the same
  # result a malformed one gives, so no other tenant's or version's metadata can
  # reach the model.
  @impl true
  def authorize_context(%Scope{} = scope) do
    with {:route, route_id} <- Scope.identity(scope),
         {:ok, request} <- request(scope),
         :ok <- endpoints_authorized(request, scope),
         {:ok, anchor} <-
           Gtfs.get_route_in_version(scope.organization_id, scope.gtfs_version_id, route_id),
         true <- approved?(request.approved_route_ids, anchor.route_id) do
      :ok
    else
      _other -> {:error, :unavailable}
    end
  end

  @impl true
  def call("compare_connection_margins", _args, %Scope{} = scope) do
    case request(scope) do
      {:ok, request} ->
        compare(request, scope)

      # `authorize_context/1` has already refused such a conversation, so this is
      # a defensive message rather than a path the turn can reach.
      {:error, :unavailable} ->
        {:error,
         "These approved connections cannot be read as approved. Ask the person to approve them again."}
    end
  end

  def call(_name, _args, %Scope{}), do: {:error, "This helper has no such tool."}

  # -- the comparison --------------------------------------------------------

  defp compare(request, scope) do
    comparison_scope = %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id
    }

    case ConnectionComparison.compare(
           comparison_scope,
           request.pairs,
           request.service_date,
           request.candidate
         ) do
      {:ok, report} ->
        {:ok, result(report), evidence(report, request, scope)}

      {:error, :stale} ->
        {:error,
         "The connections changed since the person approved them. Ask them to approve the connections again before comparing them."}

      {:error, reason} ->
        {:error, comparison_message(reason)}
    end
  end

  defp comparison_message(:invalid_input),
    do:
      "These approved connections cannot be read as approved. Ask the person to approve them again."

  defp comparison_message(:not_found),
    do: "One of the approved routes or trips is no longer in this service version."

  defp comparison_message(:too_many),
    do: "These approved connections are larger than one comparison can carry."

  defp comparison_message(_reason),
    do: "These connections could not be compared right now. Try again."

  # -- the admitted request --------------------------------------------------

  # Every host JSON key is mapped to its atom explicitly. `String.to_atom/1` on
  # snapshot content would let an admitted label allocate atoms, so the mapping
  # below is the whole decoder and it only accepts the documented shapes.
  defp request(%Scope{} = scope) do
    with %{kind: @source_kind, payload: payload} <- Scope.source_snapshot(scope),
         %{"schema_version" => @schema_version} <- payload,
         {:ok, service_date} <- service_date(payload["service_date"]),
         {:ok, approved_route_ids} <- route_ids(payload["approved_route_ids"]),
         {:ok, base_digest} <- digest(payload["base_digest"]),
         {:ok, pairs} <- pairs(payload["pairs"]),
         {:ok, candidate} <- candidate(payload["candidates"], base_digest) do
      {:ok,
       %{
         service_date: service_date,
         approved_route_ids: approved_route_ids,
         base_digest: base_digest,
         pairs: pairs,
         candidate: candidate
       }}
    else
      _other -> {:error, :unavailable}
    end
  end

  defp service_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp service_date(_value), do: :error

  defp route_ids(value) when is_list(value) do
    if value != [] and Enum.all?(value, &(is_binary(&1) and &1 != "")) do
      {:ok, value}
    else
      :error
    end
  end

  defp route_ids(_value), do: :error

  defp digest(value) when is_binary(value) and value != "", do: {:ok, value}
  defp digest(_value), do: :error

  defp pairs(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn pair, {:ok, acc} ->
      case pair(pair) do
        {:ok, decoded} -> {:cont, {:ok, acc ++ [decoded]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp pairs(_value), do: :error

  defp pair(%{"id" => id, "from" => from, "to" => to, "minimum" => minimum})
       when is_binary(id) and id != "" do
    with {:ok, from} <- endpoint(from),
         {:ok, to} <- endpoint(to),
         {:ok, minimum} <- minimum(minimum) do
      {:ok, %{id: id, from: from, to: to, minimum: minimum}}
    else
      _other -> :error
    end
  end

  defp pair(_pair), do: :error

  defp endpoint(%{
         "route_id" => route_id,
         "trip_id" => trip_id,
         "stop_id" => stop_id,
         "stop_sequence" => stop_sequence,
         "service_date_offset" => offset
       })
       when is_binary(route_id) and is_binary(trip_id) and is_binary(stop_id) and
              is_integer(stop_sequence) and stop_sequence >= 0 and is_integer(offset) and
              offset >= 0 do
    {:ok,
     %{
       route_id: route_id,
       trip_id: trip_id,
       stop_id: stop_id,
       stop_sequence: stop_sequence,
       service_date_offset: offset
     }}
  end

  defp endpoint(_endpoint), do: :error

  defp minimum(%{"origin" => "stored"}), do: {:ok, %{origin: :stored}}

  defp minimum(%{"origin" => "supplied", "seconds" => seconds, "approval" => approval})
       when is_integer(seconds) and seconds >= 0 and is_binary(approval) and approval != "" do
    {:ok, %{origin: :supplied, seconds: seconds, approval: approval}}
  end

  defp minimum(_minimum), do: :error

  # A supplied candidate is external exact evidence the person approved, and its
  # binding is the `base_digest` the page recorded with the approval — not a
  # label the model chose. Two candidate entries approved under two different
  # labels are one comparison that cannot be bound to either, so it is refused
  # rather than reported under whichever label sorted first.
  defp candidate(candidates, base_digest) when is_list(candidates) do
    with {:ok, times, labels} <- candidate_clocks(candidates, [], []),
         {:ok, label} <- candidate_label(labels) do
      if times == [] do
        {:ok, nil}
      else
        {:ok,
         %{
           origin: :supplied,
           times: Map.new(times),
           approval: %{base_digest: base_digest, label: label}
         }}
      end
    end
  end

  defp candidate(_candidates, _base_digest), do: :error

  defp candidate_label([]), do: {:ok, nil}

  defp candidate_label(labels) do
    case Enum.uniq(labels) do
      [label] -> {:ok, label}
      _several -> :error
    end
  end

  defp candidate_clocks([], times, labels), do: {:ok, times, labels}

  defp candidate_clocks([entry | rest], times, labels) do
    case candidate_clock(entry) do
      {:ok, nil} ->
        candidate_clocks(rest, times, labels)

      {:ok, {id, clocks, label}} ->
        candidate_clocks(rest, times ++ [{id, clocks}], labels ++ [label])

      :error ->
        :error
    end
  end

  defp candidate_clock(
         %{
           "pair_id" => id,
           "arrival" => arrival,
           "departure" => departure,
           "approval" => label
         } = _entry
       )
       when is_binary(id) and id != "" and is_binary(label) and label != "" and
              (is_nil(arrival) or is_binary(arrival)) and
              (is_nil(departure) or is_binary(departure)) do
    supplied_clock(id, label, arrival, departure)
  end

  defp candidate_clock(_entry), do: :error

  defp supplied_clock(_id, _label, nil, nil),
    # A pair with no supplied clock is missing candidate evidence, not a zero.
    do: {:ok, nil}

  defp supplied_clock(id, label, arrival, departure),
    do: {:ok, {id, %{arrival: arrival, departure: departure}, label}}

  # -- the read boundary -----------------------------------------------------

  # Each approved endpoint is resolved inside this organization and version and
  # must belong to one of the routes the person approved. The page's approved set
  # names the feed's own route ids, so the endpoint's route row is resolved to
  # its `route_id` before the membership test rather than compared as an id of
  # another kind.
  defp endpoints_authorized(request, scope) do
    request.pairs
    |> Enum.flat_map(fn pair -> [pair.from, pair.to] end)
    |> Enum.reduce_while(:ok, fn endpoint, :ok ->
      case endpoint_authorized(endpoint, request.approved_route_ids, scope) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp endpoint_authorized(endpoint, approved_route_ids, scope) do
    with {:ok, route} <-
           Gtfs.get_route_in_version(
             scope.organization_id,
             scope.gtfs_version_id,
             endpoint.route_id
           ),
         true <- approved?(approved_route_ids, route.route_id),
         {:ok, _trip} <-
           Gtfs.get_trip_in_version(
             scope.organization_id,
             scope.gtfs_version_id,
             endpoint.trip_id
           ) do
      :ok
    else
      _other -> :error
    end
  end

  defp approved?(approved_route_ids, route_id),
    do: Enum.any?(approved_route_ids, &(&1 == route_id))

  # -- the model's answer ----------------------------------------------------

  defp result(report) do
    rows = Enum.take(report.rows, @max_witness_rows)

    %{
      "service_date" => Date.to_iso8601(report.service_date),
      "approved_route_ids" => report.approved_route_ids,
      "candidate" => candidate_result(report.candidate),
      "pairs" => Enum.map(rows, &pair_result/1),
      "pairs_shown" => length(rows),
      "pairs_omitted" => report.totals.requested - length(rows),
      "totals" => named(report.totals),
      "completeness" => named(report.completeness),
      "snapshot_digest" => report.base_digest,
      "report_digest" => report.digest
    }
  end

  defp candidate_result(nil), do: nil

  defp candidate_result(candidate) do
    %{
      "origin" => to_string(candidate.origin),
      "evidence" => to_string(candidate.evidence),
      "approval" => candidate.approval.label,
      "approved_against" => candidate.approval.base_digest,
      "supplied_pairs" => candidate.supplied_pairs
    }
  end

  defp pair_result(row) do
    %{
      "id" => row.id,
      "status" => to_string(row.status),
      "reason" => row.reason && to_string(row.reason),
      "current" => side_result(row.current),
      "candidate" => side_result(row.candidate),
      "delta_seconds" => row.delta_seconds,
      "minimum" => minimum_result(row.minimum)
    }
  end

  defp side_result(nil), do: nil

  defp side_result(side) do
    %{
      "arrival" => side.arrival_time,
      "departure" => side.departure_time,
      "available_seconds" => side.available_seconds,
      "margin_seconds" => side.margin_seconds,
      "margin_status" => to_string(side.margin_status)
    }
  end

  # The same row the tool result carries, keyed for the page card: the values are
  # identical, so a number on screen is never a re-derivation.
  defp card_row(row) do
    result = pair_result(row)

    %{
      id: result["id"],
      status: result["status"],
      reason: result["reason"],
      current: result["current"],
      candidate: result["candidate"],
      delta_seconds: result["delta_seconds"],
      minimum: result["minimum"]
    }
  end

  defp minimum_result(minimum) do
    %{
      "origin" => to_string(minimum.origin),
      "seconds" => minimum.seconds,
      "status" => to_string(minimum.status),
      "provenance" => provenance_result(minimum.provenance),
      "supplied" => supplied_result(minimum.supplied)
    }
  end

  defp provenance_result(provenance) do
    taken =
      Map.take(provenance, [
        :kind,
        :rank,
        :rule_ids,
        :reason,
        :transfer_id,
        :transfer_type,
        :min_transfer_time
      ])

    result = Map.new(taken, fn {key, value} -> {to_string(key), atom_text(value)} end)

    case Map.get(provenance, :revision) do
      nil -> result
      revision -> Map.put(result, "revision", DateTime.to_iso8601(revision))
    end
  end

  defp supplied_result(nil), do: nil

  defp supplied_result(supplied),
    do: %{"seconds" => supplied.seconds, "approval" => supplied.approval}

  defp named(map), do: Map.new(map, fn {key, value} -> {to_string(key), atom_text(value)} end)

  # A boolean stays a boolean: `true` and `false` are the report's completeness
  # answer, while `nil`, `:comparable` and the like are atoms to name.
  defp atom_text(value) when is_boolean(value), do: value
  defp atom_text(value) when is_atom(value) and not is_nil(value), do: to_string(value)
  defp atom_text(value), do: value

  # -- the panel's evidence --------------------------------------------------

  defp evidence(report, request, scope) do
    %{
      kind: "connection_comparison",
      title: "Connections for #{Date.to_iso8601(report.service_date)}",
      total: report.totals.requested,
      total_label: "approved connection pairs",
      completeness: if(report.completeness.complete?, do: :complete, else: :incomplete),
      completeness_reason: completeness_reason(report),
      facts: facts(report, request, scope),
      source_ref: @source_ref,
      digest: report.digest,
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      # The page renders these rows itself, so it never reads a number out of the
      # model's reply. They are the same rows the tool result carries.
      rows: Enum.map(Enum.take(report.rows, @max_card_rows), &card_row/1),
      exclusions: card_exclusions(report) ++ exclusions(report),
      resources:
        Enum.map(Enum.take(report.rows, @max_witness_rows), fn row ->
          %{
            kind: "connection_pair",
            id: row.id,
            label: "#{row.id}: #{row.status}" <> reason_suffix(row)
          }
        end)
    }
  end

  defp reason_suffix(%{reason: nil}), do: ""
  defp reason_suffix(%{reason: reason}), do: " (#{reason})"

  # Every category the person asked about is a number here, so an unresolved or
  # incomplete answer is never read as a comparable one.
  defp facts(report, request, scope) do
    supplied_pairs = if report.candidate, do: length(report.candidate.supplied_pairs), else: 0

    [
      %{label: "Service date", value: Date.to_iso8601(report.service_date)},
      %{label: "Comparable", value: count(report.totals.comparable)},
      %{label: "Unresolved", value: count(report.totals.unresolved)},
      %{label: "Not applicable", value: count(report.totals.not_applicable)},
      %{label: "Prohibited", value: count(report.totals.prohibited)},
      %{label: "Meets the stated minimum", value: count(report.totals.meets_stated_minimum)},
      %{label: "Below the stated minimum", value: count(report.totals.below_stated_minimum)},
      %{
        label: "Approved pairs",
        value: "#{report.totals.requested} classified of #{length(request.pairs)} admitted"
      },
      %{label: "Approved source digest", value: source_digest(scope)},
      %{label: "Compared snapshot digest", value: report.base_digest},
      %{label: "Supplied candidate pairs", value: count(supplied_pairs)}
    ]
  end

  defp count(value), do: Integer.to_string(value)

  defp identity_label(scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  defp completeness_reason(%{completeness: %{complete?: true}}), do: nil

  defp completeness_reason(report) do
    reasons =
      report.rows
      |> Enum.map(& &1.reason)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

    "Only #{report.totals.comparable} of #{report.totals.requested} approved pairs could be compared" <>
      if(reasons == [], do: ".", else: ": " <> Enum.join(reasons, ", ") <> ".")
  end

  # A pair counted but not shown on the page card is disclosed, never dropped
  # silently, so the totals on screen can be reconciled with the rows on screen.
  defp card_exclusions(%{totals: %{requested: requested}}) when requested > @max_card_rows do
    [
      "#{requested - @max_card_rows} further approved pairs are counted above but not listed here."
    ]
  end

  defp card_exclusions(_report), do: []

  defp exclusions(report) do
    shown =
      for row <- Enum.take(report.rows, @max_witness_rows),
          row.status != :comparable,
          do: "#{row.id}: #{row_reason(row)}"

    omitted = report.totals.requested - @max_witness_rows

    if omitted > 0 do
      shown ++
        [
          "#{omitted} further approved pairs are not listed here; the counts above cover all #{report.totals.requested}."
        ]
    else
      shown
    end
  end

  defp row_reason(%{reason: nil}), do: "no exact margin"
  defp row_reason(%{reason: reason}), do: to_string(reason)

  defp source_digest(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{digest: digest} -> digest
      nil -> "none"
    end
  end
end
