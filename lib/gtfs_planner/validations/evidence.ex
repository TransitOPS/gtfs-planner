defmodule GtfsPlanner.Validations.Evidence do
  @moduledoc """
  Bounded, digest-bound reads of one scoped completed validation report.

  `findings/2` resolves the run inside the scope's organization and version
  before any report JSON is read (`GtfsPlanner.Validations.fetch_scoped_run/3`),
  so a foreign, absent, malformed or wrong-version run is one `:unavailable`
  result and no other organization's report is ever deserialized (INV-1, AC-1).
  A membership that is no longer an active editor's stops the read before the
  query.

  Only a `completed` `mobility_data`/`mobility_data_flex` run whose engine is nil
  or `"mobility_data"` and whose result schema version is nil or 1 can be read.
  Still running, failed, another engine, another schema or a report without a
  recognizable `notices` shape is `:unavailable` rather than a guess.

  Three stored shapes are recognized, and none of them is rewritten:

    * the canonical groups step 2 writes, with `total_notices` and `notices`;
    * a historical wrapper group whose `notices` hold the upstream NoticeReport
      (`totalNotices`/`sampleNotices`). The embedded `totalNotices` is the true
      count and outranks the wrapper's own total or its length, and an embedded
      report without a count leaves the total unknown rather than inferring it
      from the retained samples;
    * a flat notice list, where each stored entry is one instance.

  A group keeps the stored total, the retained sample count and whether those
  samples are all of it. An unknown severity stays counted under its own key, so
  `totals_by_severity` and `total_instances` stay exact (AC-4).

  The `digest` is a SHA-256 over the canonical full source groups, the run's
  checked-input provenance and its scope. Paging and filtering are applied after
  it, so every page of one report carries the same digest. Cursors are opaque
  version-1 base64 JSON naming the digest, the filter, the group key and the
  instance offset. A cursor that is malformed, oversized, filtered differently or
  pointed outside the report is refused as `:invalid_arguments`; one whose digest
  no longer matches the stored report is `:stale`.

  Without a `code` a page lists group headers - code, severity, stored total,
  retained count and completeness - and no samples, so a page of up to 50 groups
  stays inside the result bound however many samples each group retains. With a
  `code` it lists that code's retained samples. Instance references are
  `digest/group/index` positions, never CSV row identities: the index is the
  position in the group's own sample order, so the same instance keeps the same
  reference on every page.

  Retained context is sanitized to the file's basename, its row numbers, its
  field name and the natural ids `stopId`, `routeId`, `tripId`, `serviceId` and
  `pathwayId`. Every other key of a sample is dropped and the dropped names are
  disclosed to the caller. A retained value longer than 128 bytes is refused as
  `:too_large` rather than silently shortened, and so is a result that cannot fit
  32 KiB; both ask the caller to narrow the page instead.

  ## Explanations and inspection targets

  `explain/3` pairs the stored findings of one notice code with a compile-owned
  catalog entry. The catalog holds one verified rule for one captured validator
  version - v8.0.1 `missing_required_field` - with its meaning paraphrased and
  its pinned upstream source named. A run of another version, or another code,
  discloses unavailable documentation and keeps the run's real findings. No
  documentation is fetched at runtime, and the catalog's declared severity never
  replaces the severity the stored report actually carried.

  `locate/3` resolves one instance reference to the current records it names. A
  natural key is resolved inside the scope's organization and version with a
  bounded two-row read, so a duplicated key resolves to nothing rather than to
  an arbitrary row; a `tripId` resolves to its unique current trip and then to
  that trip's unique route. A CSV row number is not a record identity and never
  resolves, and a pathway id has no typed destination in this slice, so both stay
  as evidence with a stated reason. Nothing here transfers correction authority:
  the result is a list of typed current targets or a reason, never a change.

  ## Native export readiness

  `readiness/4` describes one native export selection inside the same scope. It
  resolves the requested type against the organization's product surfaces, then
  reads the current export defaults, the native preflight totals
  (`GtfsPlanner.Gtfs.Export.Preflight.inspect_summary/3`) and the version's last
  five completed MobilityData checks as one read-only repeatable-read snapshot,
  admitted after the membership and the version were resolved.

  `relationship` is the honest answer to "were these exact bytes checked?":

    * `checked` needs a ready, unexpired selected artifact whose known SHA-256
      equals the digest a completed check recorded *and* whose durable profile
      equals that check's recorded profile, or a completed native review of that
      export run's slot that recorded the same SHA-256. Nothing else is
      evidence of it;
    * `different_bytes` is a known matching profile with different bytes;
    * `different_profile` is a known check profile that is not this artifact's;
    * `unknown` is missing or unreadable provenance, a nil digest, a nil
      profile or no completed check at all;
    * `unavailable` is no artifact this scope may name.

  A shared version and a shared timestamp never make two builds equal, and a
  matching digest proves byte identity only: it says nothing about whether the
  feed is current or whether the check found errors, so `currentness` is always
  `"unknown"` (there is no native feed revision to compare) and
  `publication_status` is always `"unsupported"`. Flex is chosen explicitly as
  its own artifact and profile, never as the primary one.
  """

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.Export.Preflight
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun
  alias GtfsPlannerWeb.ProductSurfaces

  import Ecto.Query

  # One verified rule for one captured validator version. The paraphrase is our
  # own wording and the source is the pinned upstream file it was read from; a
  # rule may only be added here with its own pinned source and captured-version
  # coverage, and nothing is ever retrieved at runtime.
  @notice_catalog %{
    {"8.0.1", "missing_required_field"} => %{
      summary:
        "A field the specification requires for this record is present in the " <>
          "file but its value is empty, so the record cannot be read as written. " <>
          "The notice names the file, the CSV row and the field name, which is " <>
          "where to fill the value in the source feed.",
      evidence_fields: ["filename", "csvRowNumber", "fieldName"],
      declared_severity: "ERROR",
      source_url:
        "https://github.com/MobilityData/gtfs-validator/blob/v8.0.1/core/src/" <>
          "main/java/org/mobilitydata/gtfsvalidator/notice/MissingRequiredFieldNotice.java"
    }
  }

  @run_types ["mobility_data", "mobility_data_flex"]
  @engines [nil, "mobility_data"]
  @schema_versions [nil, 1]
  @known_severities ["ERROR", "WARNING", "INFO"]

  # The native export types, the shapes a stored or computed export profile may
  # take, and the number of completed checks a readiness read compares.
  @export_types [:full, :pathways, :operations]
  @artifact_kinds [:primary, :flex]
  @profile_export_types ["full", "pathways", "operations"]
  @profile_artifact_kinds ["primary", "flex"]
  @profile_estimate_methods [nil, "distance", "even"]
  @profile_keys [:schema_version, :export_type, :include_flex, :artifact_kind, :estimate_method]
  @recent_check_limit 5

  @default_group_limit 20
  @max_group_limit 50
  @default_instance_limit 50
  @max_instance_limit 100
  @max_cursor_bytes 1024
  @cursor_version 1
  @max_result_bytes 32_768
  @max_value_bytes 128

  @row_keys ~w(csvRowNumber rowNumber)
  @id_keys ~w(stopId routeId tripId serviceId pathwayId)
  # Every natural key but the pathway, which has no typed destination here.
  @locatable_keys ~w(stopId routeId tripId serviceId)
  @allowed_context_keys ["filename" | @row_keys ++ ["fieldName"] ++ @id_keys]

  @typedoc "One current record a stored instance names, typed for a host link."
  @type target :: %{kind: String.t(), id: String.t(), label: String.t() | nil}

  @typedoc "One stored notice code with its actual evidence and pinned documentation."
  @type explanation :: %{
          digest: String.t(),
          code: String.t(),
          validator_version: String.t() | nil,
          documentation: %{
            status: String.t(),
            reason: String.t() | nil,
            summary: String.t() | nil,
            source_url: String.t() | nil,
            evidence_fields: [String.t()],
            declared_severity: String.t() | nil
          },
          findings: %{
            severities: %{optional(String.t()) => non_neg_integer()},
            total_instances: non_neg_integer(),
            retained_instances: non_neg_integer(),
            completeness: String.t()
          }
        }

  @typedoc "One instance's current records, or the reason it names none."
  @type location :: %{
          ref: String.t(),
          digest: String.t(),
          context: %{optional(String.t()) => String.t() | integer()},
          excluded_keys: [String.t()],
          targets: [target()],
          unresolved: [%{reason: String.t(), field: String.t() | nil, value: String.t() | nil}]
        }

  @typedoc "One bounded page of a scoped completed validation report."
  @type report :: %{
          digest: String.t(),
          groups: [group()],
          totals_by_severity: %{optional(String.t()) => non_neg_integer()},
          total_instances: non_neg_integer(),
          retained_instances: non_neg_integer(),
          completeness: String.t(),
          exclusions: [%{reason: String.t(), count: non_neg_integer()}],
          next_cursor: String.t() | nil
        }

  @typedoc "One code/severity group with the instances returned on this page."
  @type group :: %{
          key: String.t(),
          code: String.t(),
          severity: String.t(),
          total_instances: non_neg_integer() | nil,
          retained_instances: non_neg_integer(),
          instance_offset: non_neg_integer(),
          completeness: String.t(),
          instances: [instance()]
        }

  @typedoc "One retained sample, addressed by its stable position in the report."
  @type instance :: %{
          ref: String.t(),
          context: %{optional(String.t()) => String.t() | integer()},
          excluded_keys: [String.t()]
        }

  @typedoc "One export profile with atom keys, whether it was just computed or read back from jsonb."
  @type export_profile :: %{
          required(:schema_version) => 1,
          required(:export_type) => String.t(),
          required(:include_flex) => boolean(),
          required(:artifact_kind) => String.t(),
          required(:estimate_method) => String.t() | nil
        }

  @typedoc "Whether these exact artifact bytes were the ones a check actually read."
  @type relationship ::
          String.t()

  @typedoc "The scoped readiness of one native export selection."
  @type readiness_result :: %{
          required(:export_type) => atom(),
          required(:profile) => export_profile(),
          required(:product_visibility) => %{
            required(:export_type) => String.t(),
            required(:flex) => boolean(),
            required(:operations_export) => boolean()
          },
          required(:preflight) => [map()],
          required(:recent_checks) => [map()],
          required(:selected_artifact) => map() | nil,
          required(:relationship) => relationship(),
          required(:digest) => String.t() | nil,
          required(:currentness) => String.t(),
          required(:publication_status) => String.t()
        }

  @doc """
  Returns one bounded page of a scoped completed validation report.

  `args` accepts `run_id` (required), `code`, `severity`, `limit`, `cursor` and
  `digest`. Without a `code` the page walks groups (limit 20, maximum 50); with
  one it walks that code's retained instances (limit 50, maximum 100). A
  continuation must present the `digest` the first page returned.
  """
  @spec findings(Scope.t(), map()) :: {:ok, report()} | {:error, atom()}
  def findings(%Scope{} = scope, args) when is_map(args) do
    with :ok <- authorize(scope),
         {:ok, request} <- parse_request(args),
         {:ok, run} <- fetch_run(scope, request),
         {:ok, source} <- read_source(run) do
      paginate(source, request)
    end
  end

  def findings(_scope, _args), do: {:error, :invalid_arguments}

  @doc """
  Returns the bounded explanation of one stored notice code.

  The run is resolved and read exactly as `findings/2` does, so the explanation
  describes the same scoped report and the same digest. Documentation comes from
  the compile-owned catalog and is offered only for the captured version and code
  it was verified against; any other version or code returns
  `status: "unavailable"` beside the run's real findings, which are never
  restated or replaced by the catalog.
  """
  @spec explain(Scope.t(), String.t(), String.t()) :: {:ok, explanation()} | {:error, atom()}
  def explain(%Scope{} = scope, run_ref, code)
      when is_binary(run_ref) and run_ref != "" and is_binary(code) and code != "" do
    with :ok <- authorize(scope),
         {:ok, request} <- run_request(run_ref),
         {:ok, run} <- fetch_run(scope, request),
         {:ok, source} <- read_source(run) do
      bounded(explanation(run, source, code))
    end
  end

  def explain(_scope, _run_ref, _code), do: {:error, :invalid_arguments}

  @doc """
  Resolves one instance reference to the current records it names.

  The reference is the stable `digest/group/index` position `findings/2` returns,
  so a reference from another report is stale here rather than resolved. Each
  natural key is read inside the scope's organization and version with a bounded
  two-row query: exactly one row resolves, none or several do not. A CSV row
  number never resolves, and a pathway id has no typed destination, so both are
  reported as unresolved with a reason beside the sample's own context.
  """
  @spec locate(Scope.t(), String.t(), String.t()) :: {:ok, location()} | {:error, atom()}
  def locate(%Scope{} = scope, run_ref, instance_ref)
      when is_binary(run_ref) and run_ref != "" and is_binary(instance_ref) and
             instance_ref != "" do
    with :ok <- authorize(scope),
         {:ok, request} <- run_request(run_ref),
         {:ok, run} <- fetch_run(scope, request),
         {:ok, source} <- read_source(run),
         {:ok, position} <- parse_instance_ref(source.digest, instance_ref),
         {:ok, kept, excluded} <- instance_context(source, position) do
      bounded(location(scope, source, position, kept, excluded))
    end
  end

  def locate(_scope, _run_ref, _instance_ref), do: {:error, :invalid_arguments}

  @doc "The number of completed checks a readiness read lists; more may exist."
  @spec recent_check_limit() :: pos_integer()
  def recent_check_limit, do: @recent_check_limit

  @doc """
  Returns the scoped readiness of one native export selection.

  `export_type` is `:full`, `:pathways` or `:operations` (the `stations` alias
  names the pathways files); a type the organization's product hides is
  unavailable. `export_ref` optionally names one of this scope's export runs;
  without one the version's latest run of that type is used. `artifact` names
  which of that run's artifacts is meant - `:primary` by default, `:flex` for
  the companion - so a Flex digest is never read as the primary one's.

  The result names the profile the *current defaults* would build, the
  preflight totals for that type, the version's last five completed
  MobilityData checks, the artifact this selection would download with its own
  durable profile, and `relationship` - the only question of which is whether
  those exact bytes were checked. Nothing here starts, repairs or publishes
  anything, and no artifact path, log or actor field is returned.
  """
  @spec readiness(Scope.t(), atom() | String.t(), String.t() | nil, :primary | :flex) ::
          {:ok, readiness_result()} | {:error, atom()}
  def readiness(scope, export_type, export_ref \\ nil, artifact \\ :primary)

  def readiness(%Scope{} = scope, export_type, export_ref, artifact)
      when artifact in @artifact_kinds do
    with :ok <- authorize(scope),
         :ok <- authorize_context(scope),
         {:ok, type} <- parse_export_type(export_type),
         {:ok, reference} <- parse_export_ref(export_ref),
         {:ok, organization} <- current_organization(scope),
         :ok <- require_visible_export_type(organization, type) do
      export_snapshot(scope, organization, type, reference, artifact)
    end
  end

  def readiness(_scope, _export_type, _export_ref, _artifact), do: {:error, :invalid_arguments}

  # -- native export readiness ------------------------------------------------

  # The membership and the version were resolved above; these reads then see one
  # committed snapshot, so the defaults, the preflight totals and the export
  # being inspected cannot come from three different points in time. The
  # isolation is set by the service-query snapshot boundary as the first
  # statement of the transaction; Postgrex ignores an `:isolation` option.
  defp export_snapshot(scope, organization, type, reference, artifact) do
    case Repo.transaction(fn ->
           snapshot_module().begin_read()
           readiness_snapshot(scope, organization, type, reference, artifact)
         end) do
      {:ok, snapshot} -> bounded(snapshot)
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_module do
    Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot, Snapshot.Repo)
  end

  defp readiness_snapshot(scope, organization, type, reference, artifact_kind) do
    case current_export_run(scope, type, reference) do
      {:ok, run} ->
        checks = recent_checks(scope)
        artifact = selected_artifact(run, type, artifact_kind)
        reviewed? = artifact_reviewed?(scope, artifact)

        %{
          export_type: type,
          profile: current_profile(organization, type),
          product_visibility: product_visibility(organization, type),
          preflight:
            Preflight.inspect_summary(scope.organization_id, scope.gtfs_version_id, type),
          recent_checks: checks,
          selected_artifact: artifact,
          relationship: relationship(artifact, checks, reviewed?),
          digest: artifact_digest(artifact),
          currentness: "unknown",
          publication_status: "unsupported"
        }

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # A run named by a reference must be this scope's own run of the requested
  # type; a reference to another version's or another type's run is unavailable
  # rather than a different export read under this selection.
  defp current_export_run(%Scope{} = scope, type, nil) do
    {:ok, ExportRuns.latest_for_version(scope.organization_id, scope.gtfs_version_id, type)}
  end

  defp current_export_run(%Scope{} = scope, type, reference) do
    case ExportRuns.get_for_version(scope.organization_id, scope.gtfs_version_id, reference) do
      %Run{export_type: ^type} = run -> {:ok, run}
      _foreign -> {:error, :unavailable}
    end
  end

  # The artifact is the one the caller named. A run that never published that
  # artifact has no selected artifact rather than the other one.
  defp selected_artifact(nil, _type, _kind), do: nil

  defp selected_artifact(%Run{} = run, type, kind) do
    with true <- run.export_type == type,
         evidence when not is_nil(evidence) <- ExportRuns.artifact_evidence(run, kind) do
      %{
        artifact_kind: kind,
        run_id: run.id,
        export_type: run.export_type,
        filename: evidence.filename,
        sha256: evidence.sha256,
        size_bytes: evidence.size_bytes,
        expires_at: evidence.expires_at,
        available: evidence.available,
        profile: durable_profile(run, kind),
        stored_options: %{
          include_flex: run.include_flex,
          estimate_missing_times: run.estimate_missing_times,
          estimate_method: run.estimate_method && Atom.to_string(run.estimate_method)
        }
      }
    else
      _not_this_selection -> nil
    end
  end

  # What this run built, not what the organization would build now. A companion
  # Flex file never changes the primary artifact's profile, and a Flex artifact
  # is always the full export's companion rather than an export of its own.
  defp durable_profile(%Run{} = run, :primary) do
    %{
      schema_version: 1,
      export_type: to_string(run.export_type),
      include_flex: false,
      artifact_kind: "primary",
      estimate_method: stored_estimate_method(run)
    }
  end

  defp durable_profile(%Run{} = run, :flex) do
    %{
      schema_version: 1,
      export_type: "full",
      include_flex: true,
      artifact_kind: "flex",
      estimate_method: stored_estimate_method(run)
    }
  end

  defp stored_estimate_method(%Run{} = run) do
    if run.estimate_missing_times,
      do: run.estimate_method && Atom.to_string(run.estimate_method),
      else: nil
  end

  defp artifact_digest(nil), do: nil

  defp artifact_digest(%{available: true, sha256: sha256}) when is_binary(sha256), do: sha256

  defp artifact_digest(_artifact), do: nil

  # `checked` is a conjunction, and every missing half of it falls back to a
  # weaker answer rather than to the strong one: no artifact is `unavailable`,
  # no check that recorded a known profile at all is `unknown`, a known profile
  # that is not this artifact's is `different_profile`, and a matching profile
  # with different bytes is `different_bytes`.
  defp relationship(nil, _checks, _reviewed?), do: "unavailable"

  # A completed review of this very artifact is byte-exact by construction.
  defp relationship(%{available: true}, _checks, true), do: "checked"

  defp relationship(%{available: true} = artifact, checks, false) do
    known = Enum.filter(checks, &(&1.checked_profile && is_binary(&1.checked_digest)))
    comparable = Enum.filter(known, &same_profile?(&1.checked_profile, artifact.profile))

    cond do
      known == [] -> "unknown"
      comparable == [] -> "different_profile"
      Enum.any?(comparable, &same_bytes?(&1, artifact)) -> "checked"
      true -> "different_bytes"
    end
  end

  defp relationship(_artifact, _checks, _reviewed?), do: "unavailable"

  # A native artifact review pins the selected export's file, and the validator
  # re-hashes it against the digest the review recorded before it reads a byte,
  # so a completed review of this run's slot with this digest read these bytes.
  defp artifact_reviewed?(%Scope{} = scope, %{available: true, sha256: sha256} = artifact)
       when is_binary(sha256) do
    slot = if artifact.artifact_kind == :flex, do: :flex, else: :main

    Repo.exists?(
      from(run in ValidationRun,
        where: run.organization_id == ^scope.organization_id,
        where: run.gtfs_version_id == ^scope.gtfs_version_id,
        where: run.run_type == "mobility_data_artifact" and run.status == "completed",
        where: run.artifact_export_run_id == ^artifact.run_id,
        where: run.artifact_slot == ^slot and run.artifact_sha256 == ^sha256
      )
    )
  end

  defp artifact_reviewed?(_scope, _artifact), do: false

  defp same_bytes?(check, artifact),
    do: is_binary(check.checked_digest) and check.checked_digest == artifact.sha256

  # `nil` is not a known profile: a check that recorded no profile never
  # matches one, in either direction.
  defp same_profile?(nil, _profile), do: false
  defp same_profile?(_profile, nil), do: false
  defp same_profile?(profile, other), do: profile == other

  defp recent_checks(%Scope{} = scope) do
    from(run in ValidationRun,
      where: run.organization_id == ^scope.organization_id,
      where: run.gtfs_version_id == ^scope.gtfs_version_id,
      where: run.run_type in ^@run_types and run.status == "completed",
      order_by: [desc: run.started_at, desc: run.inserted_at],
      limit: @recent_check_limit
    )
    |> Repo.all()
    |> Enum.map(&recent_check/1)
  end

  # A check discloses what ran and what it found. Its own provenance is kept in
  # the known-profile form only: an unreadable or partial stored profile is
  # unknown here rather than repaired.
  defp recent_check(%ValidationRun{} = run) do
    %{
      id: run.id,
      run_type: run.run_type,
      started_at: run.started_at,
      completed_at: run.completed_at,
      validator_version: run.validator_version,
      errors: run.errors_count,
      warnings: run.warnings_count,
      infos: run.infos_count,
      checked_digest: run.checked_zip_sha256,
      checked_profile: known_profile(run.checked_export_profile)
    }
  end

  defp known_profile(profile) when is_map(profile) do
    read = &profile_value(profile, &1)
    export_type = read.(:export_type)
    artifact_kind = read.(:artifact_kind)
    include_flex = read.(:include_flex)
    estimate_method = read.(:estimate_method)

    # All five keys must be present: a profile that omits `estimate_method` is
    # a partial profile, not one that never estimates.
    if Enum.all?(@profile_keys, &profile_key?(profile, &1)) and read.(:schema_version) == 1 and
         export_type in @profile_export_types and artifact_kind in @profile_artifact_kinds and
         is_boolean(include_flex) and
         (is_nil(estimate_method) or estimate_method in @profile_estimate_methods) do
      %{
        schema_version: 1,
        export_type: export_type,
        include_flex: include_flex,
        artifact_kind: artifact_kind,
        estimate_method: estimate_method
      }
    end
  end

  defp known_profile(_profile), do: nil

  # A stored profile comes back from jsonb with string keys and a freshly built
  # one with atom keys; a key that is present but `false` or `nil` is read as
  # itself rather than as an absent key.
  defp profile_key?(profile, key),
    do: Map.has_key?(profile, key) or Map.has_key?(profile, Atom.to_string(key))

  defp profile_value(profile, key) do
    case Map.fetch(profile, key) do
      {:ok, value} -> value
      :error -> Map.get(profile, Atom.to_string(key))
    end
  end

  # The profile the organization's current defaults would build for this type.
  # It is reported beside the artifact's own stored profile, never instead of
  # it: they disagree whenever the defaults changed after the export was built.
  defp current_profile(organization, type) do
    defaults = ExportDefaults.get(organization.id)

    %{
      schema_version: 1,
      export_type: to_string(type),
      include_flex:
        defaults.include_flex and type != :pathways and
          ProductSurfaces.visible?(organization, :flex),
      artifact_kind: "primary",
      estimate_method: defaults_estimate_method(defaults)
    }
  end

  defp defaults_estimate_method(defaults) do
    if defaults.estimate_missing_times,
      do: defaults.estimate_method && Atom.to_string(defaults.estimate_method),
      else: nil
  end

  defp product_visibility(organization, type) do
    %{
      export_type: to_string(type),
      flex: ProductSurfaces.visible?(organization, :flex),
      operations_export: ProductSurfaces.visible?(organization, :operations_export)
    }
  end

  defp current_organization(%Scope{} = scope) do
    case Organizations.get_organization(scope.organization_id) do
      %Organization{} = organization -> {:ok, organization}
      nil -> {:error, :unavailable}
    end
  end

  defp require_visible_export_type(organization, :operations) do
    if ProductSurfaces.visible?(organization, :operations_export),
      do: :ok,
      else: {:error, :unavailable}
  end

  defp require_visible_export_type(_organization, _type), do: :ok

  # The Stations export is the pathways file under the product's own name, so
  # the alias resolves to the one export type it can produce.
  defp parse_export_type("stations"), do: {:ok, :pathways}
  defp parse_export_type(type) when type in @export_types, do: {:ok, type}

  defp parse_export_type(type) when is_binary(type) do
    case Enum.find(@export_types, &(Atom.to_string(&1) == type)) do
      nil -> {:error, :invalid_arguments}
      resolved -> {:ok, resolved}
    end
  end

  defp parse_export_type(_type), do: {:error, :invalid_arguments}

  defp parse_export_ref(nil), do: {:ok, nil}
  defp parse_export_ref(""), do: {:ok, nil}

  defp parse_export_ref(reference) when is_binary(reference) do
    case Ecto.UUID.cast(reference) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :unavailable}
    end
  end

  defp parse_export_ref(_reference), do: {:error, :invalid_arguments}

  # A membership withdrawn mid-conversation is not a different answer, so a
  # refused membership and an unknown run are one indistinguishable result.
  defp authorize(%Scope{} = scope) do
    case Scope.authorize(scope) do
      :ok -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp fetch_run(%Scope{} = scope, request) do
    Validations.fetch_scoped_run(
      scope.organization_id,
      scope.gtfs_version_id,
      request.run_id
    )
  end

  # The membership and the version a readiness read runs against are resolved
  # before its snapshot opens, so a withdrawn membership or a version this
  # organization can no longer resolve is one indistinguishable refusal.
  defp authorize_context(%Scope{} = scope) do
    case Scope.authorized_context(scope) do
      :ok -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  # -- the stored report ------------------------------------------------------

  defp read_source(%ValidationRun{} = run) do
    with :ok <- supported_run(run),
         {:ok, groups} <- normalize(run.result_json) do
      {:ok, %{digest: digest(run, groups), groups: groups}}
    end
  end

  defp supported_run(%ValidationRun{} = run) do
    if run.run_type in @run_types and run.status == "completed" and
         run.engine in @engines and run.result_schema_version in @schema_versions do
      :ok
    else
      {:error, :unavailable}
    end
  end

  defp normalize(%{"notices" => notices}) when is_list(notices) do
    notices
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case stored_group(entry) do
        {:ok, group} -> {:cont, {:ok, [group | acc]}}
        {:error, _reason} -> {:halt, {:error, :unavailable}}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> merge_groups() |> index_instances()}
      {:error, _reason} = error -> error
    end
  end

  defp normalize(_result_json), do: {:error, :unavailable}

  # One stored group, whichever of the three shapes it was written in.
  defp stored_group(entry) when is_map(entry) do
    with {:ok, code} <- stored_code(entry),
         {:ok, severity} <- stored_severity(entry) do
      group_from(entry, code, severity)
    end
  end

  defp stored_group(_entry), do: {:error, :unavailable}

  defp group_from(entry, code, severity) do
    case Map.get(entry, "notices") do
      notices when is_list(notices) ->
        if wrapper?(notices) do
          embedded_group(notices, code, severity)
        else
          canonical_group(entry, notices, code, severity)
        end

      _other ->
        # The flat form stores one notice per entry, so the entry itself is the
        # only instance the report holds.
        build_group(code, severity, 1, [entry])
    end
  end

  # A wrapper holds the validator's own NoticeReport, which carries the true
  # count; the wrapper's own total and its length are its own bookkeeping.
  defp wrapper?([]), do: false

  defp wrapper?(notices) do
    Enum.all?(notices, fn notice ->
      is_map(notice) and
        (Map.has_key?(notice, "totalNotices") or Map.has_key?(notice, "sampleNotices"))
    end)
  end

  defp embedded_group(notices, code, severity) do
    Enum.reduce_while(notices, {:ok, {0, []}}, fn
      %{} = notice, {:ok, {total, samples}} ->
        found = embedded_samples(notice)

        if Enum.all?(found, &is_map/1) do
          {:cont, {:ok, {add_total(total, embedded_total(notice)), samples ++ found}}}
        else
          {:halt, {:error, :unavailable}}
        end

      _notice, {:error, _reason} = error ->
        {:halt, error}
    end)
    |> case do
      {:ok, {total, samples}} -> build_group(code, severity, total, samples)
      {:error, _reason} = error -> error
    end
  end

  defp canonical_group(entry, notices, code, severity) do
    if Enum.all?(notices, &is_map/1) do
      case stored_total(entry) do
        {:ok, total} -> build_group(code, severity, total, notices)
        {:error, :not_counted} -> build_group(code, severity, nil, notices)
      end
    else
      {:error, :unavailable}
    end
  end

  defp add_total(_acc, {:error, :not_counted}), do: nil
  defp add_total(nil, {:ok, total}), do: total
  defp add_total(acc, {:ok, total}), do: acc + total

  defp stored_total(%{"total_notices" => total}) when is_integer(total) and total >= 0,
    do: {:ok, total}

  defp stored_total(_entry), do: {:error, :not_counted}

  defp embedded_total(%{"totalNotices" => total}) when is_integer(total) and total >= 0,
    do: {:ok, total}

  defp embedded_total(_notice), do: {:error, :not_counted}

  defp embedded_samples(%{"sampleNotices" => samples}) when is_list(samples), do: samples
  defp embedded_samples(_notice), do: []

  defp stored_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp stored_code(_entry), do: {:error, :unavailable}

  defp stored_severity(%{"severity" => severity}) when is_binary(severity), do: {:ok, severity}
  defp stored_severity(_entry), do: {:error, :unavailable}

  # A retained count above its own stored total is an unreadable report, not a
  # clean one; neither number is adjusted to make it fit. An embedded report
  # without a count leaves the total unknown, because the samples never stand in
  # for the number they were cut from.
  defp build_group(code, severity, total, samples) when is_integer(total) do
    if total >= length(samples) do
      {:ok, counted_group(code, severity, total, samples)}
    else
      {:error, {:retained_exceeds_total, code, severity}}
    end
  end

  defp build_group(code, severity, nil, samples),
    do: {:ok, counted_group(code, severity, nil, samples)}

  defp counted_group(code, severity, total, samples) do
    %{
      key: group_key(code, severity),
      code: code,
      severity: severity,
      total: total,
      retained: length(samples),
      completeness: group_completeness(total, length(samples)),
      raw: samples
    }
  end

  defp group_completeness(nil, _retained), do: "unknown"
  defp group_completeness(total, retained) when retained == total, do: "complete"
  defp group_completeness(_total, _retained), do: "sampled"

  # Repeated groups of one code and severity describe one group: the totals add
  # and the samples keep their stored order, exactly as the parser left them.
  defp merge_groups(groups) do
    groups
    |> Enum.reduce(%{}, fn group, acc ->
      Map.update(acc, group.key, group, fn existing ->
        total = add_known(existing.total, group.total)
        retained = existing.retained + group.retained

        existing
        |> Map.put(:total, total)
        |> Map.put(:raw, existing.raw ++ group.raw)
        |> Map.put(:retained, retained)
        |> Map.put(:completeness, group_completeness(total, retained))
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.code, &1.severity})
  end

  defp add_known(nil, _total), do: nil
  defp add_known(_total, nil), do: nil
  defp add_known(left, right), do: left + right

  # The instance index is the position in the group's own sample order, so it is
  # the same reference on every page of the same report.
  defp index_instances(groups) do
    Enum.map(groups, fn group ->
      instances =
        group.raw
        |> Enum.with_index()
        |> Enum.map(fn {raw, index} ->
          %{ref: "#{group.key}/#{index}", raw: raw, index: index}
        end)

      Map.put(group, :instances, instances)
    end)
  end

  defp group_key(code, severity), do: "#{code}|#{severity}"

  # -- digest -----------------------------------------------------------------

  # The digest identifies the content and provenance this report was read from,
  # never a chronology or a revision. Paging and filtering are applied after it.
  defp digest(%ValidationRun{} = run, groups) do
    %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      run_id: run.id,
      run_type: run.run_type,
      checked_zip_sha256: run.checked_zip_sha256,
      checked_export_profile: run.checked_export_profile,
      validator_version: run.validator_version,
      groups: Enum.map(groups, &digest_group/1)
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp digest_group(group) do
    [group.code, group.severity, group.total, Enum.map(group.instances, & &1.raw)]
  end

  # -- paging -----------------------------------------------------------------

  defp paginate(%{digest: digest, groups: groups}, request) do
    selected = filter_groups(groups, request)

    with {:ok, position} <- start_position(selected, digest, request) do
      {page, rest} = take_page(selected, position, request)

      with {:ok, presented} <- present_page(page, digest) do
        bounded(build_report(groups, presented, digest, rest, request))
      end
    end
  end

  # Without a code filter the page walks groups; with one it walks that code's
  # retained instances, so a group of 170 findings returns its stored samples
  # rather than instances the validator never recorded.
  defp entries(selected, %{code: nil}), do: selected

  defp entries(selected, _request) do
    Enum.flat_map(selected, fn group -> Enum.map(group.instances, &{group, &1}) end)
  end

  defp start_position(selected, digest, request) do
    case request.cursor do
      nil -> first_position(selected, digest, request)
      cursor -> resume_position(selected, digest, request, cursor)
    end
  end

  # A presented digest that no longer matches the stored report is stale rather
  # than a silent restart at the beginning.
  defp first_position(_selected, digest, request) do
    case request.digest do
      nil -> {:ok, 0}
      ^digest -> {:ok, 0}
      _other -> {:error, :stale}
    end
  end

  # A continuation names the report it continues, so the caller must present
  # that digest and the same filter; a cursor from another report or another
  # filter cannot be applied to this one.
  defp resume_position(selected, digest, request, cursor) do
    cond do
      is_nil(request.digest) -> {:error, :invalid_arguments}
      request.digest != cursor.digest -> {:error, :invalid_arguments}
      cursor.filter != request.filter -> {:error, :invalid_arguments}
      cursor.digest != digest -> {:error, :stale}
      true -> cursor_position(selected, cursor, request)
    end
  end

  # The cursor names the group it resumes inside. In group mode that group is the
  # first group of the next page and no instance offset applies; in instance
  # mode the offset says how far into that group's own samples to start. An
  # offset past the retained samples is refused.
  defp cursor_position(selected, %{group: key, offset: offset}, request) do
    case walk_groups(selected, key, 0, 0) do
      nil ->
        {:error, :invalid_arguments}

      {groups_before, retained_before, group} ->
        cond do
          request.code && offset > group.retained -> {:error, :invalid_arguments}
          is_nil(request.code) && offset != 0 -> {:error, :invalid_arguments}
          # Group mode's entries are the groups themselves, so the position is
          # the number of groups before the named one; instance mode's entries
          # are every retained sample, so it is the samples before that group
          # plus the offset.
          is_nil(request.code) -> {:ok, groups_before}
          true -> {:ok, retained_before + offset}
        end
    end
  end

  defp walk_groups([], _key, _groups, _retained), do: nil

  defp walk_groups([group | rest], key, groups, retained) do
    if group.key == key do
      {groups, retained, group}
    else
      walk_groups(rest, key, groups + 1, retained + group.retained)
    end
  end

  defp take_page(selected, position, request) do
    all = entries(selected, request)
    limit = request.limit

    {Enum.slice(all, position, limit), Enum.drop(all, position + limit)}
  end

  defp build_report(groups, presented, digest, rest, request) do
    totals = totals(groups)

    %{
      digest: digest,
      groups: presented,
      totals_by_severity: totals.totals_by_severity,
      total_instances: totals.total_instances,
      retained_instances: totals.retained_instances,
      completeness: completeness(groups),
      exclusions: exclusions(totals, rest, request),
      next_cursor: next_cursor(rest, digest, request)
    }
  end

  # Totals are exact for every group whose stored count could be read. A group
  # whose count is unknown is disclosed rather than counted as zero.
  defp totals(groups) do
    counted = Enum.filter(groups, &is_integer(&1.total))

    %{
      totals_by_severity: severity_totals(counted),
      total_instances: counted |> Enum.map(& &1.total) |> Enum.sum(),
      retained_instances: groups |> Enum.map(& &1.retained) |> Enum.sum(),
      sampled: Enum.count(counted, &(&1.completeness == "sampled")),
      unknown_total: length(groups) - length(counted),
      unknown_severity:
        Enum.count(counted, &(String.upcase(&1.severity) not in @known_severities))
    }
  end

  # A group is counted under the severity the validator gave it, so an unknown
  # severity stays visible and exact instead of being folded into another total.
  defp severity_totals(groups) do
    Enum.reduce(groups, %{}, fn group, acc ->
      Map.update(acc, group.severity, group.total, &(&1 + group.total))
    end)
  end

  # Completeness describes what the validator stored, not what this transport
  # page delivered: a sampled group or an unknown total is incomplete even when
  # every page has been read.
  defp completeness([]), do: "complete"

  defp completeness(groups) do
    if Enum.all?(groups, &(&1.completeness == "complete")), do: "complete", else: "incomplete"
  end

  defp exclusions(totals, rest, request) do
    []
    |> exclude("sampled_instance_groups", totals.sampled)
    |> exclude("groups_without_stored_total", totals.unknown_total)
    |> exclude("unknown_severity_groups", totals.unknown_severity)
    |> exclude(unread_reason(request), length(rest))
  end

  # A next cursor is the honest statement that more of the report exists, so the
  # unread remainder is disclosed by name rather than left to be guessed.
  defp unread_reason(%{code: nil}), do: "groups_not_on_this_page"
  defp unread_reason(_request), do: "instances_not_on_this_page"

  defp exclude(exclusions, _reason, count) when count <= 0, do: exclusions

  defp exclude(exclusions, reason, count),
    do: exclusions ++ [%{reason: reason, count: count}]

  # -- the page ---------------------------------------------------------------

  # In group mode each entry is a whole group, presented without its samples; in
  # instance mode it is one retained sample under its group.
  defp present_page([], _digest), do: {:ok, []}

  defp present_page(entries, digest) do
    entries
    |> Enum.group_by(&entry_key/1)
    |> Enum.sort_by(fn {key, _values} -> key end)
    |> Enum.reduce_while({:ok, []}, fn {_key, values}, {:ok, acc} ->
      case present_group(values, digest) do
        {:ok, group} -> {:cont, {:ok, acc ++ [group]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp entry_key(group) when is_map(group), do: {group.code, group.severity}
  defp entry_key({group, _instance}), do: {group.code, group.severity}

  # A group page is the group's header only: its retained samples are what the
  # code-filtered page walks, so one page of many large groups can never outgrow
  # the result bound or fail on a sample that was not asked for.
  defp present_group([group], _digest) when is_map(group) do
    {:ok,
     %{
       key: group.key,
       code: group.code,
       severity: group.severity,
       total_instances: group.total,
       retained_instances: group.retained,
       instance_offset: 0,
       completeness: group.completeness,
       instances: []
     }}
  end

  defp present_group(entries, digest) do
    [{group, first} | rest] = entries

    with {:ok, instances} <- present_instances([first | Enum.map(rest, &elem(&1, 1))], digest) do
      {:ok,
       %{
         key: group.key,
         code: group.code,
         severity: group.severity,
         total_instances: group.total,
         retained_instances: group.retained,
         instance_offset: first.index,
         completeness: group.completeness,
         instances: instances
       }}
    end
  end

  defp present_instances([], _digest), do: {:ok, []}

  defp present_instances([instance | rest], digest) do
    with {:ok, context, excluded} <- sanitize(instance.raw),
         {:ok, presented} <- present_instances(rest, digest) do
      {:ok,
       [
         %{
           ref: "#{digest}/#{instance.ref}",
           context: context,
           excluded_keys: excluded
         }
         | presented
       ]}
    end
  end

  # The next cursor resumes at the first entry this page did not return, so it is
  # exactly the position after the page rather than a re-read of its last group.
  defp next_cursor([], _digest, _request), do: nil

  defp next_cursor([entry | _rest], digest, request) do
    fields =
      case entry do
        group when is_map(group) -> %{group: group.key, offset: 0}
        {group, instance} -> %{group: group.key, offset: instance.index}
      end

    encode_cursor(fields, digest, request.filter)
  end

  defp encode_cursor(fields, digest, filter) do
    payload = %{
      "v" => @cursor_version,
      "digest" => digest,
      "filter" => filter,
      "group" => fields.group,
      "offset" => fields.offset
    }

    payload |> Jason.encode!() |> Base.url_encode64()
  end

  # -- filters ----------------------------------------------------------------

  defp filter_groups(groups, request) do
    Enum.filter(groups, fn group ->
      matches_code?(group.code, request.code) and
        matches_severity?(group.severity, request.severity)
    end)
  end

  defp matches_code?(_code, nil), do: true
  defp matches_code?(code, code), do: true
  defp matches_code?(_code, _wanted), do: false

  # ERROR/WARNING/INFO match in either case. Any other value is compared
  # exactly, so an unknown severity is filterable without being remapped.
  defp matches_severity?(_severity, nil), do: true

  defp matches_severity?(severity, wanted) do
    upcased = String.upcase(wanted)

    if upcased in @known_severities do
      String.upcase(severity) == upcased
    else
      severity == wanted
    end
  end

  # -- sanitization -----------------------------------------------------------

  # Only the file's basename, its rows, its field and the named natural ids
  # leave this module. Everything else a sample carries - messages, internal
  # context, host paths - is dropped, and the dropped names are disclosed.
  defp sanitize(raw) when is_map(raw) do
    {kept, oversized} =
      Enum.reduce(@allowed_context_keys, {%{}, nil}, fn key, {kept, oversized} ->
        case sanitize_value(key, Map.get(raw, key)) do
          {:ok, value} -> {Map.put(kept, key, value), oversized}
          {:error, :too_large} -> {kept, key}
          :omit -> {kept, oversized}
        end
      end)

    case oversized do
      nil -> {:ok, kept, unknown_keys(raw)}
      _key -> {:error, :too_large}
    end
  end

  defp sanitize(_raw), do: {:error, :too_large}

  defp sanitize_value("filename", value) when is_binary(value),
    do: bounded_value(Path.basename(value))

  defp sanitize_value(key, value) when key in @row_keys and is_integer(value), do: {:ok, value}

  defp sanitize_value(key, value) when key in ["fieldName" | @id_keys] and is_binary(value),
    do: bounded_value(value)

  defp sanitize_value(_key, _value), do: :omit

  # A retained value longer than the bound is refused rather than shortened: a
  # truncated identifier is not the identifier the validator reported.
  defp bounded_value(value) do
    if byte_size(value) > @max_value_bytes, do: {:error, :too_large}, else: {:ok, value}
  end

  defp unknown_keys(raw) do
    raw |> Map.keys() |> Enum.reject(&(&1 in @allowed_context_keys)) |> Enum.sort()
  end

  # -- arguments --------------------------------------------------------------

  defp parse_request(args) do
    with {:ok, run_id} <- required_string(args, :run_id),
         {:ok, code} <- optional_string(args, :code),
         {:ok, severity} <- optional_string(args, :severity),
         {:ok, limit} <- optional_limit(args, code),
         {:ok, digest} <- optional_string(args, :digest),
         {:ok, cursor} <- decode_cursor(args) do
      {:ok,
       %{
         run_id: run_id,
         code: code,
         severity: severity,
         limit: limit,
         digest: digest,
         cursor: cursor,
         filter: %{"code" => code, "severity" => severity}
       }}
    end
  end

  defp required_string(args, key) do
    case string_arg(args, key) do
      {:ok, value} -> {:ok, value}
      :omit -> {:error, :invalid_arguments}
    end
  end

  defp optional_string(args, key) do
    case string_arg(args, key) do
      {:ok, value} -> {:ok, value}
      :omit -> {:ok, nil}
    end
  end

  defp string_arg(args, key) do
    case Map.get(args, key) || Map.get(args, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> :omit
      _other -> {:error, :invalid_arguments}
    end
  end

  defp optional_limit(args, code) do
    case Map.get(args, :limit) || Map.get(args, "limit") do
      nil ->
        {:ok, default_limit(code)}

      limit when is_integer(limit) and limit > 0 ->
        if limit <= max_limit(code), do: {:ok, limit}, else: {:error, :invalid_arguments}

      _other ->
        {:error, :invalid_arguments}
    end
  end

  defp default_limit(nil), do: @default_group_limit
  defp default_limit(_code), do: @default_instance_limit

  defp max_limit(nil), do: @max_group_limit
  defp max_limit(_code), do: @max_instance_limit

  defp decode_cursor(args) do
    case Map.get(args, :cursor) || Map.get(args, "cursor") do
      nil -> {:ok, nil}
      cursor when is_binary(cursor) -> parse_cursor(cursor)
      _other -> {:error, :invalid_arguments}
    end
  end

  defp parse_cursor(cursor) when byte_size(cursor) > @max_cursor_bytes,
    do: {:error, :invalid_arguments}

  defp parse_cursor(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, payload} <- Jason.decode(json),
         {:ok, decoded} <- cursor_payload(payload) do
      {:ok, decoded}
    else
      _other -> {:error, :invalid_arguments}
    end
  end

  defp cursor_payload(%{
         "v" => @cursor_version,
         "digest" => digest,
         "filter" => %{"code" => code, "severity" => severity},
         "group" => group,
         "offset" => offset
       })
       when is_binary(digest) and is_binary(group) and is_integer(offset) and offset >= 0 and
              (is_nil(code) or is_binary(code)) and (is_nil(severity) or is_binary(severity)) do
    {:ok,
     %{
       digest: digest,
       filter: %{"code" => code, "severity" => severity},
       group: group,
       offset: offset
     }}
  end

  defp cursor_payload(_payload), do: {:error, :invalid_arguments}

  # -- explanations ------------------------------------------------------------

  # Both new reads resolve the run through the same scoped path `findings/2`
  # uses, so an explanation or an inspection target never describes a report the
  # caller could not have paged.
  defp run_request(run_ref) do
    case parse_request(%{run_id: run_ref}) do
      {:ok, request} -> {:ok, request}
      {:error, _reason} = error -> error
    end
  end

  defp explanation(%ValidationRun{} = run, source, code) do
    groups = Enum.filter(source.groups, &(&1.code == code))
    counted = Enum.filter(groups, &is_integer(&1.total))

    %{
      digest: source.digest,
      code: code,
      validator_version: run.validator_version,
      documentation: documentation(run.validator_version, code),
      findings: %{
        severities: severity_totals(counted),
        total_instances: counted |> Enum.map(& &1.total) |> Enum.sum(),
        retained_instances: groups |> Enum.map(& &1.retained) |> Enum.sum(),
        completeness: completeness(groups)
      }
    }
  end

  # Documentation is offered only for the exact version and code it was verified
  # against. A run of another version, a code the catalog does not name, and a
  # run that recorded no version at all all read the same way: the documentation
  # is unavailable and the run's own findings stand alone beside it. The
  # catalog's declared severity is disclosure about the upstream rule, never a
  # replacement for the severity this report actually carried.
  defp documentation(validator_version, code) do
    case Map.get(@notice_catalog, {validator_version, code}) do
      nil ->
        %{
          status: "unavailable",
          reason: unavailable_reason(validator_version),
          summary: nil,
          source_url: nil,
          evidence_fields: [],
          declared_severity: nil
        }

      entry ->
        %{
          status: "available",
          reason: nil,
          summary: entry.summary,
          source_url: entry.source_url,
          evidence_fields: entry.evidence_fields,
          declared_severity: entry.declared_severity
        }
    end
  end

  defp unavailable_reason(nil), do: "validator_version_not_recorded"
  defp unavailable_reason(_validator_version), do: "not_in_catalog_for_this_version"

  # -- inspection targets -----------------------------------------------------

  # A reference is the stable `digest/group/index` position `findings/2`
  # presented. The group key is `code|severity`, so a code or an unknown
  # severity that itself contains `/` cannot be addressed and is refused. A
  # reference issued for another report is stale here rather than resolved
  # against this one.
  defp parse_instance_ref(digest, instance_ref) do
    case String.split(instance_ref, "/") do
      [ref_digest, group_key, index] -> instance_position(digest, ref_digest, group_key, index)
      _other -> {:error, :invalid_arguments}
    end
  end

  defp instance_position(digest, ref_digest, group_key, index) do
    with {:ok, index} <- instance_index(index) do
      if ref_digest == digest,
        do: {:ok, %{group_key: group_key, index: index}},
        else: {:error, :stale}
    end
  end

  defp instance_index(index) do
    case Integer.parse(index) do
      {value, ""} when value >= 0 -> {:ok, value}
      _other -> {:error, :invalid_arguments}
    end
  end

  defp instance_context(source, %{group_key: group_key, index: index}) do
    group = Enum.find(source.groups, &(&1.key == group_key))
    instance = group && Enum.find(group.instances, &(&1.index == index))

    case instance do
      %{raw: raw} -> sanitize(raw)
      nil -> {:error, :invalid_arguments}
    end
  end

  defp location(%Scope{} = scope, source, %{group_key: group_key, index: index}, kept, excluded) do
    resolutions = resolve_keys(scope, kept)

    %{
      ref: "#{source.digest}/#{group_key}/#{index}",
      digest: source.digest,
      context: kept,
      excluded_keys: excluded,
      targets: for({_key, _value, {:resolved, target}} <- resolutions, do: target),
      unresolved: unresolved(resolutions, kept)
    }
  end

  # Every natural key the sample carried is resolved independently, so a notice
  # naming both a route and a stop offers both, and one key that resolves to
  # nothing never hides another that does. One resolution answers both lists, so
  # a target and the reason beside it can never disagree.
  defp resolve_keys(%Scope{} = scope, kept) do
    Enum.flat_map(@locatable_keys, fn key ->
      case Map.get(kept, key) do
        value when is_binary(value) -> [{key, value, natural(scope, key, value)}]
        _absent -> []
      end
    end)
  end

  # A natural key that names no single current record is stated rather than
  # dropped, so the caller can say why the sample resolved to nothing.
  defp unresolved(resolutions, kept) do
    stated =
      for {key, value, {:unresolved, reason}} <- resolutions,
          do: %{reason: reason, field: key, value: value}

    case stated ++ pathway_reasons(kept) do
      [] -> row_only_reasons(kept)
      reasons -> reasons
    end
  end

  # A pathway id is evidence, but this application has no typed destination to
  # send a person to for it, so it is stated rather than guessed at.
  defp pathway_reasons(kept) do
    case Map.get(kept, "pathwayId") do
      nil -> []
      value -> [%{reason: "no_typed_destination_for_pathway", field: "pathwayId", value: value}]
    end
  end

  # A CSV row number names a line of a file, not a record; nothing in it can name
  # a current row, so it stays evidence with that reason stated.
  defp row_only_reasons(kept) do
    if Enum.any?(@id_keys -- ["pathwayId"], &Map.has_key?(kept, &1)),
      do: [],
      else: [%{reason: "row_number_is_not_a_record", field: nil, value: nil}]
  end

  defp natural(%Scope{} = scope, "stopId", stop_id) do
    case natural_row(scope, Stop, :stop_id, stop_id) do
      {:resolved, stop} -> {:resolved, %{kind: "stop", id: stop.stop_id, label: stop_name(stop)}}
      {:unresolved, reason} -> {:unresolved, reason}
    end
  end

  defp natural(%Scope{} = scope, "routeId", route_id) do
    case natural_row(scope, Route, :route_id, route_id) do
      {:resolved, route} ->
        {:resolved, %{kind: "route", id: route.route_id, label: route_name(route)}}

      {:unresolved, reason} ->
        {:unresolved, reason}
    end
  end

  defp natural(%Scope{} = scope, "serviceId", service_id) do
    case natural_row(scope, Calendar, :service_id, service_id) do
      {:resolved, calendar} ->
        {:resolved, %{kind: "calendar", id: calendar.service_id, label: nil}}

      {:unresolved, reason} ->
        {:unresolved, reason}
    end
  end

  # A trip is not a destination in this application, so it resolves to the route
  # it currently belongs to, and only when both the trip and that route are
  # single current records.
  defp natural(%Scope{} = scope, "tripId", trip_id) do
    case natural_row(scope, Trip, :trip_id, trip_id) do
      {:resolved, trip} ->
        case natural_row(scope, Route, :route_id, trip.route_id) do
          {:resolved, route} ->
            {:resolved, %{kind: "route", id: route.route_id, label: route_name(route)}}

          {:unresolved, _reason} ->
            {:unresolved, "trip_route_not_current"}
        end

      {:unresolved, reason} ->
        {:unresolved, reason}
    end
  end

  # `Repo.one/2` raises on an ambiguous natural key, so uniqueness is read with a
  # bounded two-row query inside the scope's organization and version: exactly
  # one row resolves, none or several do not. A key naming no row of *this*
  # version - including one that exists only in another version or organization -
  # is no current record here.
  defp natural_row(%Scope{} = scope, schema, field, value) do
    case unique(scope, schema, field, value) do
      [row] -> {:resolved, row}
      [] -> {:unresolved, "no_current_record"}
      _many -> {:unresolved, "duplicate_current_records"}
    end
  end

  defp unique(%Scope{} = scope, schema, field, value) do
    Repo.all(
      from(row in schema,
        where:
          row.organization_id == ^scope.organization_id and
            row.gtfs_version_id == ^scope.gtfs_version_id and
            field(row, ^field) == ^value,
        limit: 2
      )
    )
  end

  defp stop_name(stop), do: stop.stop_name || stop.stop_id

  defp route_name(route), do: route.route_short_name || route.route_long_name || route.route_id

  # -- bounds -----------------------------------------------------------------

  defp bounded(report) do
    case Jason.encode(report) do
      {:ok, json} ->
        if byte_size(json) > @max_result_bytes, do: {:error, :too_large}, else: {:ok, report}

      {:error, _reason} ->
        {:error, :too_large}
    end
  end
end
