defmodule GtfsPlanner.Gtfs.Routes do
  @moduledoc """
  Trusted edit sources, the route editor workspace read and pure merge
  comparison for route detail editing.

  `route_editor/3` loads the whole route workspace in one call: the scoped
  published route and its trusted source, scoped agency options, scoped route
  mode counts, scoped warning candidates and the route's last audit entry. An
  imported route without audit reports unknown attribution (`last_saved` is
  `nil`). No geometry query runs here, so the S-3 map enrichment stays a
  separate read.

  `source/1` projects a persisted route into the R2 source shape: server-owned
  identity (organization, version, route UUID, natural ID, revision) plus the
  raw original editable values and their normalized comparison form.

  `compare_edit/4` is the pure R4 comparison of the trusted base `B`, the
  submitted draft `D` and the freshly locked current `C`. It returns the
  compatible and conflicting field sets and, once a stale merge is explicitly
  confirmed and divergent fields carry choices, the accepted write set
  (`D` minus `B`, minus anything resolved to current) and the combined accepted
  result for validation. Comparison runs on normalized values only; untouched
  fields keep their raw original values in every output.

  The color pair (`route_color` background with its derived `route_text_color`
  foreground) is one edit unit: overlapping pair edits conflict together and
  resolve with one coupled choice. Identity keys carried by base and current
  must fully agree, so a same-natural-ID replacement UUID or a scope change is
  rejected instead of silently rebasing an old edit.

  `infer_route_id/3` is the pure R3 creation-ID precursor: it proposes a
  candidate identifier with its reason and generated/manual mode against a
  caller-supplied taken-ID snapshot. `create_editor_route/3` performs the final
  database allocation under the published-version write lock.

  `create_editor_route/3` is the R3 creation command with audit-backed replay
  protection. It runs one serializable transaction that reauthorizes the actor,
  locks the published version, resolves the submitted agency (seam `S-1`),
  allocates the scoped identifier, inserts the route through the shared `Route`
  editor changeset (seam `S-2`) and writes the route audit in the same
  transaction. `reconcile_creation/2` reports an attempt's committed result
  without ever inserting.

  `update_route/5` is the R4 reviewed detail-edit command. It reauthorizes,
  locks the scoped published version and then the route row, compares the
  trusted base source `B`, the submitted draft `D` and the freshly locked
  current `C`, and validates only the accepted combined result through the
  shared `Route` editor changeset. An unchanged `C` applies only `D` minus `B`;
  a changed `C` returns a fresh source and the comparison before any write, and
  a deliberate merge is bound to the displayed current revision so a third
  intervening save returns a fresh conflict instead of a stale write. Changed
  fields and the route audit commit together; a no-op writes nothing.

  `set_route_active/4` is the distinct R4 status command, kept separate from
  detail params. It reauthorizes and locks the published version then the route
  row in one serializable transaction, requires the exact saved UUID/revision
  for a real state change, and writes only the boolean state together with its
  transactional audit. Only explicit `false` is inactive: a desired state that
  is already effective (including NULL requested as `true`) is a no-op that
  never backfills, and Undo/reactivation must arrive with a fresh source.

  `review_route_deletion/2` builds the R5 deletion review over one consistent
  serializable snapshot: every affected category carries its stable key, count,
  sorted scoped identities, an ordered semantic-content digest and a label, and
  the retained summary names the imported shapes, shared stops, calendars and
  agency that survive. The fingerprint binds command, scope, route UUID and the
  ordered identities plus semantic values, so equal totals with changed
  contents still change it. Malformed cross-route timing ownership blocks the
  review atomically. `deletion_review_changes/2` is the pure comparison of a
  previous and a fresh category list; it returns the stable `count_changed` and
  `contents_changed` category markers in deterministic category order.
  """

  import Ecto.Changeset, only: [add_error: 3]
  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @edit_fields [
    :route_short_name,
    :route_long_name,
    :route_type,
    :agency_id,
    :route_desc,
    :route_url,
    :route_color,
    :route_text_color,
    :route_sort_order,
    :continuous_pickup,
    :continuous_drop_off,
    :network_id
  ]

  @integer_fields [:route_type, :route_sort_order, :continuous_pickup, :continuous_drop_off]
  @hex_fields [:route_color, :route_text_color]
  @color_pair [:route_color, :route_text_color]
  @identity_keys [:organization_id, :gtfs_version_id, :route_uuid, :route_id]
  @confirm_key :confirm_merge
  @choice_values ["mine", "theirs"]
  @known_keys @edit_fields ++ @identity_keys ++ [@confirm_key]

  @digest_fields [
    "route_id",
    "text_mode",
    "route_short_name",
    "route_long_name",
    "route_type",
    "agency_id",
    "route_desc",
    "route_url",
    "route_color",
    "route_text_color",
    "route_sort_order",
    "continuous_pickup",
    "continuous_drop_off",
    "network_id"
  ]

  @type source :: %{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          route_uuid: Ecto.UUID.t(),
          route_id: String.t(),
          updated_at: DateTime.t(),
          original: map(),
          normalized: map()
        }

  @type edit_result :: %{
          status: :applied | :confirmation_required | :choices_required,
          compatible: [atom()],
          conflicting: [atom()],
          write: %{optional(atom()) => term()},
          merged: %{optional(atom()) => term()} | nil
        }

  @type agency_option :: %{
          agency_id: String.t() | nil,
          agency_name: String.t() | nil,
          agency_url: String.t() | nil
        }
  @type mode_count :: %{route_type: integer() | nil, count: non_neg_integer()}
  @type warning_candidate :: %{
          id: Ecto.UUID.t(),
          route_id: String.t(),
          route_short_name: String.t() | nil,
          route_color: String.t() | nil
        }
  @type last_save :: %{
          action: String.t(),
          actor_id: Ecto.UUID.t(),
          actor_email: String.t(),
          saved_at: DateTime.t()
        }
  @type editor_workspace :: %{
          route: Route.t(),
          source: source(),
          agencies: [agency_option()],
          mode_counts: [mode_count()],
          warning_candidates: [warning_candidate()],
          last_saved: last_save() | nil
        }

  @type id_example :: %{route_id: String.t(), route_short_name: String.t() | nil}
  @type id_inference :: %{
          route_id: String.t(),
          reason: :manual | :inferred_prefix | :number | :name_slug | :slug_fallback,
          mode: :generated | :manual
        }

  @type creation_attempt :: %{
          required(:creation_attempt_id) => Ecto.UUID.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t()
        }
  @type create_result :: %{route: Route.t(), replayed?: boolean()}
  @type result_link :: %{route_uuid: Ecto.UUID.t(), route_id: String.t()}

  @type conflict :: %{source: source(), comparison: edit_result()}
  @type update_result :: %{route: Route.t(), source: source()}

  @doc """
  Projects a persisted route into the trusted edit source (R2).

  `original` keeps the raw persisted editable values exactly as stored so
  untouched values (imported hex case, blank colors, custom text colors)
  survive unrelated edits; `normalized` is their comparison-only form.
  Identity stays in the dedicated keys, never inside the value maps.
  """
  @spec source(Route.t()) :: source()
  def source(%Route{} = route) do
    original = Map.new(@edit_fields, &{&1, Map.fetch!(route, &1)})

    %{
      organization_id: route.organization_id,
      gtfs_version_id: route.gtfs_version_id,
      route_uuid: route.id,
      route_id: route.route_id,
      updated_at: route.updated_at,
      original: original,
      normalized: normalize_fields(original)
    }
  end

  @doc """
  Compares trusted `base`, submitted `draft` and freshly locked `current`.

  All three arguments accept either a plain field map (values listed directly,
  optional identity keys) or a `source/1` map (raw values from `original`,
  comparison values from `normalized`). `choices` carries the explicit merge
  confirmation (`confirm_merge: true`) and per-field `"mine"`/`"theirs"`
  resolutions for divergent fields; other choice keys are caller-owned
  bindings and are ignored here.

  Returns `{:error, :source_mismatch}` when base and current identity keys
  disagree (including a same-natural-ID replacement UUID), `{:error,
  {:invalid_choice, field, value}}` for bad choice values, and `{:error,
  {:coupled_choice_conflict, fields}}` when color-pair choices disagree. The
  result map carries `compatible`/`conflicting` field sets in every status;
  `write`/`merged` are only present once the merge is fully resolved and
  explicitly confirmed (or when current is unchanged and a plain save applies
  `D` minus `B` directly).
  """
  @spec compare_edit(map(), map(), map(), map()) ::
          {:ok, edit_result()}
          | {:error,
             :source_mismatch
             | {:invalid_choice, atom(), term()}
             | {:coupled_choice_conflict, [atom()]}}
  def compare_edit(base, draft, current, choices) do
    base_side = side(base)
    current_side = side(current)
    choices = normalize_keys(choices)

    with :ok <- check_identity(base_side.identity, current_side.identity),
         {:ok, choices} <- validate_choices(choices) do
      resolve(base_side, side(draft), current_side, choices)
    end
  end

  @doc """
  Loads the route editor workspace for one published route (R2).

  The read is scoped by organization, version and natural ID through the
  published scoped lookup: a foreign scope, an unpublished version or an
  unknown natural ID is `{:error, :not_found}` with no workspace data. A lost
  database connection is `{:error, :unavailable}`; no other failure is
  classified that way.

  `agencies` carry the scoped ID, name and home URL. `mode_counts` count scoped
  routes per numeric mode, descending frequency then ascending mode.
  `warning_candidates` are the scoped routes projected to UUID, natural ID,
  short name and color only. `last_saved` projects the route's most recent
  audit entry (action, actor and time); `nil` is the unknown/imported
  attribution for a route with no audit. Geometry never runs here.
  """
  @spec route_editor(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, editor_workspace()} | {:error, :not_found | :unavailable}
  def route_editor(organization_id, gtfs_version_id, route_id) do
    with {:ok, route} <- RoutePatterns.published_route(organization_id, gtfs_version_id, route_id) do
      {:ok,
       %{
         route: route,
         source: source(route),
         agencies: agency_options(organization_id, gtfs_version_id),
         mode_counts: mode_counts(organization_id, gtfs_version_id),
         warning_candidates: warning_candidates(organization_id, gtfs_version_id),
         last_saved: last_saved(route)
       }}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  @doc """
  Infers the creation route identifier (R3, pure precursor).

  `candidates` are the same-mode example routes: each carries the natural
  `route_id` and its own `route_short_name` as its number. `attrs` carries the
  submitted `route_short_name` (number), `route_long_name` (name) and an
  optional manual `route_id` (string or atom keys). `taken_ids` is the scoped
  identifier snapshot; suffixed duplicates resolve against it only.

  A manual `route_id` is used verbatim and a duplicate stays `{:error,
  :duplicate_route_id}` — never suffixed. A generated candidate takes the
  prefix shared by at least two eligible examples (IDs ending in their own
  number) when that prefix covers at least 60% of them, with ties resolved
  lexicographically; otherwise the number, then the lowercase name slug, then
  `route` when the slug is empty or non-Latin. Generated duplicates append
  `-2`, `-3`, and so on.
  """
  @spec infer_route_id([id_example()], map(), MapSet.t(String.t()) | Enumerable.t()) ::
          {:ok, id_inference()} | {:error, :duplicate_route_id}
  def infer_route_id(candidates, attrs, taken_ids) do
    taken = MapSet.new(taken_ids)
    attrs = normalize_keys(attrs)

    case trimmed(Map.get(attrs, :route_id)) do
      nil ->
        {candidate, reason} = generated_candidate(candidates, attrs)
        {:ok, %{route_id: dedupe(candidate, taken), reason: reason, mode: :generated}}

      manual ->
        if MapSet.member?(taken, manual) do
          {:error, :duplicate_route_id}
        else
          {:ok, %{route_id: manual, reason: :manual, mode: :manual}}
        end
    end
  end

  @doc """
  Creates one editor route for a verified creation attempt (R3).

  `attempt` is trusted verified attempt data minted when the creation drawer
  opened: the creation-attempt nonce UUID plus its actor, organization and
  version binding (atom or string keys). The binding is rechecked against
  `audit`, and the actor is reauthorized inside the transaction, so an
  arbitrary claimed actor can never reach the mutation.

  One serializable transaction takes the published-version write lock first,
  re-resolves the submitted agency (seam `S-1`), allocates the scoped route
  identifier, inserts the route through the shared `Route` editor changeset
  (seam `S-2`) and writes the route audit together with the mutation. A prior
  create log for the same attempt and canonical request digest replays the
  original route by exact UUID with no new writes (`replayed?: true`). A
  changed digest is `{:error, {:attempt_mismatch, link}}` and a deleted prior
  result is `{:error, :attempt_consumed}`; neither ever inserts a suffixed
  copy. Scoped validation failures are error changesets (manual duplicate and
  agency assignment fail inline), foreign or unpublished scope is `:not_found`,
  a denied actor is `:forbidden`, and exhausted transient retries are `:busy`.
  """
  @spec create_editor_route(map(), creation_attempt() | map(), AuditContext.t()) ::
          {:ok, create_result()}
          | {:error,
             :not_found
             | :forbidden
             | :attempt_consumed
             | :busy
             | :failed_audit
             | :invalid_input
             | {:attempt_mismatch, result_link()}
             | Ecto.Changeset.t()}
  def create_editor_route(attrs, attempt, %AuditContext{} = audit)
      when is_map(attrs) and is_map(attempt) do
    with {:ok, attempt_id} <- verify_creation_attempt(attempt, audit) do
      digest = request_digest(attrs)

      run_command_transaction(fn ->
        :ok = authorize_editor!(audit)
        _version = lock_published_version!(audit)

        case find_creation_log(audit, attempt_id) do
          nil -> insert_created_route(attrs, audit, attempt_id, digest)
          log -> committed_creation(log, digest, audit)
        end
      end)
    end
  end

  def create_editor_route(_attrs, _attempt, _audit), do: {:error, :invalid_input}

  @doc """
  Reports a creation attempt's committed result without inserting (R3).

  Reconciliation is audit-backed: a retained create log for the scoped actor's
  attempt resolves its route by exact UUID. A missing log is `:not_started`
  (mutation and audit are atomic, so no committed create exists), a deleted
  result is `:attempt_consumed`, a now-forbidden actor is `:forbidden` with no
  route details, and a malformed or foreign attempt is `:not_found`.
  """
  @spec reconcile_creation(map(), AuditContext.t()) ::
          {:ok, Route.t()}
          | {:error, :not_started | :attempt_consumed | :forbidden | :not_found}
  def reconcile_creation(attempt, %AuditContext{} = audit) when is_map(attempt) do
    with {:ok, attempt_id} <- verify_creation_attempt(attempt, audit) do
      Repo.transaction(fn ->
        :ok = authorize_editor!(audit)
        _version = lock_published_version!(audit, false)

        case find_creation_log(audit, attempt_id) do
          nil -> Repo.rollback(:not_started)
          log -> committed_creation(log, nil, audit)
        end
      end)
    end
  end

  def reconcile_creation(_attempt, _audit), do: {:error, :not_found}

  @doc """
  Applies reviewed route detail edits (R4).

  `source` is the trusted base `B` (a `source/1` map) minted when the editor
  loaded, `attrs` the submitted draft `D`, and `choices` the deliberate merge
  confirmations: `confirm_merge: true`, per-field `"mine"`/`"theirs"` values
  for divergent fields and the displayed-current-revision binding
  `current_updated_at`. One serializable transaction reauthorizes the active
  editor, locks the scoped published version and then the route row, and
  validates only the accepted combined result through the shared `Route` editor
  changeset, so forged scope/identity/active keys and a replaced UUID can never
  mutate.

  An unchanged current applies only `D` minus `B` directly. A changed current
  never writes on a plain submission: the call returns `{:error, {:conflict,
  payload}}` with a fresh source and the comparison and no stale draft is
  written. A deliberate merge applies only when its choices are bound to the
  displayed current revision (`current_updated_at` matching the freshly locked
  revision); every submission is rechecked against the locked row, so a third
  intervening save returns a fresh conflict payload. No-op saves write nothing
  and add no audit; applied edits write the changed fields and their route audit
  atomically. A source identity mismatch (including a replaced UUID) is
  `:stale`, a missing or foreign route is `:not_found`, and the base is never
  implicitly replaced. A submitted agency is re-resolved under the lock (seam
  `S-1`).
  """
  @spec update_route(String.t(), map(), map(), map(), AuditContext.t()) ::
          {:ok, update_result()}
          | {:error,
             :not_found
             | :stale
             | :forbidden
             | :busy
             | :failed_audit
             | :invalid_input
             | {:conflict, conflict()}
             | {:invalid_choice, atom(), term()}
             | {:coupled_choice_conflict, [atom()]}
             | Ecto.Changeset.t()}
  def update_route(route_id, attrs, base, choices, %AuditContext{} = audit)
      when is_binary(route_id) and is_map(attrs) and is_map(base) and is_map(choices) do
    run_command_transaction(fn ->
      :ok = authorize_editor!(audit)
      _version = lock_published_version!(audit)

      case lock_scoped_route(route_id, audit) do
        nil -> Repo.rollback(:not_found)
        current_route -> apply_reviewed_edit(current_route, attrs, base, choices, audit)
      end
    end)
  end

  def update_route(_route_id, _attrs, _base, _choices, _audit), do: {:error, :invalid_input}

  @doc """
  Changes route eligibility (R4 status command).

  `active` is the desired boolean state and `source` the saved identity the
  caller acts on (an R2 `source/1` map). The command is deliberately separate
  from detail params: one serializable transaction reauthorizes the active
  editor, locks the scoped published version and then the route row, and writes
  only the boolean state together with its transactional route audit.

  A real state change requires the source's exact UUID and revision; a source
  describing a replaced route (same natural ID, different UUID) is `:stale` and
  a deleted or foreign route is `:not_found`, so Undo must arrive with a fresh
  source. Only explicit `false` is inactive: when the desired state is already
  effective (including NULL requested as `true`) the call is a no-op that writes
  nothing, touches no timestamp and never backfills NULL.
  """
  @spec set_route_active(String.t(), boolean(), map(), AuditContext.t()) ::
          {:ok, update_result()}
          | {:error, :not_found | :stale | :forbidden | :busy | :failed_audit | :invalid_input}
  def set_route_active(route_id, active, source, %AuditContext{} = audit)
      when is_binary(route_id) and is_boolean(active) and is_map(source) do
    run_command_transaction(fn ->
      :ok = authorize_editor!(audit)
      _version = lock_published_version!(audit)

      case lock_scoped_route(route_id, audit) do
        nil -> Repo.rollback(:not_found)
        current_route -> apply_status_change(current_route, active, source, audit)
      end
    end)
  end

  def set_route_active(_route_id, _active, _source, _audit), do: {:error, :invalid_input}

  @typedoc "One reviewed deletion category: stable key, count, sorted scoped identities, ordered semantic-content digest and label."
  @type deletion_category :: %{
          key: String.t(),
          label: String.t(),
          count: non_neg_integer(),
          identities: [String.t()],
          digest: String.t()
        }

  @typedoc "One retained-resource summary entry: stable key, count, sorted identities and label."
  @type retained_resource :: %{
          key: String.t(),
          label: String.t(),
          count: non_neg_integer(),
          identities: [String.t()]
        }

  @type deletion_review :: %{
          fingerprint: String.t(),
          route_uuid: Ecto.UUID.t(),
          categories: [deletion_category()],
          retained: [retained_resource()],
          empty?: boolean()
        }

  @doc """
  Builds the complete R5 deletion review for one scoped route (AC-13).

  One serializable transaction provides the consistent snapshot. Every
  affected set is enumerated with its scoped identities and an ordered
  semantic-content digest that covers the row values (never timestamps alone,
  because `update_all` writers preserve them); stop-time vectors are streamed
  into an incremental hash instead of accumulating in memory. Zero-pattern
  routes still enumerate their explicit relationships (transfers, fare rules,
  attributions, network links and translations), and the retained summary
  names the affected imported shapes and other shared resources that survive.

  Malformed cross-route timing ownership (a trip whose linked timing belongs to
  another route's pattern, or a timing row spanning two routes' patterns)
  blocks the review atomically with `:malformed_cross_route_timing`. A foreign
  or unpublished scope is `:not_found` without counts; a denied actor is
  `:forbidden`.
  """
  @spec review_route_deletion(String.t(), AuditContext.t()) ::
          {:ok, deletion_review()}
          | {:error,
             :not_found | :forbidden | :busy | :invalid_input | :malformed_cross_route_timing}
  def review_route_deletion(route_id, %AuditContext{} = audit) when is_binary(route_id) do
    run_command_transaction(fn ->
      :ok = authorize_editor!(audit)
      _version = lock_published_version!(audit, false)

      case scoped_route(route_id, audit) do
        nil -> Repo.rollback(:not_found)
        route -> build_deletion_review(route, audit)
      end
    end)
  end

  def review_route_deletion(_route_id, _audit), do: {:error, :invalid_input}

  @doc """
  Compares a previous and a fresh deletion-review category list (R5/AC-13).

  Returns one entry per changed category, in the fresh list's deterministic
  order, carrying the stable `:count_changed` and `:contents_changed` markers:
  a count difference is `:count_changed`, and any semantic-content digest
  difference is `:contents_changed`, so equal totals with changed contents are
  still explained. Unchanged categories are omitted.
  """
  @spec deletion_review_changes([map()], [map()]) ::
          [%{key: String.t(), label: String.t(), markers: [atom()]}]
  def deletion_review_changes(previous_categories, categories)
      when is_list(previous_categories) and is_list(categories) do
    previous = Map.new(previous_categories, &{&1.key, &1})

    Enum.flat_map(categories, fn category ->
      markers = change_markers(Map.get(previous, category.key), category)

      if markers == [],
        do: [],
        else: [%{key: category.key, label: category.label, markers: markers}]
    end)
  end

  defp change_markers(nil, _category), do: [:count_changed, :contents_changed]

  defp change_markers(previous, category) do
    Enum.concat([
      if(previous.count != category.count, do: [:count_changed], else: []),
      if(previous.digest != category.digest, do: [:contents_changed], else: [])
    ])
  end

  defp agency_options(organization_id, gtfs_version_id) do
    Enum.map(Gtfs.list_agencies(organization_id, gtfs_version_id), fn agency ->
      %{
        agency_id: agency.agency_id,
        agency_name: agency.agency_name,
        agency_url: agency.agency_url
      }
    end)
  end

  defp mode_counts(organization_id, gtfs_version_id) do
    from(route in Route,
      where:
        route.organization_id == ^organization_id and
          route.gtfs_version_id == ^gtfs_version_id,
      group_by: route.route_type,
      select: %{route_type: route.route_type, count: count(route.id)},
      order_by: [desc: count(route.id), asc: route.route_type]
    )
    |> Repo.all()
  end

  defp warning_candidates(organization_id, gtfs_version_id) do
    from(route in Route,
      where:
        route.organization_id == ^organization_id and
          route.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: route.route_id],
      select: %{
        id: route.id,
        route_id: route.route_id,
        route_short_name: route.route_short_name,
        route_color: route.route_color
      }
    )
    |> Repo.all()
  end

  # The route's most recent audit entry, bound to the route UUID so a deleted
  # and recreated natural ID never inherits the old attribution.
  defp last_saved(%Route{} = route) do
    from(log in ChangeLog,
      where:
        log.organization_id == ^route.organization_id and
          log.gtfs_version_id == ^route.gtfs_version_id and
          log.entity_type == "route" and log.entity_id == ^route.id,
      order_by: [desc: log.inserted_at, desc: log.id],
      limit: 1,
      select: %{
        action: log.action,
        actor_id: log.actor_id,
        actor_email: log.actor_email,
        saved_at: log.inserted_at
      }
    )
    |> Repo.one()
  end

  # --- identifier inference internals -------------------------------------

  defp generated_candidate(candidates, attrs) do
    number = trimmed(Map.get(attrs, :route_short_name))
    name = trimmed(Map.get(attrs, :route_long_name))

    case inferred_prefix(candidates, number) do
      prefix when is_binary(prefix) ->
        {prefix <> number, :inferred_prefix}

      nil when is_binary(number) ->
        {number, :number}

      nil ->
        case name_slug(name) do
          "" -> {"route", :slug_fallback}
          slug -> {slug, :name_slug}
        end
    end
  end

  # The lexicographically smallest nonempty prefix shared by at least two
  # eligible same-mode examples with >=60% agreement. Examples whose IDs end
  # in their own number with an empty prefix count in the denominator but are
  # never selected: their inferred ID is the number fallback either way.
  defp inferred_prefix(_candidates, nil), do: nil

  defp inferred_prefix(candidates, _number) do
    examples =
      Enum.flat_map(candidates, fn candidate ->
        candidate = normalize_keys(candidate)
        id = trimmed(Map.get(candidate, :route_id))
        example_number = trimmed(Map.get(candidate, :route_short_name))

        with true <- is_binary(id),
             true <- is_binary(example_number),
             true <- String.ends_with?(id, example_number) do
          [binary_part(id, 0, byte_size(id) - byte_size(example_number))]
        else
          _ -> []
        end
      end)

    total = length(examples)

    examples
    |> Enum.frequencies()
    |> Enum.filter(fn {prefix, count} ->
      prefix != "" and count >= 2 and count * 100 >= 60 * total
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> List.first()
  end

  defp dedupe(candidate, taken) do
    if MapSet.member?(taken, candidate) do
      Stream.iterate(2, &(&1 + 1))
      |> Stream.map(&"#{candidate}-#{&1}")
      |> Enum.find(&(not MapSet.member?(taken, &1)))
    else
      candidate
    end
  end

  defp name_slug(nil), do: ""

  defp name_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp trimmed(nil), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil

  # --- creation and replay internals ---------------------------------------

  # The domain receives trusted verified attempt data from the LiveView
  # boundary; the binding is still rechecked here so a claimed actor or foreign
  # scope can never reach the mutation. An actor binding mismatch is
  # `:forbidden`; malformed or foreign scope is `:not_found` (AC-1).
  defp verify_creation_attempt(attempt, audit) do
    attempt_id = attempt_field(attempt, :creation_attempt_id)
    actor_id = attempt_field(attempt, :actor_id)
    organization_id = attempt_field(attempt, :organization_id)
    gtfs_version_id = attempt_field(attempt, :gtfs_version_id)

    cond do
      not Enum.all?([attempt_id, actor_id, organization_id, gtfs_version_id], &uuid?/1) ->
        {:error, :not_found}

      actor_id != audit.actor_id ->
        {:error, :forbidden}

      organization_id != audit.organization_id or gtfs_version_id != audit.gtfs_version_id ->
        {:error, :not_found}

      true ->
        {:ok, attempt_id}
    end
  end

  defp attempt_field(attempt, key) do
    Map.get(attempt, key) || Map.get(attempt, Atom.to_string(key))
  end

  # Active organization editors only (AC-1); the rule matches the established
  # Calendars editor gate and is rechecked inside every create transaction so
  # denied mutations write nothing.
  defp authorize_editor!(%AuditContext{} = audit) do
    with true <- uuid?(audit.actor_id),
         true <- uuid?(audit.organization_id),
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(audit.actor_id, audit.organization_id),
         true <- is_nil(membership.deactivated_at),
         true <- editor_role?(membership.roles) do
      :ok
    else
      _other -> Repo.rollback(:forbidden)
    end
  end

  defp editor_role?(roles) when is_list(roles), do: "pathways_studio_editor" in roles
  defp editor_role?(_roles), do: false

  # Published scope only (AC-1). The create command locks the version row FOR
  # UPDATE before any read or write so allocation and agency resolution see
  # committed state; reconcile reads without the lock.
  defp lock_published_version!(audit, lock \\ true) do
    if uuid?(audit.organization_id) and uuid?(audit.gtfs_version_id) do
      query =
        from(version in GtfsVersion,
          where:
            version.id == ^audit.gtfs_version_id and
              version.organization_id == ^audit.organization_id and
              version.publication_status == "published"
        )

      query = if lock, do: from(version in query, lock: "FOR UPDATE"), else: query

      case Repo.one(query) do
        %GtfsVersion{} = version -> version
        nil -> Repo.rollback(:not_found)
      end
    else
      Repo.rollback(:not_found)
    end
  end

  # The retained route-created log is the attempt record: scoped by actor and
  # attempt id, with the canonical request digest and result UUID retained.
  defp find_creation_log(audit, attempt_id) do
    from(log in ChangeLog,
      where:
        log.organization_id == ^audit.organization_id and
          log.gtfs_version_id == ^audit.gtfs_version_id and
          log.entity_type == "route" and log.action == "created" and
          log.actor_id == ^audit.actor_id and
          fragment("?->>'creation_attempt_id' = ?", log.changed_fields, ^attempt_id),
      order_by: [desc: log.inserted_at, desc: log.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp load_created_route(audit, route_uuid) do
    if uuid?(route_uuid) do
      from(route in Route,
        where:
          route.id == ^route_uuid and route.organization_id == ^audit.organization_id and
            route.gtfs_version_id == ^audit.gtfs_version_id
      )
      |> Repo.one()
    end
  end

  # One committed create log reconciles both callers: create replays the
  # original route when the request digest matches and refuses a changed
  # submission; reconcile returns the route for the attempt. A deleted result
  # is `:attempt_consumed`, and reconciliation alone never inserts.
  defp committed_creation(log, digest, audit) do
    case load_created_route(audit, log.entity_id) do
      nil ->
        Repo.rollback(:attempt_consumed)

      route ->
        cond do
          is_nil(digest) ->
            route

          Map.get(log.changed_fields || %{}, "request_digest") == digest ->
            %{route: route, replayed?: true}

          true ->
            Repo.rollback({:attempt_mismatch, %{route_uuid: route.id, route_id: route.route_id}})
        end
    end
  end

  defp insert_created_route(attrs, audit, attempt_id, digest) do
    cast_attrs = stringify_keys(attrs)
    agency = resolve_agency(cast_attrs, audit)
    allocation = allocate_route_id(cast_attrs, audit)

    changeset =
      %Route{organization_id: audit.organization_id, gtfs_version_id: audit.gtfs_version_id}
      |> Route.editor_changeset(creation_attrs(cast_attrs, agency, allocation), :create)
      |> put_resolution_errors(agency, allocation)

    if changeset.valid? do
      insert_created!(changeset, allocation, audit, attempt_id, digest)
    else
      Repo.rollback(changeset)
    end
  end

  defp creation_attrs(cast_attrs, agency, allocation) do
    cast_attrs
    |> put_resolution(agency)
    |> put_resolution(allocation)
  end

  defp put_resolution(attrs, {:ok, values}) when is_map(values) do
    Map.merge(attrs, Map.new(values, fn {key, value} -> {to_string(key), value} end))
  end

  defp put_resolution(attrs, {:error, _reason}), do: attrs

  defp put_resolution_errors(changeset, agency, allocation) do
    Enum.reduce([agency, allocation], changeset, fn
      {:error, {field, message}}, acc -> add_error(acc, field, message)
      _outcome, acc -> acc
    end)
  end

  defp insert_created!(changeset, {:ok, %{mode: mode}}, audit, attempt_id, digest) do
    case Repo.insert(changeset) do
      {:ok, route} ->
        audit_created!(route, audit, attempt_id, digest)
        %{route: route, replayed?: false}

      {:error, %Ecto.Changeset{} = failed} ->
        if mode == :generated and Keyword.has_key?(failed.errors, :route_id) do
          # An explicitly identified generated-ID collision reruns the closure
          # so allocation re-suffixes against fresh committed rows; a manual
          # override is never renamed.
          Repo.rollback(:generated_collision)
        else
          Repo.rollback(failed)
        end
    end
  end

  # Seam S-1: a submitted agency is re-resolved inside the transaction with
  # Gtfs.get_agency_by_agency_id/3 under the version write lock. One scoped
  # agency resolves automatically (read-only assignment) and multiple agencies
  # require a selected scoped agency (AC-5).
  defp resolve_agency(attrs, audit) do
    submitted = trimmed(Map.get(attrs, "agency_id") || Map.get(attrs, :agency_id))
    count = Gtfs.count_agencies(audit.organization_id, audit.gtfs_version_id)

    cond do
      is_binary(submitted) ->
        case Gtfs.get_agency_by_agency_id(
               audit.organization_id,
               audit.gtfs_version_id,
               submitted
             ) do
          %Agency{} = agency -> {:ok, %{agency_id: agency.agency_id}}
          nil -> {:error, {:agency_id, "is not available in this version"}}
        end

      count == 1 ->
        case Gtfs.list_agencies(audit.organization_id, audit.gtfs_version_id) do
          [agency | _rest] -> {:ok, %{agency_id: agency.agency_id}}
        end

      count >= 2 ->
        {:error, {:agency_id, "must be selected when the version has multiple agencies"}}

      true ->
        {:ok, %{}}
    end
  end

  defp allocate_route_id(attrs, audit) do
    taken =
      from(route in Route,
        where:
          route.organization_id == ^audit.organization_id and
            route.gtfs_version_id == ^audit.gtfs_version_id,
        select: route.route_id
      )
      |> Repo.all()

    case infer_route_id(id_examples(attrs, audit), attrs, taken) do
      {:ok, allocation} -> {:ok, allocation}
      {:error, :duplicate_route_id} -> {:error, {:route_id, "has already been taken"}}
    end
  end

  # Same-mode example routes for identifier inference; a non-numeric submitted
  # mode has no examples and falls back to the number or name slug.
  defp id_examples(attrs, audit) do
    case normalize_value(:route_type, Map.get(attrs, "route_type") || Map.get(attrs, :route_type)) do
      route_type when is_integer(route_type) ->
        from(route in Route,
          where:
            route.organization_id == ^audit.organization_id and
              route.gtfs_version_id == ^audit.gtfs_version_id and
              route.route_type == ^route_type,
          select: %{route_id: route.route_id, route_short_name: route.route_short_name}
        )
        |> Repo.all()

      _other ->
        []
    end
  end

  defp audit_created!(route, audit, attempt_id, digest) do
    case Gtfs.record_change_in_transaction(audit, :route, route, "created", %{
           before: nil,
           creation_attempt_id: attempt_id,
           request_digest: digest
         }) do
      {:ok, log} -> log
      {:error, _changeset} -> Repo.rollback(:failed_audit)
    end
  end

  # Canonical submitted-value digest over the creation request fields (R1:
  # transient text_mode is included). Keys are canonical names, values are
  # trimmed and blanks dropped, so an identical resubmission replays while any
  # changed submitted value mismatches.
  defp request_digest(attrs) do
    canonical =
      attrs
      |> stringify_keys()
      |> Map.take(@digest_fields)
      |> Enum.flat_map(fn {key, value} ->
        case canonical_value(value) do
          nil -> []
          canonical -> [{key, canonical}]
        end
      end)
      |> Enum.sort()

    "sha256:" <>
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(canonical)), case: :lower)
  end

  defp canonical_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp canonical_value(value) when is_number(value) or is_boolean(value) or is_atom(value),
    do: to_string(value)

  defp canonical_value(value), do: inspect(value)

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # --- reviewed update internals -------------------------------------------

  defp lock_scoped_route(route_id, audit) do
    from(route in Route,
      where:
        route.organization_id == ^audit.organization_id and
          route.gtfs_version_id == ^audit.gtfs_version_id and
          route.route_id == ^route_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  # Compares the trusted base, the submitted draft and the freshly locked
  # current, then either refuses before any write (identity mismatch, bad
  # choices, or a changed current without a confirmed merge bound to the
  # displayed revision) or applies the accepted write set. `:source_mismatch`
  # — including a replaced UUID — is `:stale` and never a rebase of the base.
  defp apply_reviewed_edit(current_route, attrs, base, choices, audit) do
    current = source(current_route)

    case compare_edit(base, attrs, current, choices) do
      {:error, :source_mismatch} ->
        Repo.rollback(:stale)

      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, %{status: status} = comparison} when status != :applied ->
        Repo.rollback({:conflict, %{source: current, comparison: comparison}})

      {:ok, %{write: write} = comparison} ->
        if changed_since_base?(base, current) and
             not bound_to_displayed_current?(choices, current_route) do
          # The choices were bound to another revision: re-present the merge as
          # undecided and never write the stale draft.
          Repo.rollback(
            {:conflict, %{source: current, comparison: unresolved_comparison(comparison)}}
          )
        else
          write_reviewed_edit(current_route, write, attrs, audit)
        end
    end
  end

  # A re-displayed comparison is always undecided: divergent fields need fresh
  # per-field choices and everything else needs fresh merge confirmation.
  defp unresolved_comparison(%{conflicting: conflicting} = comparison) do
    %{
      comparison
      | status: if(conflicting == [], do: :confirmation_required, else: :choices_required),
        write: %{},
        merged: nil
    }
  end

  # A changed current means the submission is a deliberate merge: its choices
  # must be bound to the revision that was actually displayed.
  defp changed_since_base?(base, current) do
    base_normalized = side(base).normalized

    Enum.any?(@edit_fields, fn field ->
      Map.get(base_normalized, field) != Map.get(current.normalized, field)
    end)
  end

  defp bound_to_displayed_current?(choices, current_route) do
    binding = Map.get(choices, :current_updated_at) || Map.get(choices, "current_updated_at")

    case binding && Ecto.Type.cast(:utc_datetime_usec, binding) do
      {:ok, bound} when not is_nil(bound) ->
        DateTime.compare(bound, current_route.updated_at) == :eq

      _other ->
        false
    end
  end

  # Only the accepted write set is cast (untouched raw imported values stay
  # outside normalization) and the shared editor changeset validates the
  # accepted combined result. A submitted agency is re-resolved under the
  # version lock (seam `S-1`). A changeset with nothing left to change is a
  # no-op: no write, no timestamp touch and no audit.
  defp write_reviewed_edit(current_route, write, attrs, audit) do
    write_attrs = stringify_keys(write)

    agency =
      if Map.has_key?(write, :agency_id),
        do: resolve_agency(write_attrs, audit),
        else: {:ok, %{}}

    final_attrs =
      write_attrs
      |> put_resolution(agency)
      |> put_text_mode(attrs)

    changeset = Route.editor_changeset(current_route, final_attrs, :edit)

    changeset =
      case agency do
        {:error, {field, message}} -> add_error(changeset, field, message)
        _outcome -> changeset
      end

    cond do
      not changeset.valid? ->
        Repo.rollback(changeset)

      changeset.changes == %{} ->
        %{route: current_route, source: source(current_route)}

      true ->
        case Repo.update(changeset) do
          {:ok, updated} ->
            audit_updated!(current_route, updated, audit)
            %{route: updated, source: source(updated)}

          {:error, failed} ->
            Repo.rollback(failed)
        end
    end
  end

  # --- status internals ----------------------------------------------------

  # Only explicit false is inactive (R4/INV-4): true and NULL both mean
  # effectively eligible, so a desired state already effective is a no-op and
  # a NULL row is never backfilled to true.
  defp effectively_active?(active), do: active != false

  # Identity binding is fail-closed and applies to every call (AC-9): a source
  # that does not describe this exact route row (replaced UUID, scope change or
  # a one-sided identity) is :stale and never authorizes the command. A real
  # state change additionally requires the exact displayed revision, so Undo
  # and reactivation use the fresh source minted by the previous change.
  defp apply_status_change(current_route, desired, source, audit) do
    current = source(current_route)

    case check_identity(side(source).identity, side(current).identity) do
      {:error, :source_mismatch} ->
        Repo.rollback(:stale)

      :ok ->
        cond do
          effectively_active?(current_route.active) == desired ->
            %{route: current_route, source: current}

          not exact_revision?(source, current_route) ->
            Repo.rollback(:stale)

          true ->
            write_status_change(current_route, desired, audit)
        end
    end
  end

  defp exact_revision?(source, current_route) do
    revision = Map.get(source, :updated_at) || Map.get(source, "updated_at")

    case revision && Ecto.Type.cast(:utc_datetime_usec, revision) do
      {:ok, bound} when not is_nil(bound) ->
        DateTime.compare(bound, current_route.updated_at) == :eq

      _other ->
        false
    end
  end

  # A deliberate status change writes the boolean state and the transactional
  # audit only (R4/INV-3): no detail field is cast, a failed audit rolls the
  # mutation back, and the ordinary revision advance is what forces Undo to
  # reauthorize against a fresh source.
  defp write_status_change(current_route, desired, audit) do
    changeset = Ecto.Changeset.change(current_route, active: desired)

    case Repo.update(changeset) do
      {:ok, updated} ->
        audit_updated!(current_route, updated, audit)
        %{route: updated, source: source(updated)}

      {:error, failed} ->
        Repo.rollback(failed)
    end
  end

  # text_mode is transient form transport metadata (R1): forwarded so the
  # editor changeset recomputes automatic text server-side and rejects invalid
  # values, never persisted.
  defp put_text_mode(final_attrs, attrs) do
    key = Enum.find(["text_mode", :text_mode], &Map.has_key?(attrs, &1))
    if key, do: Map.put(final_attrs, "text_mode", Map.fetch!(attrs, key)), else: final_attrs
  end

  # Mutation and audit commit together (INV-3); an unrecordable audit rolls the
  # edit back. Route diffs are the explicit before/after snapshots in the
  # shared snapshot shape.
  defp audit_updated!(before_route, updated_route, audit) do
    case Gtfs.record_change_in_transaction(audit, :route, updated_route, "updated", %{
           before: Gtfs.route_audit_snapshot(before_route),
           after: Gtfs.route_audit_snapshot(updated_route)
         }) do
      {:ok, log} -> log
      {:error, _changeset} -> Repo.rollback(:failed_audit)
    end
  end

  # The route command bounded-retry convention (the route-pattern/schedule
  # rule): rerun the whole serializable closure on a transient serialization
  # failure (40001), deadlock (40P01) or an explicitly identified generated-ID
  # collision, at most three attempts. Manual overrides and every other failure
  # return unchanged; exhausted retries are `:busy`.
  defp run_command_transaction(transaction, attempts \\ 3) do
    case run_apply_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:retryable_conflict, _error} ->
        retry_command_transaction(transaction, attempts)

      {:error, :generated_collision} ->
        retry_command_transaction(transaction, attempts)

      {:error, reason} ->
        if retryable_conflict?(reason),
          do: retry_command_transaction(transaction, attempts),
          else: {:error, reason}
    end
  end

  defp retry_command_transaction(transaction, attempts) when attempts > 1,
    do: run_command_transaction(transaction, attempts - 1)

  defp retry_command_transaction(_transaction, _attempts), do: {:error, :busy}

  defp run_apply_transaction(transaction) do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    ).run(transaction)
  rescue
    error in Postgrex.Error ->
      if retryable_conflict?(error),
        do: {:retryable_conflict, error},
        else: reraise(error, __STACKTRACE__)
  end

  defp retryable_conflict?(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :serialization_failure,
              "40001",
              :deadlock_detected,
              "40P01"
            ],
       do: true

  defp retryable_conflict?(_reason), do: false

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  # --- comparison internals -----------------------------------------------

  # Splits a base/current/draft map into raw values, normalized comparison
  # values and identity keys. A source map contributes `original` as raw and
  # `normalized` as comparison values; a plain map is normalized here.
  defp side(map) when is_map(map) do
    map = normalize_keys(map)

    {raw, normalized} =
      case map do
        %{original: %{} = original, normalized: %{} = normalized} ->
          {normalize_keys(original), normalize_keys(normalized)}

        plain ->
          fields = Map.take(plain, @edit_fields)
          {fields, normalize_fields(fields)}
      end

    %{raw: raw, normalized: normalized, identity: Map.take(map, @identity_keys)}
  end

  # Identity keys present on either side must match exactly; a key present on
  # only one side is a mismatch, and both sides without identity keys compares
  # as plain field maps.
  defp check_identity(base_identity, current_identity) do
    if same_identity?(base_identity, current_identity) do
      :ok
    else
      {:error, :source_mismatch}
    end
  end

  defp same_identity?(base_identity, current_identity) do
    Enum.sort(Map.keys(base_identity)) == Enum.sort(Map.keys(current_identity)) and
      Enum.all?(base_identity, fn {key, value} ->
        Map.fetch(current_identity, key) == {:ok, value}
      end)
  end

  defp validate_choices(choices) do
    confirm = Map.get(choices, @confirm_key)

    field_choices =
      choices
      |> Map.drop([@confirm_key])
      |> Enum.filter(fn {key, _value} -> key in @edit_fields end)

    invalid = Enum.find(field_choices, fn {_key, value} -> value not in @choice_values end)

    cond do
      confirm not in [true, nil] ->
        {:error, {:invalid_choice, @confirm_key, confirm}}

      is_tuple(invalid) ->
        {key, value} = invalid
        {:error, {:invalid_choice, key, value}}

      true ->
        {:ok, %{confirmed?: confirm == true, fields: Map.new(field_choices)}}
    end
  end

  defp resolve(base, draft, current, choices) do
    units = Enum.map(edit_units(), &classify_unit(&1, base, draft, current))

    compatible = units |> Enum.flat_map(&compatible_fields/1) |> Enum.uniq() |> Enum.sort()
    conflicting = units |> Enum.flat_map(&conflicting_fields/1) |> Enum.uniq() |> Enum.sort()

    case resolve_units(units, choices) do
      {:error, _reason} = error ->
        error

      :unresolved ->
        {:ok, result(:choices_required, compatible, conflicting, %{}, nil)}

      {:ok, resolved} ->
        if stale?(resolved) and not choices.confirmed? do
          {:ok, result(:confirmation_required, compatible, conflicting, %{}, nil)}
        else
          write = build_write(resolved, draft, current)
          merged = build_merged(base, current, write)
          {:ok, result(:applied, compatible, conflicting, write, merged)}
        end
    end
  end

  defp result(status, compatible, conflicting, write, merged) do
    %{
      status: status,
      compatible: compatible,
      conflicting: conflicting,
      write: write,
      merged: merged
    }
  end

  # The color pair is one edit unit so automatic background/foreground edits
  # stay coupled; every other editable field is its own unit.
  defp edit_units do
    [@color_pair | Enum.map(@edit_fields -- @color_pair, &[&1])]
  end

  defp classify_unit(members, base, draft, current) do
    mine = Enum.filter(members, &changed?(&1, draft, base))
    theirs = Enum.filter(members, &changed?(&1, current, base))

    kind =
      cond do
        mine == [] or theirs == [] -> :disjoint
        Enum.sort(mine) == Enum.sort(theirs) and identical?(mine, draft, current) -> :identical
        true -> :conflict
      end

    %{members: members, mine: mine, theirs: theirs, kind: kind, resolution: nil}
  end

  defp changed?(field, side, base) do
    Map.has_key?(side.normalized, field) and
      normalize_value(field, Map.get(side.raw, field)) !=
        normalize_value(field, Map.get(base.raw, field))
  end

  defp identical?(fields, draft, current) do
    Enum.all?(fields, fn field ->
      normalize_value(field, Map.get(draft.raw, field)) ==
        normalize_value(field, Map.get(current.raw, field))
    end)
  end

  defp compatible_fields(%{kind: :conflict}), do: []

  defp compatible_fields(%{mine: mine, theirs: theirs}) do
    Enum.uniq(mine ++ theirs)
  end

  defp conflicting_fields(%{kind: :conflict, mine: mine, theirs: theirs}),
    do: Enum.uniq(mine ++ theirs)

  defp conflicting_fields(_unit), do: []

  defp stale?(units), do: Enum.any?(units, fn unit -> unit.theirs != [] end)

  defp resolve_units(units, choices) do
    Enum.reduce_while(units, {:ok, []}, fn unit, {:ok, acc} ->
      case resolve_unit(unit, choices) do
        {:ok, unit} -> {:cont, {:ok, [unit | acc]}}
        :unresolved -> {:halt, :unresolved}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      other -> other
    end
  end

  # A conflicted unit resolves with one coupled choice over all its members;
  # disagreeing member choices break the color/text coupling and are rejected.
  defp resolve_unit(%{kind: :conflict, members: members} = unit, choices) do
    values =
      members
      |> Enum.map(&Map.get(choices.fields, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case values do
      [] ->
        :unresolved

      [value] ->
        {:ok, %{unit | resolution: choice_atom(value)}}

      _disagreeing ->
        {:error, {:coupled_choice_conflict, Enum.sort(members)}}
    end
  end

  defp resolve_unit(unit, _choices), do: {:ok, unit}

  defp choice_atom("mine"), do: :mine
  defp choice_atom("theirs"), do: :theirs

  # Accepted draft values: one-sided mine edits, identical edits (dropped when
  # already equivalent at current), and conflicted units resolved to mine.
  defp build_write(units, draft, current) do
    units
    |> Enum.flat_map(fn
      %{kind: :conflict, resolution: :theirs} -> []
      %{kind: :conflict, resolution: :mine, mine: mine} -> mine
      %{kind: _kind, mine: mine} -> mine
    end)
    |> Enum.uniq()
    |> Enum.filter(fn field ->
      normalize_value(field, Map.get(draft.raw, field)) !=
        normalize_value(field, Map.get(current.raw, field))
    end)
    |> Map.new(fn field -> {field, Map.fetch!(draft.raw, field)} end)
  end

  # Combined accepted result: raw current values (freshly locked originals for
  # untouched fields, falling back to base originals) overlaid with the write.
  defp build_merged(base, current, write) do
    keys =
      (Map.keys(base.raw) ++ Map.keys(current.raw) ++ Map.keys(write))
      |> Enum.uniq()

    Map.new(keys, fn field ->
      cond do
        Map.has_key?(write, field) -> {field, Map.fetch!(write, field)}
        Map.has_key?(current.raw, field) -> {field, Map.fetch!(current.raw, field)}
        true -> {field, Map.fetch!(base.raw, field)}
      end
    end)
  end

  # --- value normalization -------------------------------------------------

  defp normalize_fields(fields) do
    Map.new(fields, fn {field, value} -> {field, normalize_value(field, value)} end)
  end

  # Comparison-only normalization: blank text collapses to nil so form blanks
  # never look like changes, hex case folds so display casing is not an edit,
  # and integer fields accept their string form as the same value. Raw values
  # are preserved unchanged everywhere else.
  defp normalize_value(field, value) when field in @hex_fields do
    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> String.upcase(trimmed)
        end

      other ->
        other
    end
  end

  defp normalize_value(field, value) when field in @integer_fields do
    case value do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {int, ""} -> int
          _ -> String.trim(value)
        end

      other ->
        other
    end
  end

  defp normalize_value(_field, value) do
    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      other ->
        other
    end
  end

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {known_key(key), value}
      {key, value} -> {key, value}
    end)
  end

  # Known keys map to their canonical atoms; unknown keys stay strings, so
  # user input never mints atoms and forged keys never become fields.
  defp known_key(key) do
    Enum.find(@known_keys, key, fn known -> Atom.to_string(known) == key end)
  end

  # --- deletion review internals ---------------------------------------------

  defp scoped_route(route_id, audit) do
    Repo.one(
      from(route in Route,
        where:
          route.organization_id == ^audit.organization_id and
            route.gtfs_version_id == ^audit.gtfs_version_id and
            route.route_id == ^route_id
      )
    )
  end

  # The R5 consistent snapshot: one serializable transaction enumerates every
  # affected set in a fixed category order. Identity lists are sorted and each
  # digest hashes the category's semantic row values in a deterministic order.
  defp build_deletion_review(route, audit) do
    org_id = audit.organization_id
    version_id = audit.gtfs_version_id
    route_id = route.route_id

    :ok = check_cross_route_timing!(org_id, version_id, route_id)

    pattern_ids =
      Repo.all(
        from(p in RoutePattern,
          where: p.organization_id == ^org_id and p.gtfs_version_id == ^version_id,
          where: p.route_id == ^route_id,
          select: p.id
        )
      )

    timing_ids =
      if pattern_ids == [] do
        []
      else
        Repo.all(
          from(tp in TimedPattern,
            where: tp.organization_id == ^org_id and tp.gtfs_version_id == ^version_id,
            where: tp.route_pattern_id in ^pattern_ids,
            select: tp.id
          )
        )
      end

    trip_ids =
      Repo.all(
        from(t in Trip,
          where: t.organization_id == ^org_id and t.gtfs_version_id == ^version_id,
          where: t.route_id == ^route_id,
          select: t.trip_id
        )
      )

    attribution_ids =
      Repo.all(
        from(a in Attribution,
          where: a.organization_id == ^org_id and a.gtfs_version_id == ^version_id,
          where: a.route_id == ^route_id or a.trip_id in ^trip_ids,
          where: not is_nil(a.attribution_id),
          select: a.attribution_id
        )
      )

    categories = [
      route_category(route),
      stream_category(
        from(p in RoutePattern,
          where: p.organization_id == ^org_id and p.gtfs_version_id == ^version_id,
          where: p.route_id == ^route_id,
          order_by: [p.route_pattern_id, p.id]
        ),
        "patterns",
        "Route patterns",
        &{&1.route_pattern_id, semantic_content(&1)}
      ),
      stream_category(
        from(rps in RoutePatternStop,
          where: rps.organization_id == ^org_id and rps.gtfs_version_id == ^version_id,
          where: rps.route_pattern_id in ^pattern_ids,
          order_by: [rps.route_pattern_id, rps.position, rps.id]
        ),
        "pattern_stops",
        "Pattern stops",
        &{&1.id, semantic_content(&1)}
      ),
      stream_category(
        from(tp in TimedPattern,
          where: tp.organization_id == ^org_id and tp.gtfs_version_id == ^version_id,
          where: tp.route_pattern_id in ^pattern_ids,
          order_by: [tp.id]
        ),
        "timed_patterns",
        "Timed patterns",
        &{&1.id, semantic_content(&1)}
      ),
      stream_category(
        from(tps in TimedPatternStop,
          where: tps.timed_pattern_id in ^timing_ids,
          order_by: [tps.id]
        ),
        "timed_pattern_stops",
        "Timing rows",
        &{&1.id, semantic_content(&1)}
      ),
      stream_category(
        from(t in Trip,
          where: t.organization_id == ^org_id and t.gtfs_version_id == ^version_id,
          where: t.route_id == ^route_id,
          order_by: [t.trip_id, t.id]
        ),
        "trips",
        "Trips",
        &{&1.trip_id, semantic_content(&1)}
      ),
      stream_category(
        from(st in StopTime,
          where: st.organization_id == ^org_id and st.gtfs_version_id == ^version_id,
          where: st.trip_id in ^trip_ids,
          order_by: [st.trip_id, st.stop_sequence, st.id]
        ),
        "stop_times",
        "Stop times",
        &{"#{&1.trip_id}:#{&1.stop_sequence}", semantic_content(&1)}
      ),
      stream_category(
        from(f in Frequency,
          where: f.organization_id == ^org_id and f.gtfs_version_id == ^version_id,
          where: f.trip_id in ^trip_ids,
          order_by: [f.trip_id, f.start_time, f.id]
        ),
        "frequencies",
        "Frequencies",
        &{&1.id, semantic_content(&1)}
      ),
      stream_category(
        from(t in Trip,
          where: t.organization_id == ^org_id and t.gtfs_version_id == ^version_id,
          where: t.route_id == ^route_id,
          where: not is_nil(t.block_id),
          distinct: true,
          order_by: [t.block_id],
          select: t.block_id
        ),
        "blocks",
        "Block IDs affected",
        &{&1, &1}
      ),
      stream_category(
        from(tr in Transfer,
          where: tr.organization_id == ^org_id and tr.gtfs_version_id == ^version_id,
          where:
            tr.from_route_id == ^route_id or tr.to_route_id == ^route_id or
              tr.from_trip_id in ^trip_ids or tr.to_trip_id in ^trip_ids,
          order_by: [tr.id]
        ),
        "transfers",
        "Transfers",
        &{&1.id, semantic_content(&1)}
      ),
      stream_category(
        from(fr in FareRule,
          where: fr.organization_id == ^org_id and fr.gtfs_version_id == ^version_id,
          where: fr.route_id == ^route_id,
          order_by: [fr.id]
        ),
        "fare_rules",
        "Fare rules",
        &{&1.id, semantic_content(&1)}
      ),
      stream_category(
        from(a in Attribution,
          where: a.organization_id == ^org_id and a.gtfs_version_id == ^version_id,
          where: a.route_id == ^route_id or a.trip_id in ^trip_ids,
          order_by: [a.id]
        ),
        "attributions",
        "Attributions",
        &{&1.id, semantic_content(&1)}
      ),
      stream_category(
        from(rn in RouteNetwork,
          where: rn.organization_id == ^org_id and rn.gtfs_version_id == ^version_id,
          where: rn.route_id == ^route_id,
          order_by: [rn.id]
        ),
        "route_networks",
        "Route network links",
        &{&1.id, semantic_content(&1)}
      ),
      stream_category(
        from(tr in Translation,
          where: tr.organization_id == ^org_id and tr.gtfs_version_id == ^version_id,
          where:
            (tr.table_name == "routes" and tr.record_id == ^route_id) or
              (tr.table_name == "trips" and tr.record_id in ^trip_ids) or
              (tr.table_name == "stop_times" and tr.record_id in ^trip_ids) or
              (tr.table_name == "attributions" and tr.record_id in ^attribution_ids),
          order_by: [tr.id]
        ),
        "translations",
        "Translations",
        &{&1.id, semantic_content(&1)}
      )
    ]

    retained = retained_summary(route, org_id, version_id, trip_ids)

    %{
      fingerprint: deletion_fingerprint(route, categories, retained),
      route_uuid: route.id,
      categories: categories,
      retained: retained,
      empty?: Enum.all?(categories, &(&1.key == "route" or &1.count == 0))
    }
  end

  defp route_category(route) do
    %{
      key: "route",
      label: "Route",
      count: 1,
      identities: [route.route_id],
      digest:
        Base.encode16(
          :crypto.hash(:sha256, [route.route_id, "\t", semantic_content(route), "\n"]),
          case: :lower
        )
    }
  end

  # Streams one affected set in a deterministic order and folds each semantic
  # row into an incremental SHA-256, so stop-time vectors never accumulate in
  # memory; only compact identity strings do.
  defp stream_category(query, key, label, row_fun) do
    {hash, identities, count} =
      query
      |> Repo.stream(max_rows: 1_000)
      |> Enum.reduce({:crypto.hash_init(:sha256), [], 0}, fn row, {hash, ids, seen} ->
        {identity, content} = row_fun.(row)
        {:crypto.hash_update(hash, [identity, "\t", content, "\n"]), [identity | ids], seen + 1}
      end)

    %{
      key: key,
      label: label,
      count: count,
      identities: Enum.sort(identities),
      digest: Base.encode16(:crypto.hash_final(hash), case: :lower)
    }
  end

  # Semantic row content for review digests: every persisted value except
  # scope and timestamps (update_all writers can preserve updated_at), keyed
  # deterministically so equal rows hash equally.
  defp semantic_content(row) do
    row
    |> Map.from_struct()
    |> Map.drop([:__meta__, :organization_id, :gtfs_version_id, :inserted_at, :updated_at])
    |> Enum.reject(fn {_key, value} -> match?(%Ecto.Association.NotLoaded{}, value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\u0001", fn {key, value} -> "#{key}=#{semantic_value(value)}" end)
  end

  defp semantic_value(nil), do: "nil"
  defp semantic_value(value) when is_binary(value), do: value
  defp semantic_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp semantic_value(value), do: inspect(value)

  # The retained-resource summary (seam S-3): imported shapes referenced by the
  # removed trips are retained and named, alongside the shared stops, calendars
  # and agency the cascade never touches.
  defp retained_summary(route, org_id, version_id, trip_ids) do
    route_id = route.route_id

    referenced_shape_ids =
      Repo.all(
        from(t in Trip,
          where: t.organization_id == ^org_id and t.gtfs_version_id == ^version_id,
          where: t.route_id == ^route_id,
          where: not is_nil(t.shape_id),
          distinct: true,
          select: t.shape_id
        )
      )

    imported_shape_ids =
      Repo.all(
        from(s in Shape,
          where: s.organization_id == ^org_id and s.gtfs_version_id == ^version_id,
          where: s.shape_id in ^referenced_shape_ids,
          distinct: true,
          order_by: [s.shape_id],
          select: s.shape_id
        )
      )

    stop_ids =
      Repo.all(
        from(st in StopTime,
          where: st.organization_id == ^org_id and st.gtfs_version_id == ^version_id,
          where: st.trip_id in ^trip_ids,
          where: not is_nil(st.stop_id),
          distinct: true,
          order_by: [st.stop_id],
          select: st.stop_id
        )
      )

    service_ids =
      Repo.all(
        from(t in Trip,
          where: t.organization_id == ^org_id and t.gtfs_version_id == ^version_id,
          where: t.route_id == ^route_id,
          where: not is_nil(t.service_id),
          distinct: true,
          order_by: [t.service_id],
          select: t.service_id
        )
      )

    agency_ids = if route.agency_id, do: [route.agency_id], else: []

    [
      retained_entry("shapes", "Imported shapes retained", imported_shape_ids),
      retained_entry("stops", "Shared stops retained", stop_ids),
      retained_entry("calendars", "Calendars retained", service_ids),
      retained_entry("agencies", "Agencies retained", agency_ids)
    ]
  end

  defp retained_entry(key, label, identities) do
    %{
      key: key,
      label: label,
      count: length(identities),
      identities: Enum.sort(identities)
    }
  end

  defp deletion_fingerprint(route, categories, retained) do
    category_lines =
      Enum.map(categories, fn category ->
        Enum.join(
          [
            category.key,
            Integer.to_string(category.count),
            Enum.join(category.identities, "\u0001"),
            category.digest
          ],
          "\t"
        )
      end)

    retained_lines =
      Enum.map(retained, fn entry ->
        Enum.join(
          [entry.key, Integer.to_string(entry.count), Enum.join(entry.identities, "\u0001")],
          "\t"
        )
      end)

    ["review_route_deletion", route.organization_id, route.gtfs_version_id, route.id]
    |> Enum.concat(category_lines)
    |> Enum.concat(retained_lines)
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Malformed cross-route timing ownership blocks the review atomically (AC-31):
  # a trip whose linked timing belongs to another route's pattern, or a timing
  # row whose occurrence belongs to another route's pattern, cannot be removed
  # by one route's cascade without touching the other route's rows.
  defp check_cross_route_timing!(org_id, version_id, route_id) do
    trip_timing_crossing =
      Repo.exists?(
        from(t in Trip,
          join: tp in TimedPattern,
          on: tp.id == t.timed_pattern_id,
          join: p in RoutePattern,
          on: p.id == tp.route_pattern_id,
          where: t.organization_id == ^org_id and t.gtfs_version_id == ^version_id,
          where: tp.organization_id == ^org_id and tp.gtfs_version_id == ^version_id,
          where: p.organization_id == ^org_id and p.gtfs_version_id == ^version_id,
          where: t.route_id != p.route_id,
          where: t.route_id == ^route_id or p.route_id == ^route_id
        )
      )

    timing_rows_crossing =
      Repo.exists?(
        from(tps in TimedPatternStop,
          join: tp in TimedPattern,
          on: tp.id == tps.timed_pattern_id,
          join: owning in RoutePattern,
          on: owning.id == tp.route_pattern_id,
          join: rps in RoutePatternStop,
          on: rps.id == tps.route_pattern_stop_id,
          join: visited in RoutePattern,
          on: visited.id == rps.route_pattern_id,
          where: owning.organization_id == ^org_id and owning.gtfs_version_id == ^version_id,
          where: visited.organization_id == ^org_id and visited.gtfs_version_id == ^version_id,
          where: owning.route_id != visited.route_id,
          where: owning.route_id == ^route_id or visited.route_id == ^route_id
        )
      )

    if trip_timing_crossing or timing_rows_crossing,
      do: Repo.rollback(:malformed_cross_route_timing),
      else: :ok
  end
end
