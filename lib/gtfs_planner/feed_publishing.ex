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

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.FeedPublishing.Namespace
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

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
    case Repo.get_by(Namespace, organization_id: organization_id) do
      %Namespace{} = claimed ->
        claimed

      nil ->
        case Repo.insert(
               Namespace.claim_changeset(organization_id, prefix, random_claim()),
               on_conflict: :nothing
             ) do
          {:ok, _namespace, false} ->
            claimed_namespace(organization_id) || Repo.rollback(:prefix_taken)

          {:ok, %Namespace{} = namespace, true} ->
            namespace

          {:ok, %Namespace{} = namespace} ->
            namespace
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
