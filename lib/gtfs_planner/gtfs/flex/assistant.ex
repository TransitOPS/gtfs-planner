defmodule GtfsPlanner.Gtfs.Flex.Assistant do
  @moduledoc """
  The scoped Flex policy workspace: the saved service a helper conversation is
  about, read once and frozen (AC-1, AC-3; CL-1).

  `workspace/2` is the host-only initial capture entrypoint. It authorizes the
  current editor, resolves the service UUID it is given through the existing
  `GtfsPlanner.Gtfs.Flex.get_service/3` in the scope's trusted organization and
  version, and reads the service, its areas and their geometry, the calendars
  its stored fields name, the readiness facts and the computed checks inside one
  PostgreSQL `REPEATABLE READ READ ONLY` transaction
  (`GtfsPlanner.Gtfs.Flex.Assistant.Snapshot`). Every part of the answer
  therefore describes one database state, and a controlled writer that commits
  between two of its reads is invisible to all of it. The transaction is closed
  before the caller makes any provider request, so no provider call is ever made
  while the snapshot is held.

  `workspace/1` is the same loader for a conversation: it reads the service ID
  from the accepted source snapshot and delegates. The `service_id` a workspace
  is loaded for always comes from the successfully loaded native page, never
  from a tool argument or model output.

  `prepare/2` turns a proposed policy into a candidate against the current
  saved service, and `preview/2` computes the comparison of any candidate with
  that saved service. Both are pure with respect to persistence: the candidate
  is an in-memory `%FlexService{}` that only the native page's explicit Save may
  ever persist (AC-4–AC-6; CL-2). See "Preparing a candidate" below.

  ## Authority and refusals

    * The organization and version come from the scope and are never cast from a
      caller's argument. A service of another organization or version, a deleted
      service and a malformed id are the single `{:error, :unavailable}`, so no
      foreign metadata is disclosed.
    * A membership that is no longer an active editor is `{:error, :forbidden}`,
      checked through `GtfsPlanner.Agents.Scope.authorized_context/1` before any
      service read.
    * Nothing here writes: no entity, audit or job row, and the read-only
      transaction makes an accidental write impossible rather than merely
      unlikely.

  ## Completeness

  A calendar a stored field of the service names — an hours row, a booking rule,
  a detour's `calendar_service_ids`, or the office calendar a business-day rule
  depends on — must exist in the scoped version for the workspace to be a
  complete review. A missing one is `{:error, {:incomplete, reason}}` naming the
  calendar; no supported-policy review is ever reported from a workspace whose
  inputs are missing. The whole provider projection plus its evidence shares the
  existing 32 KiB tool-result bound, and an over-limit workspace is explicitly
  `{:incomplete, :workspace_too_large}` rather than a truncated complete answer.

  ## What the workspace carries

  The `:dependencies` and `:facts` members are the complete exact inputs
  `GtfsPlanner.Gtfs.Flex.Checks.run/3` and
  `GtfsPlanner.Gtfs.Flex.Export.plan/5` need, plus the generated wording
  `GtfsPlanner.Gtfs.Flex.RiderText` produces. `:view` is the minimal projection
  the provider may see: the selected service's policy fields, its named areas by
  key, the relevant calendar rows and exceptions, the generated wording and the
  computed checks. Area geometry, the version's full facts and every other
  service's records are in the workspace for the server's own use and are never
  in the view.

  `dependencies/3` re-reads that exact saved content for a caller that already
  holds a lock of its own, so `fingerprint/1` can be recomputed at write time
  against the same shape the workspace froze. It is how a guarded native save
  (`GtfsPlanner.Gtfs.Flex.save_service/5`, with
  `GtfsPlanner.Gtfs.Flex.Assistant.Guard`) proves that the service, its areas and
  the calendars its stored fields name have not moved since the review, and
  `canonical/1` is the single encoding every digest in this slice is built on.

  ## Preparing a candidate

  `prepare/2` accepts one allowlisted, string-keyed map and nothing else:

      %{"scope" => "all_supported" | "hours_only",
        "hours" => [%{"area_key" =>, "service_id" =>, "start" =>, "end" =>}],
        "booking_rules" => [%{"service_id" =>, "when" =>, "minutes" =>, "days" =>,
                              "by" =>, "business_days" =>,
                              "office_service_id" =>, "max_days" =>}],
        "unsupported" => [statement]}

  At least one of the two arrays is required, each holds at most 100 rows, and
  each is a *complete replacement*: the array enumerates the final state of that
  embedded array, unchanged rows included, and a row that drops out is a removal
  the native review has to confirm. An omitted array is retained exactly as
  saved, and is never read as a deletion.

  Every row goes through the native row changesets and the whole patch through
  `FlexService.changeset/2`, and every referenced identity is checked against
  the scoped version before it is cast: an area key the service does not have and
  a calendar the version does not hold are refusals, not warnings. Nothing else
  is cast — no name, no phone number, no eligibility, no geometry — so an
  unaddressable statement, an unknown key and a contradiction all refuse instead
  of producing a plausible but wrong policy.

  The answer carries the exact saved and candidate rows with their ordinals and
  changed fields, the service fields nothing touched, the native
  `Checks.run/3`, `RiderText` and `Export.plan/5` results for both sides, the
  accepted source and context digests, and the workspace's saved dependency
  fingerprint, so a later guarded save can prove the baseline it reviewed
  against (AC-10). `unsupported` is the caller's explicit list of source
  statements this slice cannot represent. Under `"all_supported"` any such
  statement blocks preparation: a complete supported policy carries none. Under
  `"hours_only"` the booking rules are kept exactly as saved, the booking_rules
  array is refused, and the statements become visible exclusions — so a
  discretionary "same-day if the dispatcher permits" is reported as excluded
  prose and never as a guaranteed `same_day` rule (AC-6).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Assistant.Snapshot
  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.Export
  alias GtfsPlanner.Gtfs.Flex.Export.Areas
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexHours
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo

  # The existing tool-result bound shared by one result and its evidence
  # (`GtfsPlanner.Agents.Dispatch`). An over-limit workspace is refused whole.
  @max_projection_bytes 32_768

  @snapshot_kind "flex_policy"

  @source_ref "gtfs_flex_policy_workspace"

  # `prepare/2`'s whole allowlist. Anything else in the input is refused, so a
  # proposal can never name a service, a calendar of another version or a field
  # the native page does not own.
  @input_fields ~w(hours booking_rules scope unsupported)
  @prepare_scopes ~w(all_supported hours_only)
  @hours_fields ~w(area_key service_id start end)
  @rule_fields ~w(service_id when minutes days by business_days office_service_id max_days)
  @max_rows 100
  @max_unsupported 20
  @max_statement_chars 500

  # The service's own scalar policy fields: the ones a preparation can leave
  # alone and the review reports as untouched. The two embedded arrays and the
  # areas are compared separately.
  @policy_fields [
    :name,
    :kind,
    :active,
    :agency_id,
    :riders,
    :eligibility,
    :include_registered,
    :phone,
    :phone_hours,
    :booking_url,
    :info_url,
    :note,
    :hub_stop_ids,
    :route_id,
    :distance_m,
    :wording,
    :measure,
    :first_stop_id,
    :last_stop_id,
    :dropoffs,
    :ada_only,
    :band_start,
    :band_end,
    :calendar_service_ids
  ]

  @typedoc """
  The exact saved inputs one workspace froze.

  `service` carries its areas in position order, `areas` and `geojson` are the
  area rows and their stored geometry as `Export.plan/5` reads them, and
  `calendar_rows` holds the weekly row, exceptions and attributes of every
  calendar the service's stored fields name. `fingerprint/1` digests exactly
  this map, so a later transaction can re-read the same content and compare.
  """
  @type dependencies :: %{
          service: FlexService.t(),
          areas: [FlexArea.t()],
          geojson: %{optional(Ecto.UUID.t()) => map()},
          calendar_rows: %{optional(String.t()) => calendar_row()}
        }

  @typedoc "One referenced calendar's weekly row, exceptions and attributes."
  @type calendar_row :: %{
          service_id: String.t(),
          weekly: map() | nil,
          exceptions: [%{date: Date.t(), exception_type: integer()}],
          attributes: map() | nil
        }

  @typedoc """
  One complete workspace: the frozen dependencies, the exact native inputs and
  answers derived from them, and the bounded projection a provider may read.
  """
  @type workspace :: %{
          required(:service_id) => Ecto.UUID.t(),
          required(:dependencies) => dependencies(),
          required(:fingerprint) => String.t(),
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          required(:area_inputs) => [%{area: FlexArea.t(), geojson: map() | nil}],
          required(:calendars) => map(),
          required(:calendar_rows) => %{optional(String.t()) => calendar_row()},
          required(:facts) => Checks.facts(),
          required(:others) => [FlexService.t()],
          required(:checks) => [Checks.check()],
          required(:check_status) => map(),
          required(:wording) => map(),
          required(:view) => map()
        }

  # --- entry points -----------------------------------------------------------

  @doc """
  Loads the workspace for the service named by this scope's accepted source.

  The service ID comes from the accepted `flex_policy` snapshot, never from a
  tool argument. A scope with no accepted snapshot, a snapshot of another kind
  and a snapshot without a service ID are the single `{:error, :unavailable}`.
  """
  @spec workspace(Scope.t()) ::
          {:ok, workspace(), Pack.evidence()} | {:error, workspace_error()}
  def workspace(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{kind: @snapshot_kind, payload: %{"service_id" => service_id}}
      when is_binary(service_id) ->
        workspace(scope, service_id)

      _other ->
        {:error, :unavailable}
    end
  end

  @doc """
  Loads the scoped Flex policy workspace for one service.

  `service_id` is the service the native page already loaded. Returns
  `{:ok, workspace, evidence}`, `{:error, :forbidden}` for a membership that is
  no longer an active editor, `{:error, :unavailable}` for a service this
  organization and version cannot resolve, and `{:error, {:incomplete, reason}}`
  when a calendar the service names is missing or the bounded projection does
  not fit one tool result.
  """
  @spec workspace(Scope.t(), Ecto.UUID.t() | String.t()) ::
          {:ok, workspace(), Pack.evidence()} | {:error, workspace_error()}
  def workspace(%Scope{} = scope, service_id) do
    with :ok <- Scope.authorized_context(scope) do
      scoped_workspace(scope, service_id)
    end
  end

  # The snapshot read and the answers it maps to. A service of another
  # organization or version, a deleted service and a malformed id are the same
  # answer, so no foreign metadata is disclosed.
  defp scoped_workspace(scope, service_id) do
    organization_id = scope.organization_id
    version_id = scope.gtfs_version_id

    case in_snapshot(fn -> snapshot_workspace(organization_id, version_id, service_id) end) do
      {:ok, {:ok, workspace}} ->
        {:ok, workspace, evidence(workspace, scope)}

      {:ok, {:error, :not_found}} ->
        {:error, :unavailable}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The scoped service read and the workspace projection, in the one shape
  # `workspace/2` matches on: `{:ok, workspace}` or a reason it turns into its
  # own answer above.
  defp snapshot_workspace(organization_id, version_id, service_id) do
    with {:ok, service} <- Flex.get_service(organization_id, version_id, service_id) do
      build(organization_id, version_id, service)
    end
  end

  @doc """
  Re-reads the exact dependency content `fingerprint/1` digests.

  This is the same read `workspace/2` freezes, in the same shape, for a caller
  that already holds a lock of its own: a guarded native save calls it inside
  its exclusive transaction and compares `fingerprint/1` over the result with
  the baseline its reviewed guard carries, so a calendar-only, area-only or
  service-only commit that landed since the review is visible before any write.

  It opens no transaction and takes no lock of its own, so it describes exactly
  the state the caller's transaction can see. A calendar the service names that
  is no longer in the version is simply absent from `calendar_rows` here: the
  digest moves, and the caller decides what that means.
  """
  @spec dependencies(Ecto.UUID.t(), Ecto.UUID.t(), FlexService.t()) :: dependencies()
  def dependencies(organization_id, version_id, %FlexService{} = service) do
    service = %{service | areas: areas_in_position_order(organization_id, version_id, service.id)}

    %{
      service: service,
      areas: service.areas,
      geojson: Geometry.get_geojson(Enum.map(service.areas, & &1.id)),
      calendar_rows: referenced_calendar_rows(organization_id, version_id, service)
    }
  end

  @doc """
  The canonical digest of one workspace's saved dependencies.

  It covers the exact stored content — the service's complete ordered fields
  with its `lock_version`, its hours and booking rules in order, its areas in
  position order with their stored geometry, and every referenced calendar's
  weekly row, exceptions and attributes — encoded deterministically, so two
  reads of the same content always agree and any committed change to any of
  them does not. `updated_at` alone is never the dependency, and nothing here
  reads the clock.
  """
  @spec fingerprint(dependencies()) :: String.t()
  def fingerprint(%{service: %FlexService{}} = dependencies) when is_map(dependencies) do
    %{
      scope: {dependencies.service.organization_id, dependencies.service.gtfs_version_id},
      service: service_snapshot(dependencies.service),
      areas: Enum.map(dependencies.areas, &area_snapshot(&1, dependencies.geojson)),
      calendars: dependencies.calendar_rows
    }
    |> canonical_value()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @typedoc "One refusal or incompleteness reason from `workspace/2`."
  @type workspace_error :: :forbidden | :unavailable | {:incomplete, term()}

  @typedoc """
  One embedded array compared row by row against the saved rows.

  The rows are the saved ordinals: `changed` and `unchanged` are ordinals the
  candidate kept at that position, `added` and `removed` the positions only one
  side has. Because the arrays are complete replacements, a row the candidate
  omits appears here as a removal for the native review rather than disappearing
  (AC-4).
  """
  @type comparison :: %{
          required(:saved) => [map()],
          required(:candidate) => [map()],
          required(:changed) => [
            %{ordinal: non_neg_integer(), fields: [String.t()], before: map(), after: map()}
          ],
          required(:unchanged) => [non_neg_integer()],
          required(:added) => [%{ordinal: non_neg_integer(), row: map()}],
          required(:removed) => [%{ordinal: non_neg_integer(), row: map()}]
        }

  @typedoc """
  The native comparison of one candidate with the saved service, computed
  without touching persistence (AC-5).
  """
  @type preview :: %{
          required(:service_id) => Ecto.UUID.t(),
          required(:saved_lock_version) => integer(),
          required(:candidate) => FlexService.t(),
          required(:checks) => map(),
          required(:rider_text) => map(),
          required(:export) => map(),
          required(:hours) => comparison(),
          required(:booking_rules) => comparison(),
          required(:unchanged_fields) => [atom()],
          required(:changed_fields) => [atom()],
          required(:areas_changed?) => boolean(),
          required(:warnings) => [String.t()],
          required(:exclusions) => [String.t()]
        }

  @typedoc """
  One prepared candidate: the preview plus the exact patch that produced it, the
  prepare scope, the source statements it could not represent, and the digests
  that bind it to the accepted source, the conversation context and the saved
  dependency fingerprint a later guarded save re-reads (AC-4, AC-10).
  """
  @type prepared :: %{
          required(:service_id) => Ecto.UUID.t(),
          required(:service_key) => String.t() | nil,
          required(:saved_lock_version) => integer(),
          required(:candidate) => FlexService.t(),
          required(:checks) => map(),
          required(:rider_text) => map(),
          required(:export) => map(),
          required(:hours) => comparison(),
          required(:booking_rules) => comparison(),
          required(:unchanged_fields) => [atom()],
          required(:changed_fields) => [atom()],
          required(:areas_changed?) => boolean(),
          required(:warnings) => [String.t()],
          required(:exclusions) => [String.t()],
          required(:prepare_scope) => :all_supported | :hours_only,
          required(:replaced) => [:hours | :booking_rules],
          required(:unsupported) => [String.t()],
          required(:patch) => map(),
          required(:source_digest) => String.t() | nil,
          required(:context_digest) => String.t(),
          required(:saved_fingerprint) => String.t()
        }

  @typedoc "One refusal from `prepare/2` or `preview/2`."
  @type prepare_error :: workspace_error() | {:invalid_input, term()} | {:unsupported, term()}

  # --- preparation ------------------------------------------------------------

  @doc """
  Prepares a supported policy candidate for the service this scope's accepted
  source names.

  The scope is authorized and the workspace is read first, so the comparison is
  always against the current saved service and the answer carries the
  fingerprint of the dependencies it was built from. `input` is the allowlisted
  string-keyed map the moduledoc describes; anything else refuses.

  Returns `{:ok, prepared}` or `{:error, reason}`. Nothing here writes: the
  candidate is an in-memory struct, and no audit or job row is created for a
  read, a refusal or an answer.
  """
  @spec prepare(Scope.t(), map()) :: {:ok, prepared()} | {:error, prepare_error()}
  def prepare(%Scope{} = scope, input) when is_map(input) do
    with {:ok, workspace, _evidence} <- workspace(scope) do
      build_prepared(workspace, scope, input)
    end
  end

  def prepare(%Scope{}, _input), do: {:error, {:invalid_input, :not_a_map}}

  @doc """
  The native comparison of one candidate with the workspace's saved service.

  This is the shared draft-preview computation: the native readiness checks,
  the generated rider wording, the rider's own "what changed" lines, the export
  plan and the `booking_rules.txt` columns one candidate produces, and the
  row-by-row saved/candidate comparison. `candidate` must be a struct of the
  workspace's own service in its own organization and version, so a foreign
  struct never reaches the checks; any other struct is refused. It writes
  nothing.
  """
  @spec preview(workspace(), FlexService.t()) :: {:ok, preview()} | {:error, prepare_error()}
  def preview(
        %{dependencies: %{service: %FlexService{} = saved}} = workspace,
        %FlexService{} = candidate
      ) do
    with :ok <- check_candidate(saved, candidate) do
      build_preview(workspace, candidate)
    end
  end

  defp build_prepared(workspace, scope, input) do
    with :ok <- check_input_fields(input),
         {:ok, prepare_scope} <- check_prepare_scope(input),
         {:ok, unsupported} <- check_unsupported(input),
         :ok <- check_replacements(input),
         :ok <- check_prepare_mode(prepare_scope, input, unsupported),
         {:ok, patch} <- build_patch(workspace, input),
         {:ok, candidate} <- apply_patch(workspace, patch) do
      case preview(workspace, candidate) do
        {:ok, preview} ->
          {:ok, prepared(workspace, scope, prepare_scope, unsupported, patch, preview)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepared(workspace, scope, prepare_scope, unsupported, patch, preview) do
    saved = workspace.dependencies.service

    preview
    |> Map.put(:service_key, saved.key)
    |> Map.put(:prepare_scope, prepare_scope)
    |> Map.put(:replaced, replaced_arrays(patch))
    |> Map.put(:unsupported, unsupported)
    |> Map.put(:patch, patch)
    |> Map.put(:exclusions, exclusions(prepare_scope, unsupported, patch, saved))
    |> Map.put(:source_digest, source_digest(scope))
    |> Map.put(:context_digest, Scope.context_digest(scope))
    |> Map.put(:saved_fingerprint, workspace.fingerprint)
  end

  # What this candidate deliberately does not do. The unsupported statements are
  # quoted back so the editor reads the prose that was left out beside the rows
  # that were kept, and a retained array is named as retained rather than
  # silently absent from the patch.
  defp exclusions(_prepare_scope, unsupported, patch, %FlexService{} = saved) do
    statements =
      Enum.map(unsupported, &"Left out of this candidate, kept for the native editor: #{&1}")

    retained =
      if Map.has_key?(patch, "booking_rules") do
        []
      else
        [
          "The saved booking policy is untouched: all #{length(saved.booking_rules)} " <>
            "booking rule(s) stay exactly as they are."
        ]
      end

    statements ++
      retained ++
      [
        "Every other saved field, including contacts, eligibility, drop-off policy and area geometry, is untouched."
      ]
  end

  defp replaced_arrays(patch) do
    Enum.filter([:hours, :booking_rules], &Map.has_key?(patch, Atom.to_string(&1)))
  end

  # The digest the server computed for the accepted source envelope, or nil when
  # this scope froze no source. It is the snapshot's own digest, never one the
  # caller supplies.
  defp source_digest(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{digest: digest} when is_binary(digest) -> digest
      _other -> nil
    end
  end

  # --- the input --------------------------------------------------------------

  defp check_input_fields(input) do
    Enum.reduce_while(input, :ok, fn {key, _value}, :ok ->
      if is_binary(key) and key in @input_fields do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_input, {:unknown_key, key}}}}
      end
    end)
  end

  defp check_prepare_scope(input) do
    case Map.get(input, "scope") do
      scope when is_binary(scope) and scope in @prepare_scopes ->
        {:ok, String.to_existing_atom(scope)}

      _other ->
        {:error, {:invalid_input, :scope}}
    end
  end

  # The source statements this slice cannot represent. Each is bounded, so a
  # source document is never smuggled in as one entry.
  defp check_unsupported(input) do
    case Map.get(input, "unsupported", []) do
      statements when is_list(statements) and length(statements) <= @max_unsupported ->
        unsupported_statements(statements)

      _other ->
        {:error, {:invalid_input, :unsupported}}
    end
  end

  # The bounded list, statement by statement, keeping source order. A statement
  # that is not a string is refused with its index; one that is refused on its
  # own content names the trimmed text.
  defp unsupported_statements(statements) do
    statements
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {statement, _index}, {:ok, acc} when is_binary(statement) ->
        case checked_statement(statement) do
          {:ok, trimmed} ->
            {:cont, {:ok, acc ++ [trimmed]}}

          {:error, trimmed} ->
            {:halt, {:error, {:invalid_input, {:unsupported_statement, trimmed}}}}
        end

      {statement, index}, _acc ->
        {:halt, {:error, {:invalid_input, {:unsupported_statement, index, statement}}}}
    end)
  end

  # One statement, trimmed and bounded. The refusal names the trimmed text, the
  # same value the accepted list would have carried.
  defp checked_statement(statement) do
    trimmed = String.trim(statement)

    if trimmed != "" and String.length(trimmed) <= @max_statement_chars do
      {:ok, trimmed}
    else
      {:error, trimmed}
    end
  end

  # At least one complete replacement array is required, and an omitted array is
  # never read as a deletion. An empty array would be exactly such a deletion
  # over every row at once, and this slice has no source-backed removal channel,
  # so it is refused here rather than confirmed by a later review (AC-4).
  defp check_replacements(input) do
    Enum.reduce_while([:hours, :booking_rules], :ok, fn field, :ok ->
      case Map.get(input, Atom.to_string(field)) do
        nil ->
          {:cont, :ok}

        rows when is_list(rows) and rows != [] and length(rows) <= @max_rows ->
          {:cont, :ok}

        _other ->
          {:halt, {:error, {:invalid_input, {field, :replacement}}}}
      end
    end)
    |> require_one_replacement(input)
  end

  defp require_one_replacement(:ok, input) do
    if Map.has_key?(input, "hours") or Map.has_key?(input, "booking_rules") do
      :ok
    else
      {:error, {:invalid_input, :no_replacement}}
    end
  end

  defp require_one_replacement(error, _input), do: error

  defp check_prepare_mode(:all_supported, _input, []), do: :ok

  defp check_prepare_mode(:all_supported, _input, unsupported) do
    {:error, {:unsupported, {:source_statements, unsupported}}}
  end

  # An explicit hours-only preparation keeps every booking rule, so a proposed
  # booking array contradicts the scope the editor chose rather than being
  # quietly ignored.
  defp check_prepare_mode(:hours_only, input, _unsupported) do
    if Map.has_key?(input, "booking_rules") do
      {:error, {:unsupported, :booking_rules_in_hours_only}}
    else
      :ok
    end
  end

  # --- the patch --------------------------------------------------------------

  defp build_patch(workspace, input) do
    with {:ok, hours} <- hours_rows(workspace, Map.get(input, "hours")),
         {:ok, rules} <- rule_rows(workspace, Map.get(input, "booking_rules")) do
      patch =
        %{}
        |> put_replacement("hours", hours)
        |> put_replacement("booking_rules", rules)

      {:ok, patch}
    end
  end

  defp put_replacement(patch, _field, nil), do: patch
  defp put_replacement(patch, field, rows), do: Map.put(patch, field, rows)

  defp hours_rows(_workspace, nil), do: {:ok, nil}

  defp hours_rows(workspace, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case hours_row(workspace, row, index) do
        {:ok, attrs} -> {:cont, {:ok, acc ++ [attrs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp hours_row(workspace, row, index) do
    with :ok <- check_row(:hours, row, index, @hours_fields),
         {:ok, attrs} <- row_attrs(row, @hours_fields),
         :ok <- check_area_key(workspace, attrs),
         :ok <- check_calendar(workspace, attrs, "service_id") do
      cast_row(FlexHours, @hours_fields, attrs, :hours, index)
    end
  end

  defp rule_rows(_workspace, nil), do: {:ok, nil}

  defp rule_rows(workspace, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case rule_row(workspace, row, index) do
        {:ok, attrs} -> {:cont, {:ok, acc ++ [attrs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rule_row(workspace, row, index) do
    with :ok <- check_row(:booking_rules, row, index, @rule_fields),
         {:ok, attrs} <- row_attrs(row, @rule_fields),
         :ok <- check_calendar(workspace, attrs, "service_id"),
         :ok <- check_calendar(workspace, attrs, "office_service_id") do
      cast_row(FlexBookingRule, @rule_fields, attrs, :booking_rules, index)
    end
  end

  defp check_row(field, row, index, allowed) do
    cond do
      not is_map(row) ->
        {:error, {:invalid_input, {field, index, :not_a_map}}}

      Enum.any?(row, fn {key, _value} -> not (is_binary(key) and key in allowed) end) ->
        {:error, {:invalid_input, {field, index, :unknown_field}}}

      true ->
        :ok
    end
  end

  defp row_attrs(row, allowed) do
    Enum.reduce(allowed, %{}, fn key, acc ->
      case Map.fetch(row, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
    |> then(&{:ok, &1})
  end

  # An hours row's area is one of this service's own areas. A key the service
  # does not have is refused, so no policy is proposed against an area the page
  # cannot show.
  defp check_area_key(workspace, attrs) do
    case Map.get(attrs, "area_key") do
      key when is_binary(key) and key != "" ->
        if key in Enum.map(workspace.dependencies.areas, & &1.key) do
          :ok
        else
          {:error, {:invalid_input, {:unknown_area, key}}}
        end

      _other ->
        :ok
    end
  end

  # A calendar is one this version actually holds. `facts.service_ids` is the
  # version's complete calendar set, so a calendar of another version or a
  # guessed id is refused rather than exported as an unknown service.
  defp check_calendar(workspace, attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" ->
        if MapSet.member?(workspace.facts.service_ids, value) do
          :ok
        else
          {:error, {:invalid_input, {:unknown_calendar, field, value}}}
        end

      _other ->
        :ok
    end
  end

  # Each row is cast by its own native changeset, so the values that reach the
  # candidate are the values the native page would store, and a row the native
  # schema refuses is refused here with its own messages.
  defp cast_row(module, fields, attrs, field, index) do
    changeset = module.changeset(struct(module), attrs)

    if changeset.valid? do
      {:ok, changeset |> Ecto.Changeset.apply_changes() |> applied_attrs(fields)}
    else
      {:error, {:invalid_input, {:"invalid_#{field}", index, messages(changeset)}}}
    end
  end

  # The applied row as the same string-keyed map the native form submits, so the
  # patch is exactly what `Flex.save_service/4` reads and stays JSON-encodable:
  # an enum value travels as its own name, never as an atom.
  defp applied_attrs(row, fields) do
    row
    |> Map.from_struct()
    |> Map.take(Enum.map(fields, &String.to_existing_atom/1))
    |> Map.new(fn {key, value} -> {Atom.to_string(key), json_value(value)} end)
  end

  defp json_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp json_value(value), do: value

  defp apply_patch(workspace, patch) do
    changeset = FlexService.changeset(workspace.dependencies.service, patch)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, {:invalid_input, {:invalid_changeset, messages(changeset)}}}
    end
  end

  # The complete service changeset is applied to an in-memory struct and never
  # inserted: an assistant candidate is a struct, not a row, and the only writer
  # of this table is the native page's explicit Save (CR-1).
  defp messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(& &1)
    |> flatten_errors([])
  end

  defp flatten_errors(errors, path) when is_map(errors) do
    Enum.flat_map(errors, fn {field, messages} ->
      flatten_errors(List.wrap(messages), path ++ [to_string(field)])
    end)
  end

  defp flatten_errors(messages, path) when is_list(messages) do
    Enum.map(messages, &"#{Enum.join(path, ".")} #{error_message(&1)}")
  end

  # A validation message with its interpolation values, read the way the native
  # form reads it, so a refusal quotes the same sentence the editor would see.
  defp error_message({message, options}) when is_binary(message) and is_list(options) do
    Regex.replace(~r"%\{(\w+)\}", message, fn _whole, key ->
      case Keyword.fetch(options, String.to_existing_atom(key)) do
        {:ok, value} -> to_string(value)
        :error -> ""
      end
    end)
  end

  defp error_message(message) when is_binary(message), do: message

  # --- the comparison ---------------------------------------------------------

  defp check_candidate(%FlexService{} = saved, %FlexService{} = candidate) do
    if candidate.id == saved.id and candidate.organization_id == saved.organization_id and
         candidate.gtfs_version_id == saved.gtfs_version_id do
      :ok
    else
      {:error, {:invalid_input, :foreign_candidate}}
    end
  end

  defp build_preview(workspace, %FlexService{} = candidate) do
    saved = workspace.dependencies.service

    candidate_checks = Checks.run(candidate, workspace.facts, workspace.others)
    introduced = introduced_checks(workspace.checks, candidate_checks)
    new_errors = Enum.filter(introduced, &(&1.level == :error))

    case new_errors do
      [] ->
        {:ok,
         %{
           service_id: workspace.service_id,
           saved_lock_version: saved.lock_version,
           candidate: candidate,
           checks: %{
             saved: workspace.checks,
             candidate: candidate_checks,
             introduced: introduced,
             saved_status: workspace.check_status,
             status: Checks.status(candidate, candidate_checks)
           },
           rider_text: %{
             saved: workspace.wording,
             candidate: wording(candidate, workspace.calendars),
             changes: RiderText.changes(saved, candidate, workspace.calendars)
           },
           export: %{
             saved: export_projection(workspace, saved),
             candidate: export_projection(workspace, candidate)
           },
           hours: compare_rows(hours_views(saved.hours), hours_views(candidate.hours)),
           booking_rules:
             compare_rows(rule_views(saved.booking_rules), rule_views(candidate.booking_rules)),
           unchanged_fields: unchanged_fields(saved, candidate),
           changed_fields: changed_fields(saved, candidate),
           areas_changed?: saved.areas != candidate.areas,
           warnings: preview_warnings(introduced, workspace.checks),
           exclusions: []
         }}

      _new_errors ->
        # Native readiness is the authority on whether the proposed policy is
        # contradictory, so a candidate that introduces a readiness error is
        # refused rather than reviewed as if it were sound.
        {:error, {:unsupported, {:contradictory_policy, Enum.map(new_errors, & &1.text)}}}
    end
  end

  # The findings the candidate introduces: a check the saved service did not
  # have, whatever it says. The ones it already had are not this preparation's
  # to fix, and they are reported as warnings instead.
  defp introduced_checks(saved_checks, candidate_checks) do
    saved = MapSet.new(saved_checks, &{&1.level, &1.section, &1.field, &1.text})

    Enum.reject(
      candidate_checks,
      &MapSet.member?(saved, {&1.level, &1.section, &1.field, &1.text})
    )
  end

  # Rows are compared by the saved ordinal, because an embedded row has no id of
  # its own. A row that sits at its saved ordinal with every field equal is
  # unchanged, even when the candidate enumerated it again. Walking the ordinals
  # in order keeps both sides in the page's own order, so a row only one side
  # has leaves a hole rather than shifting the rows after it.
  defp compare_rows(saved_rows, candidate_rows) do
    saved = saved_rows |> Enum.with_index() |> Map.new(fn {row, index} -> {index, row} end)

    candidate =
      candidate_rows |> Enum.with_index() |> Map.new(fn {row, index} -> {index, row} end)

    ordinals = saved |> Map.keys() |> Kernel.++(Map.keys(candidate)) |> Enum.uniq() |> Enum.sort()

    Enum.reduce(
      ordinals,
      %{saved: [], candidate: [], changed: [], unchanged: [], added: [], removed: []},
      fn
        ordinal, acc ->
          case {Map.fetch(saved, ordinal), Map.fetch(candidate, ordinal)} do
            {{:ok, before}, {:ok, after_}} ->
              fields = changed_row_fields(before, after_)

              acc
              |> Map.update!(:saved, &(&1 ++ [before]))
              |> Map.update!(:candidate, &(&1 ++ [after_]))
              |> append_comparison(row_comparison(ordinal, before, after_, fields))

            {:error, {:ok, after_}} ->
              acc
              |> Map.update!(:candidate, &(&1 ++ [after_]))
              |> Map.update!(:added, &(&1 ++ [%{ordinal: ordinal, row: after_}]))

            {{:ok, before}, :error} ->
              acc
              |> Map.update!(:saved, &(&1 ++ [before]))
              |> Map.update!(:removed, &(&1 ++ [%{ordinal: ordinal, row: before}]))
          end
      end
    )
  end

  # One row both sides have: unchanged when every field is equal, changed with
  # the fields that moved otherwise.
  defp row_comparison(ordinal, before, after_, fields) do
    if fields == [] do
      {:unchanged, ordinal}
    else
      {:changed, %{ordinal: ordinal, fields: fields, before: before, after: after_}}
    end
  end

  defp append_comparison(acc, {:unchanged, ordinal}),
    do: Map.update!(acc, :unchanged, &(&1 ++ [ordinal]))

  defp append_comparison(acc, {:changed, change}),
    do: Map.update!(acc, :changed, &(&1 ++ [change]))

  defp changed_row_fields(before, after_) do
    before
    |> Map.keys()
    |> Enum.filter(&(Map.get(before, &1) != Map.get(after_, &1)))
    |> Enum.sort()
  end

  defp unchanged_fields(saved, candidate) do
    Enum.filter(@policy_fields, &(Map.get(saved, &1) == Map.get(candidate, &1)))
  end

  defp changed_fields(saved, candidate) do
    Enum.reject(@policy_fields, &(Map.get(saved, &1) == Map.get(candidate, &1)))
  end

  defp preview_warnings(introduced, saved_checks) do
    suggestions =
      for %{level: :warning, text: text} <- introduced, do: "New readiness suggestion: #{text}"

    carried = Enum.count(saved_checks, &(&1.level == :error))

    suggestions ++
      if carried > 0 do
        [
          "The saved service already has #{carried} readiness problem(s); this candidate leaves them as they are."
        ]
      else
        []
      end
  end

  # --- the native export projection -------------------------------------------

  # The export's own plan over the candidate, with the `booking_rules.txt`
  # columns R7's fields produce, so the review can show which booking fields a
  # proposal actually changes. The plan is the same one the service page's export
  # drawer lists, and the area inputs are the workspace's own stored geometry.
  defp export_projection(workspace, %FlexService{} = service) do
    organization_id = workspace.organization_id
    version_id = workspace.gtfs_version_id

    plan =
      Export.plan(organization_id, version_id, service, area_inputs(workspace, service), [])

    %{
      headline: plan.headline,
      counts: plan.counts,
      warnings: plan.warnings,
      rows: Enum.filter(plan.rows, &(&1.file == "booking_rules.txt")),
      booking_rule_fields: Areas.booking_rule_rows(service, workspace.calendars)
    }
  end

  defp area_inputs(workspace, %FlexService{} = service) do
    Enum.map(service.areas, fn area ->
      %{area: area, geojson: Map.get(workspace.dependencies.geojson, area.id)}
    end)
  end

  # --- snapshot boundary ------------------------------------------------------

  # Every source read of one workspace happens inside this transaction and the
  # fingerprint is derived from the rows it returned. The transaction is closed
  # before the caller builds a model request, so no provider call is made while
  # the snapshot is held.
  defp in_snapshot(fun) when is_function(fun, 0) do
    Repo.transaction(
      fn ->
        snapshot_module().begin_read()
        fun.()
      end,
      timeout: :infinity
    )
  end

  defp snapshot_module do
    Application.get_env(:gtfs_planner, :gtfs_flex_assistant_snapshot, Snapshot.Repo)
  end

  # --- workspace parts --------------------------------------------------------

  # Every calendar the service's stored fields name, in a stable order: its
  # hours rows, its booking rules, a business-day rule's office calendar and a
  # detour's own calendars.
  defp referenced_calendar_ids(%FlexService{} = service) do
    hours_ids = Enum.map(service.hours, & &1.service_id)

    rule_ids =
      Enum.flat_map(service.booking_rules, fn rule ->
        [rule.service_id, office_service_id(rule)]
      end)

    (hours_ids ++ rule_ids ++ service.calendar_service_ids)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Only a business-day rule depends on an office calendar; the field is
  # otherwise inert, so an unset one is not a missing dependency.
  defp office_service_id(%{business_days: true, office_service_id: service_id})
       when is_binary(service_id) and service_id != "",
       do: service_id

  defp office_service_id(_rule), do: nil

  defp referenced_calendar_rows(organization_id, version_id, %FlexService{} = service) do
    service_ids = referenced_calendar_ids(service)

    weekly = calendar_rows(Calendar, organization_id, version_id, service_ids)
    attributes = attribute_rows(organization_id, version_id, service_ids)

    exceptions =
      exception_rows(organization_id, version_id, service_ids)
      |> Enum.group_by(& &1.service_id)

    Map.new(service_ids, fn service_id ->
      {service_id,
       %{
         service_id: service_id,
         weekly: Map.get(weekly, service_id),
         exceptions: Map.get(exceptions, service_id, []) |> Enum.sort_by(&exception_order/1),
         attributes: Map.get(attributes, service_id)
       }}
    end)
  end

  defp exception_order(%{date: %Date{} = date, exception_type: type}),
    do: {date, type}

  defp calendar_rows(schema, organization_id, version_id, service_ids) do
    from(row in schema,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id and
          row.service_id in ^service_ids,
      select: row
    )
    |> Repo.all()
    |> Map.new(&{&1.service_id, &1})
  end

  defp attribute_rows(organization_id, version_id, service_ids) do
    from(row in CalendarAttribute,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id and
          row.service_id in ^service_ids,
      select: row
    )
    |> Repo.all()
    |> Map.new(&{&1.service_id, &1})
  end

  defp exception_rows(organization_id, version_id, service_ids) do
    from(row in CalendarDate,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id and
          row.service_id in ^service_ids,
      order_by: [asc: row.date, asc: row.exception_type],
      select: row
    )
    |> Repo.all()
  end

  # A calendar that has no weekly row, no exception and no attribute in this
  # organization and version does not exist here, whatever another organization
  # or version holds. The service names it, so the workspace is incomplete
  # rather than complete over a missing input.
  defp check_referenced_calendars(%FlexService{} = service, calendar_rows) do
    missing =
      service
      |> referenced_calendar_ids()
      |> Enum.filter(&(not calendar_present?(calendar_rows, &1)))

    case missing do
      [] -> :ok
      [service_id | _rest] -> Repo.rollback({:incomplete, {:missing_calendar, service_id}})
    end
  end

  defp calendar_present?(calendar_rows, service_id) do
    case Map.fetch(calendar_rows, service_id) do
      {:ok, %{weekly: nil, exceptions: [], attributes: nil}} -> false
      {:ok, _row} -> true
      :error -> false
    end
  end

  # --- the workspace ----------------------------------------------------------

  defp build(organization_id, version_id, %FlexService{} = service) do
    dependencies = dependencies(organization_id, version_id, service)

    with :ok <- check_referenced_calendars(dependencies.service, dependencies.calendar_rows) do
      build_workspace(organization_id, version_id, dependencies.service, dependencies)
    end
  end

  # The service's own area rows in position order, the same read the scoped
  # loader performs, so a re-read inside a caller's transaction sees the areas
  # that transaction can see rather than a struct's preloaded list.
  defp areas_in_position_order(organization_id, version_id, flex_service_id) do
    from(a in FlexArea,
      where:
        a.flex_service_id == ^flex_service_id and a.organization_id == ^organization_id and
          a.gtfs_version_id == ^version_id,
      order_by: [asc: a.position]
    )
    |> Repo.all()
  end

  defp build_workspace(organization_id, version_id, service, dependencies) do
    calendars = Flex.calendars_map(organization_id, version_id)
    facts = Checks.version_facts(organization_id, version_id)

    others =
      organization_id
      |> Flex.list_services(version_id)
      |> Enum.reject(&(&1.id == service.id))

    checks = Checks.run(service, facts, others)

    area_inputs =
      Enum.map(service.areas, fn area ->
        %{area: area, geojson: Map.get(dependencies.geojson, area.id)}
      end)

    workspace = %{
      service_id: service.id,
      dependencies: dependencies,
      fingerprint: fingerprint(dependencies),
      organization_id: organization_id,
      gtfs_version_id: version_id,
      area_inputs: area_inputs,
      calendars: calendars,
      calendar_rows: dependencies.calendar_rows,
      facts: facts,
      others: others,
      checks: checks,
      check_status: Checks.status(service, checks),
      wording: wording(service, calendars),
      view: nil
    }

    workspace = Map.put(workspace, :view, view(workspace))

    if bounded?(workspace) do
      {:ok, workspace}
    else
      Repo.rollback({:incomplete, :workspace_too_large})
    end
  end

  # The native generated wording for the saved service, computed here so the
  # review and the export read the same words the service page shows. A saved
  # service compared with itself has no unsaved changes.
  defp wording(%FlexService{} = service, calendars) do
    %{
      where_line: RiderText.where_line(service),
      hours_lines: RiderText.hours_lines(service, service.areas, calendars),
      deadline_lines: RiderText.deadline_lines(service, calendars),
      message: RiderText.message(service, calendars),
      rider_name: RiderText.rider_name(service),
      changes: RiderText.changes(service, service, calendars)
    }
  end

  defp bounded?(%{view: view}) do
    byte_size(Jason.encode!(view)) + byte_size(Jason.encode!(evidence_facts(view))) <=
      @max_projection_bytes
  end

  # --- the provider projection ------------------------------------------------

  defp view(workspace) do
    service = workspace.dependencies.service

    %{
      "service" => service_view(service),
      "areas" => Enum.map(workspace.area_inputs, &area_view/1),
      "hours" => Enum.map(service.hours, &hours_view/1),
      "booking_rules" => Enum.map(service.booking_rules, &rule_view/1),
      "calendars" => workspace.calendar_rows |> Map.values() |> Enum.map(&calendar_view/1),
      "rider_text" => %{
        "rider_name" => workspace.wording.rider_name,
        "where" => workspace.wording.where_line,
        "hours_lines" => workspace.wording.hours_lines,
        "deadline_lines" => workspace.wording.deadline_lines,
        "message" => workspace.wording.message,
        "changes" => workspace.wording.changes
      },
      "checks" => Enum.map(workspace.checks, &check_view/1),
      "check_status" => %{
        "tone" => Atom.to_string(workspace.check_status.tone),
        "label" => workspace.check_status.label,
        "errors" => workspace.check_status.errors,
        "warnings" => workspace.check_status.warnings
      },
      "fingerprint" => workspace.fingerprint
    }
  end

  # The selected service's own policy and contact fields. Nothing here is another
  # service's, and no geometry, calendar fact set or contact record of anything
  # else is included.
  defp service_view(%FlexService{} = service) do
    %{
      "id" => service.id,
      "key" => service.key,
      "name" => service.name,
      "kind" => Atom.to_string(service.kind),
      "active" => service.active,
      "riders" => Atom.to_string(service.riders),
      "eligibility" => service.eligibility,
      "include_registered" => service.include_registered,
      "phone" => service.phone,
      "phone_hours" => service.phone_hours,
      "booking_url" => service.booking_url,
      "info_url" => service.info_url,
      "note" => service.note,
      "route_id" => service.route_id,
      "distance_m" => service.distance_m,
      "wording" => service.wording,
      "measure" => Atom.to_string(service.measure),
      "first_stop_id" => service.first_stop_id,
      "last_stop_id" => service.last_stop_id,
      "dropoffs" => Atom.to_string(service.dropoffs),
      "ada_only" => service.ada_only,
      "band_start" => service.band_start,
      "band_end" => service.band_end,
      "calendar_service_ids" => service.calendar_service_ids,
      "hub_stop_ids" => service.hub_stop_ids,
      "lock_version" => service.lock_version
    }
  end

  # Area names and keys only. The stored polygon is the server's own input to
  # `Export.plan/5` and the overlap checks; it is not part of the projection.
  defp area_view(%{area: area}) do
    %{
      "key" => area.key,
      "position" => area.position,
      "name" => area.name,
      "source" => area.source && Atom.to_string(area.source),
      "route_ids" => area.route_ids,
      "distance_m" => area.distance_m
    }
  end

  defp hours_view(row) do
    %{
      "area_key" => row.area_key,
      "service_id" => row.service_id,
      "start" => row.start,
      "end" => row.end
    }
  end

  defp hours_views(rows), do: Enum.map(rows, &hours_view/1)

  defp rule_views(rows), do: Enum.map(rows, &rule_view/1)

  defp rule_view(rule) do
    %{
      "service_id" => rule.service_id,
      "when" => rule.when && Atom.to_string(rule.when),
      "minutes" => rule.minutes,
      "days" => rule.days,
      "by" => rule.by,
      "business_days" => rule.business_days,
      "office_service_id" => rule.office_service_id,
      "max_days" => rule.max_days
    }
  end

  defp calendar_view(%{service_id: service_id} = row) do
    %{
      "service_id" => service_id,
      "weekly" => weekly_view(row.weekly),
      "exceptions" =>
        Enum.map(row.exceptions, fn exception ->
          %{
            "date" => Date.to_iso8601(exception.date),
            "exception_type" => exception.exception_type
          }
        end),
      "attributes" => attributes_view(row.attributes)
    }
  end

  defp weekly_view(nil), do: nil

  defp weekly_view(weekly) do
    %{
      "monday" => weekly.monday,
      "tuesday" => weekly.tuesday,
      "wednesday" => weekly.wednesday,
      "thursday" => weekly.thursday,
      "friday" => weekly.friday,
      "saturday" => weekly.saturday,
      "sunday" => weekly.sunday,
      "start_date" => Date.to_iso8601(weekly.start_date),
      "end_date" => Date.to_iso8601(weekly.end_date)
    }
  end

  defp attributes_view(nil), do: nil

  defp attributes_view(attributes) do
    %{
      "service_schedule_name" => attributes.service_schedule_name,
      "service_description" => attributes.service_description,
      "service_schedule_type" => attributes.service_schedule_type,
      "service_schedule_typicality" => attributes.service_schedule_typicality
    }
  end

  defp check_view(check) do
    %{
      "level" => Atom.to_string(check.level),
      "section" => Atom.to_string(check.section),
      "field" => Atom.to_string(check.field),
      "text" => check.text
    }
  end

  # --- evidence ---------------------------------------------------------------

  # The evidence is built from the same rows the view describes, so its counts
  # cannot disagree with what the model read, and its digest covers the exact
  # view that was returned (INV-2). Nothing here is invented: the source
  # revision is the saved service's own `lock_version`.
  defp evidence(workspace, %Scope{} = scope) do
    service = workspace.dependencies.service

    %{
      kind: "flex_policy_workspace",
      title: service.name || "Flex service",
      total: length(workspace.checks),
      total_label: "readiness checks",
      completeness: :complete,
      completeness_reason: nil,
      facts: evidence_facts(workspace.view),
      source_ref: @source_ref,
      digest: digest(workspace.view),
      source_revision: Integer.to_string(service.lock_version),
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: [
        "Area geometry, other services and the version's other records are not part of this workspace."
      ],
      resources: [%{kind: "flex_service", id: service.id, label: service.name}]
    }
  end

  # The server-computed counts beside the answer, in the panel's own shape.
  # These are also the bytes the projection bound measures with the view, so an
  # over-limit workspace is refused before any provider sees a plausible but
  # short answer.
  defp evidence_facts(view) do
    [
      %{label: "Hours rows", value: Integer.to_string(length(view["hours"]))},
      %{label: "Booking rules", value: Integer.to_string(length(view["booking_rules"]))},
      %{label: "Areas", value: Integer.to_string(length(view["areas"]))},
      %{label: "Calendars", value: Integer.to_string(length(view["calendars"]))},
      %{label: "Readiness errors", value: Integer.to_string(view["check_status"]["errors"])},
      %{label: "Readiness warnings", value: Integer.to_string(view["check_status"]["warnings"])}
    ]
  end

  defp digest(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp identity_label(%Scope{} = scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  # --- canonical dependency content -------------------------------------------

  @doc """
  The deterministic canonical encoding every digest in this slice is built on.

  A `%DateTime{}`, `%Date{}` or `%Decimal{}` becomes its exact text, an enum atom
  becomes its name, a map becomes its entries sorted by key and a struct becomes
  its own fields without `:__meta__`. Two equal contents therefore always encode
  identically and any committed change to any of them does not.
  """
  @spec canonical(term()) :: term()
  def canonical(value), do: canonical_value(value)

  defp canonical_value(%DateTime{} = value), do: {:datetime, DateTime.to_iso8601(value)}
  defp canonical_value(%Date{} = value), do: {:date, Date.to_iso8601(value)}
  defp canonical_value(%Decimal{} = value), do: {:decimal, Decimal.to_string(value, :normal)}

  defp canonical_value(%_{} = value),
    do: value |> Map.from_struct() |> Map.drop([:__meta__]) |> canonical_value()

  defp canonical_value(nil), do: nil
  defp canonical_value(value) when is_atom(value), do: {:atom, Atom.to_string(value)}

  defp canonical_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, entry} -> {to_string(key), canonical_value(entry)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)

  defp canonical_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> canonical_value()

  defp canonical_value(value), do: value

  # The service's complete ordered fields with its `lock_version`, so a change
  # to any stored field changes the fingerprint.
  defp service_snapshot(%FlexService{} = service) do
    service
    |> Map.from_struct()
    |> Map.drop([:areas, :__struct__, :__meta__])
    |> canonical_value()
  end

  # One area's stored row plus its geometry, so an area-only change is visible.
  defp area_snapshot(%FlexArea{} = area, geojson) do
    %{
      row: area |> Map.from_struct() |> Map.drop([:__struct__, :__meta__]) |> canonical_value(),
      geojson: canonical_value(Map.get(geojson, area.id))
    }
  end
end
