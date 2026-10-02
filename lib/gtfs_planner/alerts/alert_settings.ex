defmodule GtfsPlanner.Alerts.AlertSettings do
  @moduledoc """
  One organization's alert writing guidelines, stored in `alert_settings`.

  The row is optional: an organization that has never saved guidelines reads the
  recommended text `GtfsPlanner.Alerts.BuiltInScripts.guidelines/0` returns at
  revision 0, so reading settings never writes one. `revision` starts at 1 for
  the first saved row and is the value `Alerts.save_guidelines/3` optimistically
  locks, so two editors saving the same text cannot silently overwrite each
  other (R6).

  The guidelines are plain text an organization writes for itself, at most
  10,000 characters: this changeset casts only `guidelines` and leaves
  `organization_id` and `revision` to the `Alerts` command (R4, CR-2).

  `timezone` is the organization's own explicit alert zone. It answers for an
  alert whose retained source had no single usable agency zone, and it stays NULL
  until an organization states one, so no alert silently publishes in UTC. It has
  its own changeset because the settings text and the zone are saved for
  different reasons, and a guidance edit must not clear a stated zone.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.ChangesetHelpers
  alias GtfsPlanner.Gtfs.DisplayClock

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Every editor on the Message step and the assistant's `get_guidelines` read the
  # whole text, so it is bounded well under the assistant's result limit.
  @max_guidelines_length 10_000

  schema "alert_settings" do
    field :guidelines, :string
    field :revision, :integer, default: 1
    field :timezone, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          guidelines: String.t() | nil,
          revision: integer() | nil,
          timezone: String.t() | nil,
          organization:
            GtfsPlanner.Organizations.Organization.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Creates the changeset that stores an organization's guidelines.

  The text is optional, so an organization may save an empty document and read
  its own revision back rather than the built-in default. `revision` is never
  cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:guidelines])
    |> ChangesetHelpers.trim_string_fields()
    |> validate_length(:guidelines, max: @max_guidelines_length)
    # Two first saves can both reach the insert; the one that waits on this index
    # loses the race, which `Alerts.save_guidelines/3` reports as stale.
    |> unique_constraint(:organization_id)
  end

  @doc """
  Creates the changeset that stores the organization's own alert timezone.

  The name is validated against PostgreSQL's timezone catalog through
  `Gtfs.DisplayClock.valid_zone?/1`, the same check every other accepted zone
  uses, so a stated zone can always be compiled into civil periods later. An
  empty value clears the zone back to "no stated zone" rather than storing one,
  and `revision` is never cast.
  """
  @spec timezone_changeset(t(), map()) :: Ecto.Changeset.t()
  def timezone_changeset(settings, attrs) do
    settings
    |> cast(attrs, [:timezone])
    |> update_change(:timezone, &String.trim/1)
    |> validate_timezone()
  end

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, timezone ->
      if timezone == "" or DisplayClock.valid_zone?(timezone),
        do: [],
        else: [{:timezone, "is not a known timezone"}]
    end)
  end
end
