defmodule GtfsPlanner.Gtfs.Import.ChangeRun do
  @moduledoc "Durable, tenant- and version-scoped station change-review state."

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions.GtfsVersion

  @states [
    :pending_compute,
    :computing,
    :review,
    :pending_apply,
    :applying,
    :partial,
    :completed,
    :failed,
    :interrupted,
    :cancelled,
    :expired
  ]
  @phases [:staging, :parsing, :diffing, :preflight, :applying, :cleanup]
  @terminal_states [:partial, :completed, :failed, :interrupted, :cancelled, :expired]
  @summary_keys ~w(applicable preview approved rejected applied failed add modify remove conflict)a
  @diagnostic_keys ~w(code detail entity_type natural_key)a
  @manifest_keys ~w(files total_bytes)a
  @manifest_file_keys ~w(name key size sha256 content_type)a
  @max_string 4_096

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "gtfs_change_runs" do
    field :kind, Ecto.Enum, values: [:station_diff], default: :station_diff
    field :state, Ecto.Enum, values: @states, default: :pending_compute
    field :phase, Ecto.Enum, values: @phases
    field :progress_current, :integer
    field :progress_total, :integer
    field :summary, :map, default: %{}
    field :diagnostics, {:array, :map}, default: []
    field :source_manifest, :map, default: %{}
    field :serializer_version, :integer, default: 1
    field :lease_generation, :integer, default: 0
    field :lease_token, :binary_id
    field :lease_expires_at, :utc_datetime_usec
    field :cancel_requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :failure_code, :string
    field :actor_id, :binary_id
    field :actor_email, :string
    belongs_to :organization, Organization
    belongs_to :gtfs_version, GtfsVersion
    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
  def terminal_states, do: @terminal_states

  @doc "Public params cannot alter durable scope, actor, lease, artifact, or lifecycle state."
  def changeset(run, _attrs), do: change(run)

  @doc false
  def system_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :kind,
      :state,
      :phase,
      :progress_current,
      :progress_total,
      :summary,
      :diagnostics,
      :source_manifest,
      :serializer_version,
      :lease_generation,
      :lease_token,
      :lease_expires_at,
      :cancel_requested_at,
      :started_at,
      :finished_at,
      :failure_code,
      :actor_id,
      :actor_email,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:kind, :state, :organization_id, :gtfs_version_id])
    |> validate_number(:serializer_version, equal_to: 1)
    |> validate_number(:lease_generation, greater_than_or_equal_to: 0)
    |> validate_length(:failure_code, max: 128)
    |> validate_length(:actor_email, max: 255)
    |> validate_progress()
    |> validate_summary()
    |> validate_diagnostics()
    |> validate_manifest()
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

  defp validate_summary(changeset) do
    case get_change(changeset, :summary) do
      nil ->
        changeset

      summary when is_map(summary) ->
        summary = normalize_keys(summary, @summary_keys)

        if map_size(summary) <= 32 and
             Enum.all?(summary, fn {key, value} ->
               key in @summary_keys and valid_count?(value)
             end),
           do: changeset,
           else: add_error(changeset, :summary, "contains unsupported or invalid values")

      _ ->
        add_error(changeset, :summary, "must be a map")
    end
  end

  defp validate_diagnostics(changeset) do
    case get_change(changeset, :diagnostics) do
      nil ->
        changeset

      diagnostics when is_list(diagnostics) and length(diagnostics) <= 100 ->
        if Enum.all?(diagnostics, &diagnostic?/1),
          do: changeset,
          else: add_error(changeset, :diagnostics, "contains unsupported diagnostic data")

      _ ->
        add_error(changeset, :diagnostics, "must contain at most 100 bounded entries")
    end
  end

  defp validate_manifest(changeset) do
    case get_change(changeset, :source_manifest) do
      nil ->
        changeset

      manifest when is_map(manifest) ->
        if(manifest?(manifest),
          do: changeset,
          else: add_error(changeset, :source_manifest, "contains unsupported manifest data")
        )

      _ ->
        add_error(changeset, :source_manifest, "must be a bounded manifest map")
    end
  end

  defp diagnostic?(value) when is_map(value) do
    value = normalize_keys(value, @diagnostic_keys)

    map_size(value) <= length(@diagnostic_keys) and
      Enum.all?(value, fn {key, item} -> key in @diagnostic_keys and scalar?(item) end)
  end

  defp diagnostic?(_), do: false

  defp manifest?(value) do
    value = normalize_keys(value, @manifest_keys)

    Map.keys(value) -- @manifest_keys == [] and
      case value do
        %{files: files} when is_list(files) and length(files) <= 100 ->
          Enum.all?(files, &manifest_file?/1) and
            (not Map.has_key?(value, :total_bytes) or valid_count?(value.total_bytes))

        %{total_bytes: total} ->
          valid_count?(total)

        %{} ->
          true

        _ ->
          false
      end
  end

  defp manifest_file?(value) when is_map(value) do
    value = normalize_keys(value, @manifest_file_keys)

    Map.keys(value) -- @manifest_file_keys == [] and
      Enum.all?(value, fn {key, item} -> key in @manifest_file_keys and scalar?(item) end)
  end

  defp manifest_file?(_), do: false

  defp scalar?(value) when is_binary(value), do: String.length(value) <= @max_string
  defp scalar?(value), do: valid_count?(value) or value in [true, false, nil]
  defp valid_count?(value), do: is_integer(value) and value >= 0

  defp normalize_keys(map, allowed) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      key =
        if is_binary(key), do: Enum.find(allowed, &(Atom.to_string(&1) == key)) || key, else: key

      Map.put(acc, key, value)
    end)
  end
end
