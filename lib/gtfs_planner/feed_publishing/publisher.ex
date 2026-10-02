defmodule GtfsPlanner.FeedPublishing.Publisher do
  @moduledoc """
  Drives one frozen publication attempt to a truthfully confirmed manifest.

  An attempt is the durable work item: the channel command allocates its
  sequence and fresh generation, freezes the exact manifest bytes and its
  expected predecessor ETag, and records the immutable payload objects the
  manifest will name. `advance/3` is the only delivery step, and it never
  changes those frozen values. A new predecessor or a changed desired revision
  needs a new authorized attempt; a retry always replays this one.

  The step is deliberately conservative, because a database commit and an object
  store write are separate effects:

    1. Claim the attempt with a lease. Only the winner sends. Another node's
       live lease defers as `:pending`.
    2. Stage every immutable payload first and verify the existing object when a
       reserved key is already taken. No manifest is written while any payload
       is unconfirmed.
    3. Replace the one manifest with the frozen condition: `If-None-Match: *`
       for a first creation, `If-Match` of the frozen predecessor otherwise.
    4. A lost condition, a timeout or an unreadable outcome is not a failure and
       never rebases the attempt onto a freshly read ETag. The publisher reads
       the manifest back: if it equals this attempt the receipt is completed
       without resending, if a newer owned generation is current the attempt is
       retired as `:superseded`, and anything else is a visible `:blocked`
       conflict.
    5. The receipt is persisted only from the verified manifest, and only when
       the attempt still matches the channel's desired revision.

  A `:pending` result is normal progress: the frozen intent is kept and the next
  tick replays exactly it. Retired or blocked attempts remain rows until a later
  collection step fences them.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.Manifest
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.FeedPublishing.Storage
  alias GtfsPlanner.Repo

  @lease_seconds 180
  @retry_seconds 30

  @type advance_result :: {:ok, :current | :pending | :superseded} | {:error, atom()}

  @doc """
  Advances one attempt through staging, the conditional manifest switch and
  receipt reconciliation.

  Returns `{:ok, :current}` when this attempt is the served manifest,
  `{:ok, :pending}` when work remains for a later retry, `{:ok, :superseded}`
  when a newer owned generation or intent has taken over, and `{:error, _}` for
  a definitive refusal such as a foreign object at a reserved key.
  """
  @spec advance(Config.t(), Publication.t(), Attempt.t()) :: advance_result()
  def advance(%Config{} = config, %Publication{} = publication, %Attempt{} = attempt) do
    case claim(publication, attempt) do
      {:claimed, claimed, mode} -> run(config, claimed, mode)
      {:done, result} -> result
      :busy -> {:ok, :pending}
      {:stale, stale} -> stale(config, stale)
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Claiming -------------------------------------------------------------

  defp claim(publication, attempt) do
    case Repo.transaction(fn -> claim_locked(publication.id, attempt.id) end) do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_locked(publication_id, attempt_id) do
    publication =
      Repo.one!(from p in Publication, where: p.id == ^publication_id, lock: "FOR UPDATE")

    attempt =
      Repo.one!(
        from a in Attempt,
          where: a.id == ^attempt_id,
          lock: "FOR UPDATE",
          preload: [publication: :namespace]
      )

    cond do
      attempt.state == "blocked" ->
        {:done, {:error, :blocked}}

      attempt.state == "superseded" ->
        {:done, {:ok, :superseded}}

      attempt.state == "current" and attempt.desired_revision == publication.desired_revision ->
        {:done, {:ok, :current}}

      attempt.desired_revision != publication.desired_revision ->
        {:stale, attempt}

      lease_live?(attempt) ->
        :busy

      true ->
        {:claimed, claim_lease(attempt),
         if(attempt.state == "switching", do: :retry, else: :fresh)}
    end
  end

  defp claim_lease(attempt) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    Repo.update!(
      Ecto.Changeset.change(attempt, %{
        lease_token: token,
        lease_expires_at: DateTime.add(DateTime.utc_now(), @lease_seconds),
        state: "switching"
      })
    )
  end

  defp lease_live?(%Attempt{lease_token: token, lease_expires_at: %DateTime{} = expires})
       when is_binary(token) do
    DateTime.compare(expires, DateTime.utc_now()) == :gt
  end

  defp lease_live?(_attempt), do: false

  # -- Driving the attempt --------------------------------------------------

  defp run(config, attempt, :fresh), do: write_manifest(config, attempt)

  defp run(config, attempt, :retry) do
    case reconcile(config, attempt) do
      :install -> write_manifest(config, attempt)
      {:current, etag, last_modified} -> complete(attempt, etag, last_modified)
      :superseded -> supersede(attempt, attempt.lease_token)
      :blocked -> block(attempt, "the current manifest belongs to another owner")
      :pending -> mark_pending(attempt, nil)
    end
  end

  # Stage the payloads first; the manifest never switches while any object is
  # unconfirmed. Then replace the single manifest with the frozen condition.
  defp write_manifest(config, attempt) do
    case stage_payloads(config, attempt) do
      :ok -> switch_manifest(config, attempt)
      {:pending, reason} -> mark_pending(attempt, reason)
      {:error, reason} -> block(attempt, describe(reason))
    end
  end

  defp switch_manifest(config, attempt) do
    case Storage.put_manifest(
           config,
           manifest_key(attempt),
           attempt.manifest_body,
           condition(attempt)
         ) do
      {:ok, receipt} ->
        complete(attempt, receipt.etag, receipt.last_modified)

      {:error, :precondition_failed} ->
        after_uncertain(config, attempt)

      {:error, :unknown} ->
        after_uncertain(config, attempt)

      {:error, reason} ->
        mark_pending(attempt, describe(reason))
    end
  end

  # A lost condition or a timeout means the outcome is unknown, not a failure.
  # Read the manifest back and settle on what is actually served. The frozen
  # predecessor is never replaced with the freshly read ETag.
  defp after_uncertain(config, attempt) do
    case reconcile(config, attempt) do
      :install -> mark_pending(attempt, "the manifest write outcome is unconfirmed")
      {:current, etag, last_modified} -> complete(attempt, etag, last_modified)
      :superseded -> supersede(attempt, attempt.lease_token)
      :blocked -> block(attempt, "the current manifest belongs to another owner")
      :pending -> mark_pending(attempt, nil)
    end
  end

  defp reconcile(config, attempt) do
    case Storage.read_manifest(config, manifest_key(attempt)) do
      :missing ->
        if condition(attempt) == :absent, do: :install, else: :blocked

      {:ok, body, etag, last_modified} ->
        cond do
          body == attempt.manifest_body -> {:current, etag, last_modified}
          predecessor?(attempt, etag) -> :install
          owned_newer?(attempt, body) -> :superseded
          true -> :blocked
        end

      {:error, _reason} ->
        :pending
    end
  end

  defp predecessor?(%Attempt{predecessor_etag: etag}, etag) when is_binary(etag), do: true
  defp predecessor?(_attempt, _etag), do: false

  defp owned_newer?(attempt, body) do
    case Jason.decode(body) do
      {:ok, decoded} -> newer_owned?(decoded, attempt)
      _ -> false
    end
  end

  defp newer_owned?(
         %{
           "schema" => 1,
           "namespace" => prefix,
           "claim" => claim,
           "channel" => channel,
           "sequence" => sequence
         },
         attempt
       )
       when is_integer(sequence) do
    namespace = attempt.publication.namespace
    publication = attempt.publication

    prefix == namespace.prefix and claim == namespace.public_claim and
      channel == Atom.to_string(publication.channel) and sequence > attempt.sequence
  end

  defp newer_owned?(_decoded, _attempt), do: false

  # -- Payload staging ------------------------------------------------------

  defp stage_payloads(config, attempt) do
    Enum.reduce_while(attempt.object_receipts, :ok, fn {role, descriptor}, :ok ->
      case stage_payload(config, attempt, role, descriptor) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp stage_payload(config, attempt, role, descriptor) do
    case object_source(attempt, role, descriptor) do
      {:ok, source} ->
        case Storage.put_payload(
               config,
               descriptor["key"],
               source,
               descriptor["sha256"],
               identity(attempt)
             ) do
          {:ok, _receipt} -> :ok
          {:error, :unknown} -> {:pending, "payload #{role} outcome is unknown"}
          {:error, :unavailable} -> {:pending, "the payload store is unavailable"}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The payload bytes are frozen on the attempt as base64 (realtime) or as a
  # private staging file (a static artifact). Bytes are re-hashed against the
  # frozen descriptor so a retry can only ever upload the same bytes.
  defp object_source(attempt, role, descriptor) do
    source = get_in(attempt.private_snapshot || %{}, ["objects", role]) || %{}

    cond do
      is_binary(source["file"]) -> file_source(source["file"], descriptor)
      is_binary(source["bytes_base64"]) -> bytes_source(source["bytes_base64"], descriptor)
      true -> {:error, :incomplete}
    end
  end

  defp file_source(path, descriptor) do
    size = descriptor["bytes"]

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: ^size}} ->
        {:ok, {:file, path}}

      _ ->
        {:error, :incomplete}
    end
  end

  defp bytes_source(base64, descriptor) do
    with {:ok, bytes} <- Base.decode64(base64),
         true <- byte_size(bytes) == descriptor["bytes"],
         true <- sha256_hex(bytes) == descriptor["sha256"] do
      {:ok, {:bytes, bytes}}
    else
      _ -> {:error, :inconsistent}
    end
  end

  # -- Terminal transitions -------------------------------------------------

  defp complete(attempt, etag, last_modified) do
    token = attempt.lease_token

    case Repo.transaction(fn ->
           locked =
             Repo.one(
               from a in Attempt,
                 where: a.id == ^attempt.id and a.lease_token == ^token,
                 lock: "FOR UPDATE"
             )

           if locked == nil do
             Repo.rollback(:fenced)
           else
             publication =
               Repo.one!(
                 from p in Publication,
                   where: p.id == ^locked.publication_id,
                   lock: "FOR UPDATE"
               )

             finish(locked, publication, etag, last_modified)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, :fenced} -> {:ok, :pending}
    end
  end

  defp finish(attempt, publication, etag, last_modified) do
    now = DateTime.utc_now()

    served = %{
      manifest_bytes: attempt.manifest_body,
      manifest_sha256: attempt.manifest_sha256,
      manifest_etag: etag,
      manifest_generation: attempt.generation,
      manifest_sequence: attempt.sequence,
      manifest_last_modified: parse_http_date(last_modified),
      last_refresh_at: now
    }

    if attempt.desired_revision == publication.desired_revision do
      publication
      |> Ecto.Changeset.change(
        Map.merge(served, %{
          status: :current,
          next_retry_at: nil,
          last_error: nil,
          active_attempt_id: attempt.id
        })
      )
      |> Repo.update!()

      attempt
      |> Ecto.Changeset.change(%{
        state: "current",
        retired_at: nil,
        lease_token: nil,
        lease_expires_at: nil
      })
      |> Repo.update!()

      :current
    else
      publication
      |> Ecto.Changeset.change(
        Map.merge(served, %{
          status: :pending,
          next_retry_at: DateTime.add(now, @retry_seconds),
          last_error: "newer accepted content is pending",
          active_attempt_id: nil
        })
      )
      |> Repo.update!()

      attempt
      |> Ecto.Changeset.change(%{
        state: "superseded",
        retired_at: now,
        lease_token: nil,
        lease_expires_at: nil
      })
      |> Repo.update!()

      :superseded
    end
  end

  # A stale attempt (its desired revision moved on) is retired. If it had
  # possibly sent, its served receipt is recorded first so the channel's
  # truth never regresses to an older manifest than the one actually served.
  defp stale(config, attempt) do
    if attempt.state == "switching" do
      case reconcile(config, attempt) do
        {:current, etag, last_modified} -> serve_then_supersede(attempt, etag, last_modified)
        _ -> supersede(attempt, nil)
      end
    else
      supersede(attempt, nil)
    end
  end

  defp serve_then_supersede(attempt, etag, last_modified) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      Repo.update_all(
        from(a in Attempt, where: a.id == ^attempt.id),
        set: [state: "superseded", retired_at: now, lease_token: nil, lease_expires_at: nil]
      )

      Repo.update_all(
        from(p in Publication, where: p.id == ^attempt.publication_id),
        set: [
          manifest_bytes: attempt.manifest_body,
          manifest_sha256: attempt.manifest_sha256,
          manifest_etag: etag,
          manifest_generation: attempt.generation,
          manifest_sequence: attempt.sequence,
          manifest_last_modified: parse_http_date(last_modified),
          last_refresh_at: now,
          status: :pending,
          active_attempt_id: nil,
          next_retry_at: DateTime.add(now, @retry_seconds),
          last_error: "newer accepted content is pending"
        ]
      )

      :superseded
    end)

    {:ok, :superseded}
  end

  defp supersede(attempt, token) do
    now = DateTime.utc_now()

    case Repo.transaction(fn ->
           {count, _} =
             if is_binary(token) do
               Repo.update_all(
                 from(a in Attempt, where: a.id == ^attempt.id and a.lease_token == ^token),
                 set: [
                   state: "superseded",
                   retired_at: now,
                   lease_token: nil,
                   lease_expires_at: nil
                 ]
               )
             else
               Repo.update_all(
                 from(a in Attempt, where: a.id == ^attempt.id),
                 set: [
                   state: "superseded",
                   retired_at: now,
                   lease_token: nil,
                   lease_expires_at: nil
                 ]
               )
             end

           if is_binary(token) and count == 0 do
             Repo.rollback(:fenced)
           else
             Repo.update_all(
               from(p in Publication,
                 where: p.id == ^attempt.publication_id and p.active_attempt_id == ^attempt.id
               ),
               set: [
                 active_attempt_id: nil,
                 status: :pending,
                 next_retry_at: DateTime.add(now, @retry_seconds),
                 last_error: "newer accepted content is pending"
               ]
             )

             :superseded
           end
         end) do
      {:ok, :superseded} -> {:ok, :superseded}
      {:error, :fenced} -> {:ok, :pending}
    end
  end

  defp block(attempt, message) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(a in Attempt, where: a.id == ^attempt.id and a.lease_token == ^attempt.lease_token),
        set: [state: "blocked", lease_token: nil, lease_expires_at: nil]
      )

      Repo.update_all(
        from(p in Publication, where: p.id == ^attempt.publication_id),
        set: [status: :blocked, last_error: message, next_retry_at: nil]
      )

      :blocked
    end)

    {:error, :blocked}
  end

  defp mark_pending(attempt, reason) do
    now = DateTime.utc_now()
    message = reason || "storage is unavailable"

    Repo.transaction(fn ->
      Repo.update_all(
        from(p in Publication, where: p.id == ^attempt.publication_id),
        set: [
          status: :pending,
          next_retry_at: DateTime.add(now, @retry_seconds),
          last_error: message
        ]
      )

      Repo.update_all(
        from(a in Attempt, where: a.id == ^attempt.id and a.lease_token == ^attempt.lease_token),
        set: [state: "switching", lease_token: nil, lease_expires_at: nil]
      )

      :pending
    end)

    {:ok, :pending}
  end

  # -- Helpers --------------------------------------------------------------

  defp manifest_key(attempt) do
    Manifest.key(attempt.publication.namespace.prefix, attempt.publication.channel)
  end

  defp condition(%Attempt{predecessor_etag: etag}) when is_binary(etag) and etag != "",
    do: {:etag, etag}

  defp condition(_attempt), do: :absent

  defp identity(attempt) do
    %{
      claim: attempt.publication.namespace.public_claim,
      channel: Atom.to_string(attempt.publication.channel),
      sequence: attempt.sequence,
      generation: attempt.generation
    }
  end

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp parse_http_date(value) when is_binary(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, minute, second}} ->
        date = Date.new!(year, month, day)
        time = Time.new!(hour, minute, second)

        case DateTime.new(date, time, "Etc/UTC") do
          {:ok, datetime} -> %{datetime | microsecond: {0, 6}}
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_http_date(_value), do: nil

  defp describe(reason) when is_atom(reason), do: "storage reported #{reason}"
  defp describe(_reason), do: "storage reported an error"
end
