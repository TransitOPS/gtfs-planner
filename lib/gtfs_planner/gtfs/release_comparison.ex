defmodule GtfsPlanner.Gtfs.ReleaseComparison do
  @moduledoc """
  Scoped choice of two retained export artifacts and the inclusive date window
  they are compared over.

  Choosing never reads or claims anything. `list_choices/2` and
  `resolve_selection/2` copy durable run metadata the server already holds:
  the digest, size and expiry recorded by the verified native export, never a
  client-supplied digest, path or filename. Claiming, verifying and reading the
  bytes belong to the explicit native comparison start.

  Every refusal is the same opaque answer. A missing, foreign, deleted,
  non-editor, non-ready or expired run, an expired window shape and a version
  the organization cannot resolve all return `{:error, :unavailable}`, so no
  foreign metadata, membership state or artifact existence leaks. A run that
  exists and resolves but is not a full-main export returns the distinct
  `{:error, :unsupported_profile}` because the editor must be told that this
  profile cannot be compared, not that it does not exist.
  """

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison.Runner
  alias GtfsPlanner.Versions

  @default_limit 25
  @max_limit 100

  # Both bounds are explicit: an absent, unparseable, reversed or 63-day window
  # is refused instead of being silently narrowed or defaulted.
  @max_window_days 62

  @typedoc """
  Durable identity of one compared artifact, copied from the run the native
  export published. `size` is the verified byte size, `expires_at` the retention
  deadline the comparison itself must respect, and the estimate fields describe
  how that artifact's missing times were filled before export.
  """
  @type artifact_identity :: %{
          required(:run_id) => Ecto.UUID.t(),
          required(:version_id) => Ecto.UUID.t(),
          required(:sha256) => String.t(),
          required(:size) => non_neg_integer(),
          required(:export_type) => atom(),
          required(:expires_at) => DateTime.t(),
          required(:estimate_missing_times) => boolean(),
          required(:estimate_method) => atom() | nil
        }

  @typedoc """
  One started comparison, its owner and the reference it answers under.

  `owner_pid` is the only process that receives the result and the only process
  whose cancellation is honoured; `request_ref` tags that one request so a stale
  answer or a stale cancellation from a replaced request can never be mistaken
  for the current one.
  """
  @type start_args :: {Scope.t(), map(), pid(), term()}

  @typedoc "Two retained artifacts plus the one inclusive service-date window they share."
  @type selection :: %{
          required(:organization_id) => Ecto.UUID.t(),
          required(:host_version_id) => Ecto.UUID.t(),
          required(:left) => artifact_identity(),
          required(:right) => artifact_identity(),
          required(:from) => Date.t(),
          required(:to) => Date.t()
        }

  @doc """
  Lists the organization's retained, ready full-main export runs newest first.

  `:limit` defaults to #{@default_limit} and is capped at #{@max_limit}. `:cursor` is
  the opaque `next_cursor` a previous page returned; a cursor that does not
  decode into a keyset position is `{:error, :unavailable}` rather than a
  silent restart of the list. A decoded position is applied inside the same
  organization scope, so a cursor for someone else's run can only ever return
  this organization's own rows.
  """
  @spec list_choices(Scope.t(), keyword()) ::
          {:ok, %{rows: [map()], next_cursor: String.t() | nil}} | {:error, :unavailable}
  def list_choices(%Scope{} = scope, opts \\ []) do
    with :ok <- authorized(scope),
         {:ok, limit} <- page_limit(opts),
         {:ok, position} <- decode_cursor(Keyword.get(opts, :cursor)) do
      page = ExportRuns.list_comparable(scope.organization_id, after: position, limit: limit + 1)
      {rows, rest} = Enum.split(page, limit)

      {:ok,
       %{
         rows: Enum.map(rows, &choice_row/1),
         # A cursor is only true when a further page exists: the extra fetched
         # row is that proof, so a caller never pages into an empty list.
         next_cursor: if(rest == [], do: nil, else: next_cursor(List.last(rows)))
       }}
    end
  end

  @doc """
  Resolves one explicit comparison selection, or refuses it.

  `params` carries `"left_run_id"`/`"right_run_id"`, the optional matching
  `"left_version_id"`/`"right_version_id"` identity, and the ISO 8601 `"from"`
  and `"to"` dates. A submitted version identity is verified against the
  organization before the run is read and must name the run's own version; when
  it is absent the identity is resolved from the run itself, so a caller cannot
  point a known run at someone else's version.

  Resolution returns only server-held metadata: it takes no claim, reads no
  file, and creates no receipt.

  Every refusal is a `{:error, reason}` tuple. A malformed UUID or date answers
  `:error` from the cast helpers, so the `with` below normalizes anything that
  is not a match into the same opaque `{:error, :unavailable}` rather than
  letting a bare atom escape the function's declared contract.
  """
  @spec resolve_selection(Scope.t(), map()) ::
          {:ok, selection()}
          | {:error, :unavailable | :invalid_window | :unsupported_profile}
  def resolve_selection(%Scope{} = scope, params) when is_map(params) do
    with :ok <- authorized(scope),
         {:ok, from_date, to_date} <- window(params),
         {:ok, left} <- artifact(scope, params, "left"),
         {:ok, right} <- artifact(scope, params, "right") do
      {:ok,
       %{
         organization_id: scope.organization_id,
         host_version_id: scope.gtfs_version_id,
         left: artifact_identity(left),
         right: artifact_identity(right),
         from: from_date,
         to: to_date
       }}
    else
      {:error, reason} when reason in [:unavailable, :invalid_window, :unsupported_profile] ->
        {:error, reason}

      # A cast helper answering the bare atom `:error` is still just a
      # malformed selection, and says no more than any other refusal.
      _malformed ->
        {:error, :unavailable}
    end
  end

  def resolve_selection(_scope, _params), do: {:error, :unavailable}

  @doc """
  Starts one native comparison and returns its coordinator pid.

  This is the only entrypoint that reads or claims anything. `params` is the same
  selection `resolve_selection/2` accepts; the coordinator resolves it itself,
  re-authorizes the scope inside the claim transaction and claims each distinct
  retained artifact once, in sorted run-id order, so comparing an artifact with
  itself is one receipt and one read.

  `owner_pid` receives exactly one tagged terminal message,
  `{:release_comparison, request_ref, {:ok, result}}` or
  `{:release_comparison, request_ref, {:error, reason}}`, where `reason` is one of
  `unavailable`, `invalid_window`, `unsupported_profile`, `unsupported_size`,
  `malformed_csv`, `invalid_archive`, `cancelled`, `timeout` or `worker_exit`. A
  successful result carries the selection's fingerprint, window, both artifact
  identities and the comparison result itself.

  `{:error, :unavailable}` means no coordinator started at all. Every other
  refusal arrives as the tagged message.

  Starting a comparison takes the existing download claim, so the durable
  download receipt increments and a corrupt artifact is closed and removed by
  `GtfsPlanner.Gtfs.ExportRuns` exactly as an ordinary download would. Retention
  and quotas are unchanged.
  """
  @spec start(Scope.t(), map(), pid(), term()) :: {:ok, pid()} | {:error, :unavailable}
  defdelegate start(scope, params, owner_pid, request_ref), to: Runner

  @doc """
  Cancels the comparison `pid` is running for `request_ref`.

  Only a message from the owning pid carrying the matching request reference is
  acted on, so a foreign or stale cancellation changes nothing. Cancelling stops
  the compute child and releases every claim the coordinator took; it never
  touches export cancellation, retry or any durable export run.
  """
  @spec cancel(pid(), term()) :: :ok
  defdelegate cancel(pid, request_ref), to: Runner

  # Membership and the host version identity first: both are checked before any
  # prepared lookup, and their two failure reasons collapse into one answer.
  defp authorized(%Scope{} = scope) do
    case Scope.authorized_context(scope) do
      :ok -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp artifact(scope, params, side) do
    with {:ok, run_id} <- cast_uuid(Map.get(params, side <> "_run_id")),
         {:ok, version_id} <- cast_optional_uuid(Map.get(params, side <> "_version_id")),
         :ok <- version_in_scope(scope, version_id) do
      case ExportRuns.get_comparable(scope.organization_id, version_id, run_id) do
        {:ok, run} -> {:ok, run}
        {:error, :unsupported_profile} -> {:error, :unsupported_profile}
        {:error, _not_found} -> {:error, :unavailable}
      end
    end
  end

  # A submitted version identity is never trusted: it must resolve inside the
  # scope's organization before the run is read. An absent one leaves the
  # identity to be resolved from the run's own version.
  defp version_in_scope(_scope, nil), do: :ok

  defp version_in_scope(scope, version_id) do
    if is_nil(Versions.get_gtfs_version_for_lifecycle(scope.organization_id, version_id)) do
      {:error, :unavailable}
    else
      :ok
    end
  end

  defp window(params) do
    with {:ok, from_date} <- cast_date(Map.get(params, "from")),
         {:ok, to_date} <- cast_date(Map.get(params, "to")),
         true <- Date.compare(from_date, to_date) != :gt,
         true <- Date.diff(to_date, from_date) + 1 <= @max_window_days do
      {:ok, from_date, to_date}
    else
      _refused -> {:error, :invalid_window}
    end
  end

  defp artifact_identity(%Run{} = run) do
    %{
      run_id: run.id,
      version_id: run.gtfs_version_id,
      sha256: run.artifact_sha256,
      size: run.artifact_size_bytes,
      export_type: run.export_type,
      expires_at: run.artifact_expires_at,
      estimate_missing_times: run.estimate_missing_times,
      estimate_method: run.estimate_method
    }
  end

  @doc """
  Projects one resolved comparable run into the chooser row returned by
  `list_choices/2`.

  Callers remain responsible for resolving the run through an authorized,
  organization-scoped comparison lookup before using this pure projection.
  """
  @spec choice_row(%Run{}) :: map()
  def choice_row(%Run{} = run) do
    run
    |> artifact_identity()
    |> Map.put(:version_name, run.version_name)
    |> Map.put(:created_at, run.inserted_at)
  end

  defp page_limit(opts) do
    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 -> {:ok, min(limit, @max_limit)}
      _absent_or_invalid -> {:ok, @default_limit}
    end
  end

  # The cursor is the position of the last returned row in the query's own
  # `(inserted_at DESC, id ASC)` order, so paging cannot skip or repeat a row
  # when two runs share an insert timestamp.
  defp next_cursor(nil), do: nil

  defp next_cursor(%Run{inserted_at: inserted_at, id: id}) do
    Base.url_encode64(DateTime.to_iso8601(inserted_at) <> "|" <> id, padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(""), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [at, id] <- :binary.split(decoded, "|"),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(at),
         {:ok, run_id} <- Ecto.UUID.cast(id) do
      {:ok, {inserted_at, run_id}}
    else
      _malformed -> {:error, :unavailable}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :unavailable}

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp cast_optional_uuid(nil), do: {:ok, nil}
  defp cast_optional_uuid(value), do: cast_uuid(value)

  defp cast_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp cast_date(_value), do: :error
end
