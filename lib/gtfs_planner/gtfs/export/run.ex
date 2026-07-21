defmodule GtfsPlanner.Gtfs.Export.Run do
  @moduledoc "Durable, tenant- and version-scoped GTFS export state."

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions.GtfsVersion

  @export_types [:full, :pathways]
  @states [:pending, :building, :ready, :failed, :interrupted, :cancelled, :expired]
  @phases [:preflight, :packaging, :publishing, :cleanup]
  @terminal_states [:ready, :failed, :interrupted, :cancelled, :expired]
  @warning_keys ~w(code detail file entity_type)a
  @max_string 4_096

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "gtfs_export_runs" do
    field :export_type, Ecto.Enum, values: @export_types, default: :full
    field :state, Ecto.Enum, values: @states, default: :pending
    field :phase, Ecto.Enum, values: @phases
    field :progress_current, :integer
    field :progress_total, :integer
    field :warnings, {:array, :map}, default: []
    field :failure_code, :string
    field :lease_generation, :integer, default: 0
    field :lease_token, :binary_id
    field :lease_expires_at, :utc_datetime_usec
    field :artifact_key, :string
    field :artifact_filename, :string
    field :artifact_sha256, :string
    field :artifact_size_bytes, :integer
    field :artifact_expires_at, :utc_datetime_usec
    field :download_claimed_until, :utc_datetime_usec
    field :download_count, :integer, default: 0
    field :last_downloaded_at, :utc_datetime_usec
    field :cancel_requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :actor_id, :binary_id
    field :actor_email, :string
    field :version_name, :string
    belongs_to :organization, Organization
    belongs_to :gtfs_version, GtfsVersion
    timestamps(type: :utc_datetime_usec)
  end

  def export_types, do: @export_types
  def states, do: @states
  def terminal_states, do: @terminal_states

  @doc "Public params cannot alter durable scope, actor, lease, artifact, receipt, or lifecycle state."
  def changeset(run, _attrs), do: change(run)

  @doc false
  def system_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :export_type,
      :state,
      :phase,
      :progress_current,
      :progress_total,
      :warnings,
      :failure_code,
      :lease_generation,
      :lease_token,
      :lease_expires_at,
      :artifact_key,
      :artifact_filename,
      :artifact_sha256,
      :artifact_size_bytes,
      :artifact_expires_at,
      :download_claimed_until,
      :download_count,
      :last_downloaded_at,
      :cancel_requested_at,
      :started_at,
      :finished_at,
      :actor_id,
      :actor_email,
      :version_name,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:export_type, :state, :organization_id, :gtfs_version_id])
    |> validate_number(:lease_generation, greater_than_or_equal_to: 0)
    |> validate_number(:download_count, greater_than_or_equal_to: 0)
    |> validate_length(:failure_code, max: 128)
    |> validate_length(:actor_email, max: 255)
    |> validate_length(:version_name, max: 255)
    |> validate_progress()
    |> validate_warnings()
    |> validate_artifact()
  end

  defp validate_progress(changeset) do
    case {get_field(changeset, :progress_current), get_field(changeset, :progress_total)} do
      {nil, nil} ->
        changeset

      {current, total}
      when is_integer(current) and is_integer(total) and current >= 0 and total >= 0 and
             current <= total ->
        changeset

      _ ->
        add_error(
          changeset,
          :progress_current,
          "must be paired with a non-negative total not below current"
        )
    end
  end

  defp validate_warnings(changeset) do
    case get_change(changeset, :warnings) do
      nil ->
        changeset

      warnings when is_list(warnings) and length(warnings) <= 100 ->
        if Enum.all?(warnings, &warning?/1),
          do: changeset,
          else: add_error(changeset, :warnings, "contains unsupported warning data")

      _ ->
        add_error(changeset, :warnings, "must contain at most 100 bounded entries")
    end
  end

  defp validate_artifact(changeset) do
    changeset
    |> validate_length(:artifact_key, max: 255)
    |> validate_length(:artifact_filename, max: 255)
    |> validate_number(:artifact_size_bytes, greater_than_or_equal_to: 0)
    |> validate_change(:artifact_sha256, fn :artifact_sha256, value ->
      if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
        do: [],
        else: [artifact_sha256: "must be a lowercase SHA-256 digest"]
    end)
    |> validate_ready_artifact()
  end

  defp validate_ready_artifact(changeset) do
    if get_field(changeset, :state) == :ready do
      validate_required(changeset, [
        :artifact_key,
        :artifact_filename,
        :artifact_sha256,
        :artifact_size_bytes,
        :artifact_expires_at
      ])
    else
      changeset
    end
  end

  defp warning?(warning) when is_map(warning) do
    warning = normalize_keys(warning)

    Map.keys(warning) -- @warning_keys == [] and
      Enum.all?(warning, fn {key, value} -> key in @warning_keys and scalar?(value) end)
  end

  defp warning?(_), do: false

  defp scalar?(value) when is_binary(value), do: String.length(value) <= @max_string
  defp scalar?(value), do: is_integer(value) or value in [true, false, nil]

  defp normalize_keys(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      key =
        if is_binary(key),
          do: Enum.find(@warning_keys, &(Atom.to_string(&1) == key)) || key,
          else: key

      Map.put(acc, key, value)
    end)
  end
end
