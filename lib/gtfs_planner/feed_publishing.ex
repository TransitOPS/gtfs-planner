defmodule GtfsPlanner.FeedPublishing do
  @moduledoc """
  Durable state for public feed publication: the claimed namespace, each
  organization's channel state, and the attempts that install it.

  This module owns public intent, not public bytes. `claim_namespace/1` and the
  channel/attempt records are the only durable truth about what has been asked
  for and what the served manifest last proved; which generation is actually
  current belongs to the storage provider and the independent consumer.

  Every interactive write takes the actor's *current* editor membership with
  `Authorization.lock_editor!/1` before it reads or inserts anything else, so a
  permission revoked after a page loaded refuses the write (INV-1, CR-2). A first
  claim is then decided by the unique indexes on
  `feed_publication_namespaces`: the namespace is inserted once with
  `ON CONFLICT DO NOTHING`, so two racing claims of the same alias resolve to the
  same single owner without one of them aborting its transaction or taking a
  conflicting organization row lock.

  Organization identity and the prefix both come from trusted server context.
  The prefix is the organization's current alias captured at the first claim, so a
  later rename preserves the claimed prefix and another tenant cannot adopt it.
  Unsafe or reserved segments are refused visibly and never rename the
  organization.

  Organization deletion is refused while publication state remains:
  `publications_blocking_deletion/1` is the application's guard and the tables'
  `ON DELETE RESTRICT` foreign keys are the database's.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Alerts.Publication, as: AlertPublication
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.Manifest
  alias GtfsPlanner.FeedPublishing.Namespace
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.FeedPublishing.Publisher
  alias GtfsPlanner.FeedPublishing.StaticArtifact
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @preview_salt "feed_publishing.static_preview"
  @preview_max_age 900
  @static_slots [:main, :flex]
  @slot_names %{"main" => :main, "flex" => :flex}
  @profile_channels %{static: :full, flex: :flex, pathways: :pathways}
  @profile_names %{"static" => :static, "flex" => :flex, "pathways" => :pathways}
  @channel_zip %{full: "gtfs.zip", flex: "gtfs-flex.zip", pathways: "pathways.zip"}
  @channel_public_path %{
    full: "static/gtfs.zip",
    flex: "static/gtfs-flex.zip",
    pathways: "static/pathways.zip"
  }

  @typedoc "One advisory mismatch notice shown with a ready preview."
  @type notice :: %{
          alert_id: term(),
          alert_name: term(),
          reason: atom(),
          ids: [String.t() | [String.t()]]
        }

  @typedoc "The server-owned consent surface a ready static preview returns."
  @type preview :: %{
          token: String.t(),
          organization_id: Ecto.UUID.t(),
          run_id: Ecto.UUID.t(),
          slot: :main | :flex,
          profile: :static | :flex | :pathways,
          channel: :full | :flex | :pathways,
          destination_revision: integer(),
          destination_url: String.t() | nil,
          artifact_sha256: String.t(),
          size_bytes: non_neg_integer() | nil,
          report_id: Ecto.UUID.t(),
          errors_count: integer(),
          warnings_count: integer(),
          infos_count: integer(),
          inventory: [String.t()],
          inventory_digest: String.t(),
          notices: [notice()]
        }

  @prefix_pattern ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
  @max_prefix_length 255
  @reserved_prefixes ~w(images fonts)
  @public_claim_bytes 24

  @type error ::
          :forbidden
          | :not_found
          | :invalid_prefix
          | :reserved_prefix
          | :prefix_taken
          | Ecto.Changeset.t()

  @doc """
  Claims, or returns, the organization's permanent public namespace.

  The first deliberate publication claims the current `Organization.alias` as the
  public prefix with fresh random `public_claim`. Later calls return the claimed
  namespace unchanged, so a rename does not move published files.

  ## Examples

      iex> claim_namespace(scope)
      {:ok, %Namespace{prefix: "rivercity"}}

      iex> claim_namespace(scope)
      {:error, :invalid_prefix}

      iex> claim_namespace(scope_for_deactivated_member)
      {:error, :forbidden}
  """
  @spec claim_namespace(map()) :: {:ok, Namespace.t()} | {:error, error()}
  def claim_namespace(scope) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(scope)

      with {:ok, organization_id} <- cast_organization_id(scope),
           %Organization{} = organization <- Repo.get(Organization, organization_id) do
        claim(organization_id, organization.alias)
      else
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  @doc """
  Claims the organization's permanent namespace from trusted server state.

  This is the system-owned sibling of `claim_namespace/1`: the periodic
  publisher calls it for an organization that already has accepted public
  intent but no claimed namespace yet. It takes no actor, because there is
  none for a background tick, and no client value: the prefix is the
  organization's own current alias, exactly as the interactive claim would use
  it, and the claim is fresh randomness. A reserved or unusable alias is
  refused the same way an interactive claim refuses it.

  An organization with no accepted intent must not go through here; that is
  what keeps a configured installation from publishing an organization that
  never asked to be public.
  """
  @spec ensure_namespace_for(Ecto.UUID.t()) :: {:ok, Namespace.t()} | {:error, error()}
  def ensure_namespace_for(organization_id) do
    Repo.transaction(fn ->
      case Ecto.UUID.cast(organization_id) do
        {:ok, id} -> ensure_namespace_locked(id)
        :error -> Repo.rollback(:not_found)
      end
    end)
  end

  defp ensure_namespace_locked(id) do
    case Repo.get_by(Namespace, organization_id: id) do
      %Namespace{} = namespace -> namespace
      nil -> claim_from_organization(id)
    end
  end

  defp claim_from_organization(id) do
    case Repo.get(Organization, id) do
      %Organization{alias: alias} -> claim(id, alias)
      nil -> Repo.rollback(:not_found)
    end
  end

  @doc """
  Lists the organization's channel states for the publish and status screens.

  ## Examples

      iex> status(scope)
      {:ok, [%Publication{channel: :alerts}]}

      iex> status(scope_without_membership)
      {:error, :forbidden}
  """
  @spec status(map()) :: {:ok, [Publication.t()]} | {:error, :forbidden}
  def status(scope) do
    with :ok <- Authorization.authorize_editor(scope),
         {:ok, organization_id} <- cast_organization_id(scope) do
      publications =
        from(publication in Publication,
          where: publication.organization_id == ^organization_id,
          order_by: [asc: publication.channel],
          preload: [:namespace, :active_attempt]
        )
        |> Repo.all()

      {:ok, publications}
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc """
  Returns the organization's channels while publication state still exists.

  `Organizations.delete_organization/1` calls this inside its transaction: a
  namespace, its channel state and their attempts outlive the organization row,
  so deletion is refused until an operator withdraws publication under separate
  authority.
  """
  @spec publications_blocking_deletion(Ecto.UUID.t()) :: [Publication.t()]
  def publications_blocking_deletion(organization_id) do
    Repo.all(
      from(publication in Publication,
        where: publication.organization_id == ^organization_id,
        select: publication.channel,
        order_by: [asc: publication.channel]
      )
    )
  end

  @doc """
  Advances one channel's active attempt through staging and the conditional
  manifest switch, returning the truth about what is now served.

  This is the system delivery entry point: it needs no browser, reads the
  durable attempt the channel command froze, and runs only when publishing is
  configured. It never allocates a generation, never rebases an attempt and
  never acknowledges a newer desired revision using an older attempt.

  ## Examples

      iex> advance(publication_id)
      {:ok, :current}

      iex> advance(publication_id)
      {:error, :disabled}

      iex> advance(publication_id)
      {:error, :no_attempt}
  """
  @spec advance(Ecto.UUID.t()) ::
          {:ok, :current | :pending | :superseded} | {:error, atom()}
  def advance(publication_id) do
    case Config.current() do
      {:enabled, config} -> advance(publication_id, config)
      :disabled -> {:error, :disabled}
    end
  end

  defp advance(publication_id, config) do
    case Ecto.UUID.cast(publication_id) do
      {:ok, id} ->
        case Repo.get(Publication, id, preload: [:namespace]) do
          nil -> {:error, :not_found}
          publication -> advance_attempt(config, publication)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp advance_attempt(_config, %Publication{active_attempt_id: nil}), do: {:error, :no_attempt}

  defp advance_attempt(config, %Publication{active_attempt_id: attempt_id} = publication) do
    case Repo.get(Attempt, attempt_id) do
      nil -> {:error, :no_attempt}
      attempt -> Publisher.advance(config, publication, attempt)
    end
  end

  @doc """
  Reclaims safely retired payload objects for every channel, at most `limit` per call.

  This is the system delivery entry point for retention: it drives the concrete
  `Storage` list/head/delete boundary and never performs a generic bucket sweep.
  It confirms the current manifest before deleting anything, protects the
  current manifest's keys and every unresolved attempt's keys, observes the
  24-hour retirement grace, advances the channel's contiguous retirement
  watermark before pruning attempt rows, and leaves every byte and record in
  place when storage is unavailable or publishing is disabled.

  ## Examples

      iex> collect_retired(~U[2026-10-03 12:00:00Z])
      {:ok, 0}
  """
  @spec collect_retired(DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def collect_retired(now \\ DateTime.utc_now(), limit \\ 100) do
    Publisher.collect_retired(now, limit)
  end

  @doc """
  Reviews one selected export artifact and returns a server-signed consent token.

  Nothing the client sends is trusted beyond the run id and the trusted slot:
  the artifact bytes, its hash, the emitted profile, the extension/image
  inventory and the mismatch notices all come from the run row and the pinned
  file. The selected artifact is validated through the existing artifact runner
  (`Validations.start_artifact_run/3`) and reused when the same run, slot and
  hash already has a completed report, so an unchanged review is not repeated.

  Returns `{:pending, validation_run_id}` while that hash-bound report is still
  running, `{:ok, preview}` once a completed report exists, and `{:error, reason}`
  for an ineligible profile, an operations/TODS archive, a failed validator, a
  disabled capability or a missing artifact. `preview` binds the artifact hash,
  the completed report, the inventory digest and the destination revision in a
  `Phoenix.Token` valid for 15 minutes.
  """
  @spec preview_static(map(), Ecto.UUID.t(), :main | :flex) ::
          {:ok, preview()} | {:pending, Ecto.UUID.t()} | {:error, term()}
  def preview_static(scope, run_id, slot) when slot in @static_slots do
    case Config.current() do
      {:enabled, config} -> preview_static_enabled(config, scope, run_id, slot)
      :disabled -> {:error, :disabled}
    end
  end

  def preview_static(_scope, _run_id, _slot), do: {:error, :invalid_slot}

  defp preview_static_enabled(config, scope, run_id, slot) do
    with {:ok, organization_id} <- cast_organization_id(scope),
         :ok <- Authorization.authorize_editor(scope),
         {:ok, run_id} <- cast_optional_uuid(run_id),
         %Run{} = run <- ExportRuns.get_scoped_run(organization_id, run_id) do
      case artifact_digest(run, slot) do
        nil -> {:error, :not_found}
        digest -> preview_for(config, scope, organization_id, run, slot, digest)
      end
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp preview_for(config, scope, organization_id, run, slot, digest) do
    cond do
      review = completed_artifact_run(organization_id, run.id, slot, digest) ->
        build_preview(config, scope, organization_id, run, slot, digest, review)

      review = in_flight_artifact_run(organization_id, run.id, slot, digest) ->
        {:pending, review.id}

      true ->
        start_validation(config, scope, organization_id, run, slot, digest)
    end
  end

  defp start_validation(config, scope, organization_id, run, slot, digest) do
    case Validations.start_artifact_run(scope, run.id, slot) do
      {:ok, %ValidationRun{status: "completed"} = review} ->
        build_preview(config, scope, organization_id, run, slot, digest, review)

      {:ok, %ValidationRun{id: id}} ->
        {:pending, id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_preview(config, scope, organization_id, run, slot, digest, review) do
    with {:ok, inspected} <- inspect_artifact(run, slot),
         {:ok, namespace} <- claim_namespace(scope) do
      channel = Map.fetch!(@profile_channels, inspected.profile)
      inventory_digest = StaticArtifact.inventory_digest(inspected.inventory)
      destination_revision = destination_revision(organization_id, channel)

      payload = %{
        "organization_id" => organization_id,
        "actor_id" => actor_id(scope),
        "run_id" => run.id,
        "slot" => Atom.to_string(slot),
        "profile" => Atom.to_string(inspected.profile),
        "channel" => Atom.to_string(channel),
        "artifact_sha256" => digest,
        "report_id" => review.id,
        "inventory_digest" => inventory_digest,
        "destination_revision" => destination_revision,
        "issued_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok,
       %{
         token: Phoenix.Token.sign(GtfsPlannerWeb.Endpoint, @preview_salt, payload),
         organization_id: organization_id,
         run_id: run.id,
         slot: slot,
         profile: inspected.profile,
         channel: channel,
         destination_revision: destination_revision,
         destination_url: destination_url(config, namespace, channel),
         artifact_sha256: digest,
         size_bytes: artifact_size(run, slot),
         report_id: review.id,
         errors_count: review.errors_count,
         warnings_count: review.warnings_count,
         infos_count: review.infos_count,
         inventory: inspected.inventory,
         inventory_digest: inventory_digest,
         notices: accepted_notices(organization_id, inspected.catalog)
       }}
    end
  end

  @doc """
  Queues one reviewed static publication from a ready preview consent token.

  Confirmation re-verifies the token's signature and age, the current editor
  membership, the bound report and artifact hash, the current destination
  revision and the still-pinned artifact bytes. A report with errors proceeds
  only with an explicit `confirm_errors?: true`; a failed or unreviewed report,
  a changed destination revision or an expired artifact is refused with a typed
  error and nothing is queued.

  On success it persists the publisher intent - a frozen attempt with the
  reviewed artifact hash, its immutable payload key and the exact manifest bytes
  - and returns the channel's `publication_id`. The periodic publisher owns
  every remote effect after that.
  """
  @spec publish_static(map(), binary(), integer(), keyword()) ::
          {:ok, Ecto.UUID.t()} | {:error, term()}
  def publish_static(scope, preview_id, expected_destination_revision, opts \\ []) do
    case Config.current() do
      {:enabled, _config} ->
        publish_static_enabled(scope, preview_id, expected_destination_revision, opts)

      :disabled ->
        {:error, :disabled}
    end
  end

  defp publish_static_enabled(scope, preview_id, expected, opts) do
    with {:ok, payload} <- verify_preview(scope, preview_id, expected),
         :ok <- Authorization.authorize_editor(scope),
         {:ok, review} <- bound_review(payload),
         :ok <- confirm_errors(review, opts),
         {:ok, _namespace} <- claim_namespace(scope),
         {:ok, run} <- scoped_run(payload),
         {:ok, pin} <- reacquire_pin(run, payload) do
      enqueue(scope, payload, run, pin, review)
    end
  end

  defp verify_preview(scope, preview_id, expected) when is_binary(preview_id) do
    case Phoenix.Token.verify(
           GtfsPlannerWeb.Endpoint,
           @preview_salt,
           preview_id,
           max_age: @preview_max_age
         ) do
      {:ok, %{"organization_id" => organization_id} = payload} ->
        cond do
          not match_organization?(scope, organization_id) -> {:error, :forbidden}
          payload["destination_revision"] != expected -> {:error, :stale_destination}
          true -> {:ok, payload}
        end

      {:error, :expired} ->
        {:error, :expired_preview}

      {:error, _reason} ->
        {:error, :invalid_preview}
    end
  end

  defp verify_preview(_scope, _preview_id, _expected), do: {:error, :invalid_preview}

  defp match_organization?(scope, organization_id) do
    case cast_organization_id(scope) do
      {:ok, id} -> id == organization_id
      :error -> false
    end
  end

  # The token can only have been issued for a completed report; this re-reads
  # the current row so a report that failed or was replaced after consent is
  # refused rather than acknowledged.
  defp bound_review(payload) do
    review = Validations.get_validation_run(payload["report_id"])

    cond do
      is_nil(review) -> {:error, :stale_review}
      review.artifact_sha256 != payload["artifact_sha256"] -> {:error, :stale_review}
      review.artifact_export_run_id != payload["run_id"] -> {:error, :stale_review}
      review.status == "failed" -> {:error, :validation_failed}
      review.status != "completed" -> {:error, :review_pending}
      true -> {:ok, review}
    end
  end

  defp confirm_errors(%ValidationRun{errors_count: count}, opts) when count > 0 do
    if Keyword.get(opts, :confirm_errors?, false) do
      :ok
    else
      {:error, {:errors_require_confirmation, count}}
    end
  end

  defp confirm_errors(_review, _opts), do: :ok

  defp scoped_run(payload) do
    case ExportRuns.get_scoped_run(payload["organization_id"], payload["run_id"]) do
      %Run{} = run -> {:ok, run}
      nil -> {:error, :artifact_unavailable}
    end
  end

  # Reacquire the artifact the consent was given for. The bytes must still hash
  # to the reviewed digest; an expired file is `:artifact_unavailable` and
  # requires a new export, never a rebuild behind the same consent.
  defp reacquire_pin(run, payload) do
    slot = Map.fetch!(@slot_names, payload["slot"])
    owner = "static-publish:" <> payload["report_id"]

    case ExportRuns.pin_publication(run.organization_id, run.gtfs_version_id, run.id, slot, owner) do
      {:ok, pin} ->
        if pin.sha256 == payload["artifact_sha256"] do
          {:ok, Map.put(pin, :owner_id, owner)}
        else
          {:error, :artifact_unavailable}
        end

      {:error, :not_found} ->
        {:error, :artifact_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue(scope, payload, run, pin, review) do
    organization_id = payload["organization_id"]
    channel = Map.fetch!(@profile_channels, profile_atom(payload["profile"]))
    slot = Map.fetch!(@slot_names, payload["slot"])
    expected = payload["destination_revision"]

    case Repo.transaction(fn ->
           Authorization.lock_editor!(scope)
           publication = lock_or_create_publication(organization_id, channel)
           ensure_revision!(publication, expected)
           insert_attempt(publication, scope, payload, run, pin, review, channel, slot)
         end) do
      {:ok, publication} -> {:ok, publication.id}
      {:error, :stale_destination} -> {:error, :stale_destination}
      {:error, reason} -> {:error, reason}
    end
  end

  # The destination revision the consent was given for must still be the channel's
  # current one; a newer intent makes the consent stale rather than silently
  # replacing a newer public feed.
  defp ensure_revision!(publication, expected) do
    if publication.desired_revision != expected do
      Repo.rollback(:stale_destination)
    end

    :ok
  end

  defp lock_or_create_publication(organization_id, channel) do
    namespace = Repo.get_by!(Namespace, organization_id: organization_id)

    case Repo.get_by(Publication, organization_id: organization_id, channel: channel) do
      %Publication{} = existing ->
        Repo.one!(from p in Publication, where: p.id == ^existing.id, lock: "FOR UPDATE")

      nil ->
        %Publication{
          organization_id: organization_id,
          namespace_id: namespace.id,
          channel: channel
        }
        |> Ecto.Changeset.change()
        |> Repo.insert(on_conflict: :nothing)

        Repo.one!(
          from p in Publication,
            where: p.organization_id == ^organization_id and p.channel == ^channel,
            lock: "FOR UPDATE"
        )
    end
  end

  defp insert_attempt(publication, scope, payload, run, pin, review, channel, slot) do
    namespace = Repo.get!(Namespace, publication.namespace_id)
    sequence = publication.next_sequence
    generation = Ecto.UUID.generate()
    key = "#{namespace.prefix}/static/objects/#{generation}/#{Map.fetch!(@channel_zip, channel)}"

    attempt = %Attempt{
      publication_id: publication.id,
      organization_id: publication.organization_id,
      sequence: sequence,
      generation: generation,
      desired_revision: publication.desired_revision + 1,
      predecessor_etag: publication.manifest_etag,
      object_receipts: %{
        "zip" => %{
          "key" => key,
          "sha256" => pin.sha256,
          "bytes" => pin.size,
          "content_type" => "application/zip"
        }
      },
      private_snapshot: %{
        "objects" => %{"zip" => %{"file" => pin.path}},
        "pin" => %{"owner_id" => pin.owner_id, "pin_token" => pin.pin_token},
        "review" => report_fingerprint(payload, review),
        "source" => %{
          "run_id" => run.id,
          "slot" => Atom.to_string(slot),
          "filename" => pin.filename,
          "export_type" => Atom.to_string(run.export_type)
        }
      },
      actor_id: actor_id(scope),
      provenance: "export-run:#{run.id}",
      state: "pending"
    }

    case Manifest.encode(%{attempt | publication: %{publication | namespace: namespace}}) do
      {:ok, body} ->
        attempt =
          Repo.insert!(%{attempt | manifest_body: body, manifest_sha256: sha256_hex(body)})

        publication
        |> Ecto.Changeset.change(%{
          desired_revision: publication.desired_revision + 1,
          next_sequence: sequence + 1,
          active_attempt_id: attempt.id,
          status: :pending,
          next_retry_at: nil,
          last_error: nil
        })
        |> Repo.update!()

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp report_fingerprint(payload, review) do
    %{
      "report_id" => payload["report_id"],
      "artifact_sha256" => payload["artifact_sha256"],
      "inventory_digest" => payload["inventory_digest"],
      "destination_revision" => payload["destination_revision"],
      "issued_at" => payload["issued_at"],
      "errors_count" => review.errors_count,
      "warnings_count" => review.warnings_count,
      "infos_count" => review.infos_count,
      "engine" => review.engine
    }
  end

  # Pin the exact reviewed bytes, inspect them and release the pin again: the
  # consent screen is built while the artifact is leased, and a ready preview
  # never keeps the private file from being cleaned up.
  defp inspect_artifact(run, slot) do
    owner = "static-preview:" <> Ecto.UUID.generate()

    case ExportRuns.pin_publication(run.organization_id, run.gtfs_version_id, run.id, slot, owner) do
      {:ok, pin} ->
        try do
          StaticArtifact.inspect(%{
            path: pin.path,
            filename: pin.filename,
            export_type: run.export_type,
            slot: slot,
            sha256: pin.sha256
          })
        after
          _ =
            ExportRuns.release_publication_pin(run.organization_id, run.id, %{
              owner_id: owner,
              pin_token: pin.pin_token
            })
        end

      {:error, :not_found} ->
        {:error, :artifact_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp completed_artifact_run(organization_id, run_id, slot, digest) do
    Repo.one(
      from r in ValidationRun,
        where:
          r.organization_id == ^organization_id and r.artifact_export_run_id == ^run_id and
            r.artifact_slot == ^slot and r.artifact_sha256 == ^digest and r.status == "completed",
        order_by: [desc: r.completed_at, desc: r.inserted_at],
        limit: 1
    )
  end

  defp in_flight_artifact_run(organization_id, run_id, slot, digest) do
    Repo.one(
      from r in ValidationRun,
        where:
          r.organization_id == ^organization_id and r.artifact_export_run_id == ^run_id and
            r.artifact_slot == ^slot and r.artifact_sha256 == ^digest and
            r.status in ["pending", "started", "running"],
        order_by: [desc: r.inserted_at],
        limit: 1
    )
  end

  defp accepted_notices(organization_id, catalog) do
    StaticArtifact.mismatches(catalog, accepted_snapshots(organization_id))
  end

  # Both the newest desired intent and the last confirmed content are compared:
  # a notice is information about what the selected bytes would change, and it
  # neither blocks the publication nor writes to any alert row.
  defp accepted_snapshots(organization_id) do
    from(p in AlertPublication,
      where: p.organization_id == ^organization_id,
      select: %{
        alert_id: p.alert_id,
        desired: p.desired_snapshot,
        confirmed: p.confirmed_snapshot
      }
    )
    |> Repo.all()
    |> Enum.flat_map(&snapshot_notice_inputs/1)
    |> Enum.uniq_by(&{&1.id, &1.accepted_revision})
  end

  defp snapshot_notice_inputs(row) do
    [row.desired, row.confirmed]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn stored ->
      snapshot = AlertPublication.snapshot_from_stored(stored)

      %{
        id: row.alert_id,
        name: Map.get(snapshot, :header),
        selectors: selectors_from_scope(Map.get(snapshot, :scope)),
        accepted_revision: Map.get(snapshot, :accepted_revision)
      }
    end)
  end

  defp selectors_from_scope(scope) when is_map(scope) do
    %{
      agency_ids: Map.get(scope, :agencies, []),
      route_ids: Map.get(scope, :routes, []),
      stop_ids: Map.get(scope, :stops, []),
      route_stops: Map.get(scope, :route_stops, []),
      trips: Map.get(scope, :trips, [])
    }
  end

  defp selectors_from_scope(_scope), do: %{}

  defp destination_revision(organization_id, channel) do
    case Repo.get_by(Publication, organization_id: organization_id, channel: channel) do
      %Publication{desired_revision: revision} -> revision
      nil -> 0
    end
  end

  defp destination_url(config, %Namespace{prefix: prefix}, channel) do
    config.public_base_url
    |> URI.merge("/#{prefix}/#{Map.fetch!(@channel_public_path, channel)}")
    |> URI.to_string()
  end

  defp artifact_digest(run, :main), do: run.artifact_sha256
  defp artifact_digest(run, :flex), do: run.flex_artifact_sha256

  defp artifact_size(run, :main), do: run.artifact_size_bytes
  defp artifact_size(run, :flex), do: run.flex_artifact_size_bytes

  defp profile_atom(name), do: Map.fetch!(@profile_names, name)

  defp cast_optional_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_optional_uuid(_value), do: :error

  defp actor_id(%{actor_id: actor_id}), do: actor_id
  defp actor_id(_scope), do: nil

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp claim(organization_id, alias) do
    case validate_prefix(alias) do
      {:ok, prefix} -> insert_claim(organization_id, prefix)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_claim(organization_id, prefix) do
    # A read first keeps a repeated claim free of a deliberate constraint
    # violation. When nothing is claimed yet, the insert alone decides the winner.
    # `ON CONFLICT DO NOTHING` covers every unique index at once, so a loser
    # neither aborts the transaction nor waits to be told which index it lost.
    # `Repo.insert/2` always answers `{:ok, struct}`, and on a conflict that struct
    # is the skipped insert with a generated id that was never written, so the
    # winner is read back by its owning organization rather than trusted here.
    case Repo.get_by(Namespace, organization_id: organization_id) do
      %Namespace{} = claimed ->
        claimed

      nil ->
        case Repo.insert(
               Namespace.claim_changeset(organization_id, prefix, random_claim()),
               on_conflict: :nothing
             ) do
          {:ok, %Namespace{}} ->
            claimed_namespace(organization_id) || Repo.rollback(:prefix_taken)

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  # Another first claim won this organization. Its claimed prefix is the permanent
  # one, so a racing claim of the same alias and any claim made after a rename both
  # return that same row instead of moving published files.
  defp claimed_namespace(organization_id) do
    Repo.get_by(Namespace, organization_id: organization_id)
  end

  # One lowercase URL-safe segment: alphanumeric ends, internal hyphens, no other
  # punctuation. `images` and `fonts` are reserved because the serving layer owns
  # those paths.
  defp validate_prefix(alias) when is_binary(alias) do
    prefix = String.downcase(String.trim(alias))

    cond do
      String.length(prefix) > @max_prefix_length -> {:error, :invalid_prefix}
      not Regex.match?(@prefix_pattern, prefix) -> {:error, :invalid_prefix}
      prefix in @reserved_prefixes -> {:error, :reserved_prefix}
      true -> {:ok, prefix}
    end
  end

  defp validate_prefix(_), do: {:error, :invalid_prefix}

  defp random_claim do
    @public_claim_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp cast_organization_id(%{organization_id: organization_id}) do
    Ecto.UUID.cast(organization_id)
  end

  defp cast_organization_id(_), do: :error
end
