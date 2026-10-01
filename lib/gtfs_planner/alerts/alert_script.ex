defmodule GtfsPlanner.Alerts.AlertScript do
  @moduledoc """
  One organization's message script: the wording an editor can generate a
  rider's header and description from (R10).

  A script is data, not code. Both templates are plain text whose only markup is
  the fixed placeholder vocabulary `GtfsPlanner.Alerts.Message` fills, so
  `changeset/2` refuses a template carrying `<%` and a template naming anything
  `Message.unknown_placeholders/1` does not recognize. A script therefore cannot
  be an EEx template, cannot reach `File` or any other runtime call, and cannot
  introduce a fill-in the fill would silently skip.

  Names are unique per organization, which the database index enforces and
  `changeset/2` reports as a `name` error rather than an exception. Identity is
  server-owned: `organization_id` is set by the `Alerts` command from the audit
  context and is never cast here (R4, CR-2).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Message
  alias GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @script_fields [:name, :situation, :header_template, :description_template, :position]
  @required_fields [:name, :situation, :header_template, :description_template]
  @template_fields [:header_template, :description_template]

  @max_name_length 80
  # The header a rider sees in an app list and the description they open. The
  # bounds are `MessageAnswer`'s, so a generated message never overflows the
  # field it is stored in.
  @max_header_template_length 120
  @max_description_template_length 2_000

  @markup_message "must be plain text with [placeholders], not a template tag"

  schema "alert_scripts" do
    field :name, :string
    field :situation, Ecto.Enum, values: Alert.situations()
    field :header_template, :string
    field :description_template, :string
    field :position, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          situation: atom() | nil,
          header_template: String.t() | nil,
          description_template: String.t() | nil,
          position: integer() | nil,
          organization:
            GtfsPlanner.Organizations.Organization.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Creates the changeset the scripts drawer saves.

  Requires a name, a situation and both templates, so a stored script is
  always fillable, and bounds each template by the message field it generates.
  `position` is the editor's own ordering; a script without one is listed after
  the ones that have one.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(script, attrs) do
    script
    |> cast(attrs, @script_fields)
    |> ChangesetHelpers.trim_string_fields()
    |> validate_required(@required_fields)
    |> validate_length(:name, max: @max_name_length)
    |> validate_length(:header_template, max: @max_header_template_length)
    |> validate_length(:description_template, max: @max_description_template_length)
    |> validate_templates()
    # The index spans the organization, so the constraint is named for it; a
    # duplicate name is a `name` error on the form, not a raised exception.
    |> unique_constraint(:name, name: "alert_scripts_organization_id_name_index")
  end

  # A template is refused on two counts, both reported on the field the operator
  # typed so the drawer can show the error next to the input: `<%` is an attempt
  # at a template the fill never runs, and a bracketed word outside
  # `Message.placeholders/0` is a fill-in nothing could ever replace.
  defp validate_templates(changeset) do
    Enum.reduce(@template_fields, changeset, &validate_template(&2, &1))
  end

  defp validate_template(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not is_binary(value) -> []
        String.contains?(value, "<%") -> [{field, @markup_message}]
        true -> unknown_placeholder_errors(field, value)
      end
    end)
  end

  defp unknown_placeholder_errors(field, value) do
    case Message.unknown_placeholders(value) do
      [] ->
        []

      names ->
        [
          {field,
           "names " <>
             Enum.map_join(names, " and ", &inspect/1) <>
             ", which this app does not fill in. Available placeholders: " <>
             Enum.map_join(Message.placeholders(), ", ", &inspect/1)}
        ]
    end
  end
end
