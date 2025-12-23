defmodule GtfsPlanner.Organizations.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @secret_size 32
  @hash_algorithm :sha512
  @prefix "GtfsPlanner"

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "api_keys" do
    field :description, :string
    field :roles, {:array, :string}, default: []
    field :version, :integer, default: 1
    field :secret_hash, :binary
    belongs_to :organization, GtfsPlanner.Organizations.Organization

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an API key token with hashed secret and returns the token string and updated changeset.
  """
  def build_hashed_token(organization_id, changeset) do
    version = 1
    api_key_id = Ecto.UUID.generate()
    token_secret = :crypto.strong_rand_bytes(@secret_size)
    hash = hash_api_key(api_key_id, version, organization_id, token_secret)
    token = serialize_token(version, api_key_id, token_secret)

    changeset =
      cast(changeset, %{id: api_key_id, version: version, secret_hash: hash}, [
        :id,
        :version,
        :secret_hash
      ])

    {token, changeset}
  end

  @doc """
  Creates a hash of the API key components.
  """
  def hash_api_key(api_key_id, version, organization_id, secret) do
    data = "#{api_key_id}:#{version}:#{organization_id}:#{secret}"
    :crypto.hash(@hash_algorithm, data)
  end

  @doc """
  Serializes the API key components into a token string.
  """
  def serialize_token(version, api_key_id, secret) do
    Enum.join(
      [
        @prefix,
        "V#{version}",
        Base.encode32(Ecto.UUID.dump!(api_key_id) <> secret, case: :lower, padding: false)
      ],
      "."
    )
  end

  @doc """
  Verifies an API key token by extracting the ID, fetching from the database,
  and comparing hashes using constant-time comparison to prevent timing attacks.

  Returns {:ok, api_key} if valid, or {:error, :invalid} otherwise.
  """
  def verify_token(token, repo) when is_atom(repo) do
    with [@prefix, "V1", encoded] <- String.split(token, "."),
         <<api_key_id::binary-size(16), secret::binary-size(@secret_size)>> <-
           Base.decode32!(encoded, case: :lower, padding: false),
         api_key_id_uuid <- Ecto.UUID.cast!(api_key_id),
         %__MODULE__{} = api_key <- repo.get(__MODULE__, api_key_id_uuid) do
      hash = hash_api_key(api_key_id_uuid, 1, api_key.organization_id, secret)

      if Plug.Crypto.secure_compare(hash, api_key.secret_hash) do
        {:ok, api_key}
      else
        {:error, :invalid}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  def verify_token(_, _), do: {:error, :invalid}

  @doc """
  Creates a changeset for a new API key.
  """
  def changeset(api_key \\ %__MODULE__{}, attrs) do
    api_key
    |> cast(attrs, [:description, :roles, :organization_id])
    |> validate_required([:description, :organization_id])
    |> validate_length(:description, max: 255)
    |> foreign_key_constraint(:organization_id)
  end
end
