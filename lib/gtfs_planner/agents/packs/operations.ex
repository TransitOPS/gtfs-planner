defmodule GtfsPlanner.Agents.Packs.Operations do
  @moduledoc """
  The parts the Blocks and Runs helper packs share: reading the attached frozen
  day, the authorization fence over it, the issue pager and the evidence parts
  every tool reports.

  A pack names its own snapshot with a map of `:kind` (the admitted snapshot
  kind), `:section` (the payload's section), `:map_keys` (the payload sections
  that must be maps) and `:unavailable` (the refusal a missing or malformed
  copy reads as). Everything here is parameterised by that map, so the
  authorization check the two packs run is one function rather than two copies
  a fix could reach only one of.
  """

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Blocking.Queries, as: BlockingQueries
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.OperationsAssistance

  @collection "issues"

  # The bytes a filled page may differ from the empty one it is measured
  # against: the larger `total` and offsets, `page_limited?` and the "shown"
  # fact. The pager measures the rows and its own cursor itself.
  @envelope_slack 256

  @max_exclusions 20

  @binary_keys ["day_key", "day_ref", "source_digest"]

  @type snapshot :: %{
          kind: String.t(),
          section: String.t(),
          map_keys: [String.t()],
          unavailable: String.t()
        }

  # -- the attached copy ---------------------------------------------------

  @doc "The attached payload when it is this pack's own, well-formed copy."
  @spec attached_payload(Scope.t(), snapshot()) :: {:ok, map()} | {:error, String.t()}
  def attached_payload(%Scope{} = scope, %{kind: kind} = snapshot) do
    case Scope.source_snapshot(scope) do
      %{kind: ^kind, payload: payload} when is_map(payload) ->
        if well_formed?(payload, snapshot),
          do: {:ok, payload},
          else: {:error, snapshot.unavailable}

      _none ->
        {:error, snapshot.unavailable}
    end
  end

  defp well_formed?(payload, snapshot) do
    Map.get(payload, "section") == snapshot.section and
      Enum.all?(@binary_keys, &is_binary(Map.get(payload, &1))) and
      is_list(Map.get(payload, "issues")) and
      Enum.all?(snapshot.map_keys, &is_map(Map.get(payload, &1)))
  end

  @doc """
  Checks a tool's `day_ref` against the attached day.

  An absent `day_ref` resolves to the attached day's own ref. The ref is an
  opaque server-generated digest over the section and day key, so a model could
  not derive it from anything it can see and could not retype it reliably even
  if it were disclosed; requiring it made every read unreachable in production.
  Omitting it therefore names the same day, and a ref that IS supplied is still
  checked, so the model gains no path to a day this conversation did not attach.
  """
  @spec check_day_ref(term(), map()) :: :ok | {:error, String.t()}
  def check_day_ref(nil, _payload), do: :ok

  def check_day_ref(day_ref, payload) when is_binary(day_ref) do
    if day_ref == payload["day_ref"],
      do: :ok,
      else: {:error, "That day is not the day attached to this conversation."}
  end

  def check_day_ref(_day_ref, _payload),
    do: {:error, "day_ref must be the day reference this page attached."}

  @doc """
  Checks a tool's `plan_ref` against the attached proposal.

  An absent `plan_ref` names the proposal the attached snapshot carries, for the
  reason `check_day_ref/2` gives: the ref is an opaque server digest that no tool
  result or prompt hands the model before it reads the proposal, so requiring it
  made both proposal tools unreachable outside a test that scripts it in. A ref
  that IS supplied is still checked, so a replaced or foreign proposal is refused
  the same way.
  """
  @spec check_plan_ref(term(), map()) :: :ok | {:error, String.t()}
  def check_plan_ref(nil, _plan), do: :ok

  def check_plan_ref(plan_ref, plan) do
    if plan_ref == plan["plan_ref"] do
      :ok
    else
      {:error,
       "That proposal is not the one this page holds. It may have been replaced; ask the editor " <>
         "to start the suggestion again."}
    end
  end

  # -- authorization -------------------------------------------------------

  @doc """
  Returns `:ok` only for a scope whose attached snapshot is the pack's own.

  The version identity, the current day catalog and every technical trip
  identity the copy names are resolved with scoped queries; a malformed,
  foreign, stale or deleted scope is the single `{:error, :unavailable}`.
  """
  @spec authorize_context(Scope.t(), snapshot()) :: :ok | {:error, :unavailable}
  def authorize_context(%Scope{} = scope, snapshot) do
    with {:ok, payload} <- attached_payload(scope, snapshot),
         :ok <- resolve_version(scope),
         :ok <- resolve_day_catalog(scope, payload),
         :ok <- resolve_trip_identities(scope, payload) do
      :ok
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  defp resolve_version(%Scope{} = scope) do
    case Scope.identity(scope) do
      {:version, id} -> if id == scope.gtfs_version_id, do: :ok, else: {:error, :unavailable}
      _other -> {:error, :unavailable}
    end
  end

  # The frozen copy names a day type; the current catalog decides whether that
  # day type still exists in this organization and version. A copy whose day has
  # gone, and a version this organization does not publish, refuse alike.
  defp resolve_day_catalog(%Scope{} = scope, payload) do
    key = payload["day_key"]

    if Enum.any?(current_day_types(scope), &(&1.key == key)),
      do: :ok,
      else: {:error, :unavailable}
  end

  # The calendars are read directly rather than through
  # `Blocking.list_day_types/2`, which rolls back a transaction this read is not
  # inside. A foreign or unpublished version is `{:error, :not_found}` and reads
  # as an empty catalog; any other failure raises.
  defp current_day_types(%Scope{} = scope) do
    case Calendars.list_calendars(scope.organization_id, scope.gtfs_version_id) do
      {:ok, calendars} -> DayTypes.derive(calendars)
      {:error, :not_found} -> []
    end
  end

  # Every technical trip identity the copy names must still resolve in the
  # scoped version. A trip moved to another organization or version, or deleted
  # after the copy was published, means this snapshot no longer describes this
  # scope, and the refusal is the same one a foreign snapshot produces.
  defp resolve_trip_identities(%Scope{} = scope, payload) do
    ids = MapSet.new(payload["entities"]["trips"], & &1["trip_id"])

    resolved =
      BlockingQueries.trip_identities(
        scope.organization_id,
        scope.gtfs_version_id,
        {:trip_ids, MapSet.to_list(ids)}
      )

    if resolved |> MapSet.new(& &1.trip_id) |> MapSet.equal?(ids),
      do: :ok,
      else: {:error, :unavailable}
  end

  # -- issue pages ---------------------------------------------------------

  @doc """
  Reads the `filters` argument: absent is no filter, and the pager decides which
  codes and severities this snapshot can act on.
  """
  @spec read_filters(term()) :: {:ok, map()} | {:error, String.t()}
  def read_filters(nil), do: {:ok, %{}}
  def read_filters(filters) when is_map(filters), do: {:ok, filters}
  def read_filters(_filters), do: {:error, "filters must be an object."}

  @doc """
  Reads a tool cursor into the pager's own cursor.

  `applied` is the filter object the tool echoed (only what was applied) and
  `pager_filters` the pager's normalized form of the same narrowing. The first
  page has no cursor; a later one must agree with this snapshot, this collection
  and these filters. There is no store behind it, so a mismatched or malformed
  cursor is refused rather than followed.
  """
  @spec read_cursor(term(), map(), map(), map()) :: {:ok, map() | nil} | {:error, String.t()}
  def read_cursor(nil, _payload, _applied, _pager_filters), do: {:ok, nil}

  def read_cursor(cursor, payload, applied, pager_filters) when is_map(cursor) do
    digest = payload["source_digest"]

    with true <- Map.get(cursor, "digest") == digest,
         true <- Enum.sort(Map.keys(cursor)) == ["collection", "digest", "filters", "offset"],
         true <- Map.get(cursor, "collection") == @collection,
         true <- Map.get(cursor, "filters") == applied,
         offset when is_integer(offset) and offset >= 0 <- Map.get(cursor, "offset") do
      {:ok,
       %{
         "digest" => digest,
         "collection" => @collection,
         "filters" => pager_filters,
         "offset" => offset
       }}
    else
      _mismatch ->
        {:error,
         "That cursor belongs to a different day, filter set or position. Start the list again."}
    end
  end

  def read_cursor(_cursor, _payload, _applied, _pager_filters),
    do: {:error, "cursor must be the object a previous page returned."}

  @doc """
  The cursor a tool hands back: the pager's position with only the filters that
  were applied, so the next call stays inside the declared shape.
  """
  @spec tool_cursor(map() | nil, map()) :: map() | nil
  def tool_cursor(nil, _applied), do: nil

  def tool_cursor(%{"digest" => digest, "offset" => offset}, applied) do
    %{"digest" => digest, "collection" => @collection, "filters" => applied, "offset" => offset}
  end

  @doc """
  Serves one page of the issues collection and wraps it with `build`.

  `build` turns a pager page into the pack's `{result, evidence}`. The pager is
  given the bytes that envelope adds around an empty page, plus a small slack,
  so the result and evidence together stay inside the shared 32 KiB ceiling
  `Dispatch` enforces.
  """
  @spec issues_page(map(), map(), map() | nil, (map() -> {map(), map()})) ::
          {:ok, map(), map()} | {:error, String.t()}
  def issues_page(payload, pager_filters, cursor, build) do
    empty = %{rows: [], total: 0, next_cursor: nil, digest: payload["source_digest"]}
    reserve = encoded_bytes(build.(empty)) + @envelope_slack

    case OperationsAssistance.page(payload, @collection, pager_filters, cursor, reserve) do
      {:ok, page} ->
        {result, evidence} = build.(page)
        {:ok, result, evidence}

      {:error, :unavailable} ->
        {:error, "That page of this day's issues is not available. Start the list again."}
    end
  end

  defp encoded_bytes({result, evidence}),
    do: byte_size(Jason.encode!(result)) + byte_size(Jason.encode!(evidence))

  @doc """
  The day's scope as a page reports it: the mode and how many refs of each kind
  it holds. The ref lists themselves grow with the day and would crowd the rows
  out of the page's byte budget, so a page never echoes them.
  """
  @spec scope_summary(map()) :: map()
  def scope_summary(scope) when is_map(scope) do
    Map.new(scope, fn
      {key, refs} when is_list(refs) ->
        {String.replace_suffix(key, "_refs", "_count"), length(refs)}

      pair ->
        pair
    end)
  end

  # -- evidence parts ------------------------------------------------------

  @doc "Evidence completeness: only a whole-day copy is complete."
  @spec completeness(map()) :: :complete | :incomplete
  def completeness(%{"completeness" => "complete"}), do: :complete
  def completeness(_payload), do: :incomplete

  @doc "Why a copy is incomplete; `scoped_reason` is the pack's own wording."
  @spec completeness_reason(map(), String.t()) :: String.t() | nil
  def completeness_reason(%{"completeness" => "complete"}, _scoped_reason), do: nil
  def completeness_reason(%{"completeness" => "scoped"}, scoped_reason), do: scoped_reason

  def completeness_reason(_payload, _scoped_reason),
    do: "This day's copy is not a whole-day read."

  @doc """
  The scope the read ran under, so the panel can drop a card answering for a
  day it no longer holds. These are the authorized scope's own values.
  """
  @spec scope_evidence(Scope.t()) :: map()
  def scope_evidence(%Scope{} = scope) do
    identity =
      case Scope.identity(scope) do
        {kind, id} -> "#{kind}:#{id}"
        nil -> nil
      end

    %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      identity: identity
    }
  end

  @doc """
  The copy's own exclusions - unplottable and frequency-based trips, and rows an
  explicit subset left out - bounded so the card cannot push the answer past the
  result ceiling.
  """
  @spec exclusions(map()) :: [String.t()]
  def exclusions(payload) do
    (payload["exclusions"] || [])
    |> Enum.take(@max_exclusions)
    |> Enum.map(&exclusion_label/1)
    |> Enum.reject(&is_nil/1)
  end

  defp exclusion_label(%{"kind" => "frequency_trip", "trip_ref" => ref}),
    do: "frequency-based trip #{ref}"

  defp exclusion_label(%{"kind" => "unplottable", "trip_ref" => ref}),
    do: "unplottable trip #{ref}"

  defp exclusion_label(%{"kind" => "outside_scope", "block_ref" => ref}),
    do: "block #{ref} outside the selected scope"

  defp exclusion_label(%{"kind" => "outside_scope", "trip_ref" => ref}),
    do: "trip #{ref} outside the selected scope"

  defp exclusion_label(_exclusion), do: nil
end
