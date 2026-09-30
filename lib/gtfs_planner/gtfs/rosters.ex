defmodule GtfsPlanner.Gtfs.Rosters do
  @moduledoc """
  Scoped reads and writes for the Rosters page.

  This module is the only reader and writer of `roster_lines`, `roster_line_days`
  and of the three roster columns on `blocking_settings` — `min_rest_minutes`,
  `weekly_hours_warn_above` and `roster_day_types`. The page reaches them through
  `Gtfs` facade functions, so a roster rule has one home.

  The roster rules are the work rules a line is judged against: the minimum rest
  between a sign-off and the next sign-on, the weekly paid hours above which a
  line is flagged, and which day type each weekday's base week works. They are
  stored per published organization and version alongside the Block rules and the
  crew rules, on the same row, and this writer replaces only the three columns it
  owns — a roster save cannot reset a minimum layover or a crew rule, and a Block
  rules or crew save cannot reset a roster rule.

  A version with no stored roster rules reads the researched defaults (600
  minutes of rest, a warning above 48 weekly hours and an empty base-week choice)
  and writes nothing: a read never inserts a row.

  A stored base-week choice is accepted only while it is current. Each weekday's
  day-type key must still be a day type the version's calendars derive, and that
  day type must have at least one date on that weekday; anything else is a field
  error rather than a stored key that silently falls back to another day's service
  (INV-6).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # The rules a version with no stored row reads. The map is the single definition
  # of the defaults, exactly as `@crew_defaults` is for the Runs page: the reader
  # answers with it when no row is stored and the form changeset fills a partial
  # map from it, so the database defaults, this map and the drawn inputs cannot
  # drift apart.
  @roster_defaults %{
    min_rest_minutes: 600,
    weekly_hours_warn_above: 48,
    roster_day_types: %{}
  }

  # The three roster columns plus the write timestamp: an upsert that replaced more
  # than these would reset the Block rules and the crew rules stored on the same
  # row, and one that replaced fewer would leave a previous save's value behind.
  @replace_roster_columns BlockingSetting.roster_fields() ++ [:updated_at]

  @published_status "published"

  # The weekday a field error reads with, keyed by the ISO weekday string
  # `roster_day_types` stores and in `Date.day_of_week/1`'s order (1 = Monday).
  @weekday_names %{
    "1" => "Monday",
    "2" => "Tuesday",
    "3" => "Wednesday",
    "4" => "Thursday",
    "5" => "Friday",
    "6" => "Saturday",
    "7" => "Sunday"
  }

  @type roster_settings :: %{
          min_rest_minutes: 480..720,
          weekly_hours_warn_above: 40..60,
          roster_day_types: %{optional(String.t()) => String.t()}
        }

  @doc """
  Returns the three roster rules for an organization's GTFS version.

  A version with no stored row returns the researched defaults; the read never
  inserts one, so opening the Rosters page cannot create a settings row as a side
  effect of looking at it.
  """
  @spec get_roster_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: roster_settings()
  def get_roster_settings(organization_id, gtfs_version_id) do
    case Repo.one(roster_query(organization_id, gtfs_version_id)) do
      nil -> @roster_defaults
      stored -> stored
    end
  end

  @doc """
  Returns the changeset rendered by the roster settings form.

  `roster` is a value map from `get_roster_settings/2` — or any partial map, which
  is filled from the defaults — and `attrs` are the submitted parameters; an
  invalid value carries the field error.

  The day-type check needs the version's calendars, which this function has no
  scope for, so a stored key that is no longer a current day type is not reported
  here: `update_roster_settings/3` makes that call inside its transaction.
  """
  @spec change_roster_settings(roster_settings(), map()) :: Ecto.Changeset.t()
  def change_roster_settings(roster, attrs) do
    # The defaults fill in what the caller did not supply, so the merge runs the
    # other way round, exactly as `Runs.change_crew_settings/2` does: merging the
    # defaults over the given roster would replace every stored value with a
    # default and the form could never show what the version has.
    values = @roster_defaults |> Map.merge(roster) |> Map.take(BlockingSetting.roster_fields())

    %BlockingSetting{}
    |> Ecto.Changeset.change(values)
    |> BlockingSetting.roster_changeset(attrs)
  end

  @doc """
  Stores the three roster rules for one organization's published version.

  The save runs in one transaction whose first statement is the scoped version row
  `FOR SHARE` (`Versions.lock_for_input_write!/2`), so the rules a review loaded
  cannot change under a calendar combination that owns the version, and this save
  waits behind such an owner in turn. It then takes `Blocking.lock_blocking!/1`,
  so a roster save serializes with every other planning-input writer and cannot
  slip between a plan's review and its apply (INV-1). No second lock is taken.

  The upsert replaces only the three roster columns and the write timestamp. Its
  base carries the stored Block rules values, so a first save on a version with no
  row satisfies the Block rules columns rather than inserting defaults over them.

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when a value is outside its range
  or a chosen day type is not current for that weekday, in which case nothing is
  written.
  """
  @spec update_roster_settings(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, roster_settings()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_roster_settings(organization_id, gtfs_version_id, attrs) do
    case Repo.transaction(fn ->
           write_roster_settings!(organization_id, gtfs_version_id, attrs)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # The version share lock is the first statement of the write transaction, before
  # the published check, the day-type read and the upsert, and `lock_blocking!/1`
  # follows it and nothing else, in the blocking writers' order, so this writer
  # joins the same serialization point as the block writers.
  defp write_roster_settings!(organization_id, gtfs_version_id, attrs) do
    version = Versions.lock_for_input_write!(organization_id, gtfs_version_id)

    if version.publication_status == @published_status do
      :ok = Blocking.lock_blocking!(gtfs_version_id)

      # The stored row is the base rather than a bare struct, so the columns this
      # writer does not own are present and satisfy the insert of the version's
      # first row; the upsert then replaces only the roster columns, so writing a
      # roster rule cannot blank a stored layover, interlining rule or crew rule.
      stored = Blocking.get_settings(organization_id, gtfs_version_id)

      changeset =
        %BlockingSetting{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
        |> Ecto.Changeset.change(Map.take(stored, BlockingSetting.settings_fields()))
        |> BlockingSetting.roster_changeset(attrs)
        |> check_day_types(Blocking.list_day_types(organization_id, gtfs_version_id))

      case Repo.insert(changeset,
             on_conflict: {:replace, @replace_roster_columns},
             conflict_target: [:organization_id, :gtfs_version_id]
           ) do
        {:ok, saved} -> {:ok, roster_values(saved)}
        # Nothing has been written yet, so the transaction commits this result and
        # still leaves the stored row exactly as the previous save left it.
        {:error, invalid} -> {:error, invalid}
      end
    else
      # The shared lock takes no publication stance, so the published requirement
      # stays here, exactly as `Blocking`'s and `Runs`' own settings writers apply
      # it.
      {:error, :not_found}
    end
  end

  # A chosen day type has to be a day type the version derives now, and it has to
  # have at least one date on the weekday it was chosen for. Both halves are
  # checked against the calendars read inside the write transaction, so a key that
  # a calendar change has made stale is refused at the moment it is submitted
  # rather than stored and reported as "Base week changed" later (INV-6).
  #
  # An entry whose weekday or key is malformed is left to
  # `BlockingSetting.roster_changeset/2`, which has already put a field error on
  # it, rather than answering the same entry twice.
  defp check_day_types(changeset, day_types) do
    case Ecto.Changeset.get_field(changeset, :roster_day_types) do
      choices when is_map(choices) ->
        # Only entries whose weekday and key are well formed are checked here: the
        # other two refusals — a weekday outside 1 to 7 and a blank key — are
        # already field errors from `roster_changeset/2`, and answering the same
        # entry twice would give the drawer two messages for one mistake.
        choices
        |> Enum.filter(fn {weekday, key} ->
          Map.has_key?(@weekday_names, weekday) and usable_key?(key)
        end)
        |> Enum.reduce(changeset, &check_day_type(&1, &2, day_types))

      _not_a_map ->
        changeset
    end
  end

  defp check_day_type({weekday, key}, changeset, day_types) do
    if runs_on_weekday?(day_types, key, weekday) do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :roster_day_types,
        "Choose a day type that runs on #{Map.fetch!(@weekday_names, weekday)}."
      )
    end
  end

  # The key must be a day type the version's calendars derive now, and that day type
  # must have at least one date on the weekday the key was chosen for.
  defp runs_on_weekday?(day_types, key, weekday) do
    case Enum.find(day_types, &(&1.key == key)) do
      %{dates: dates} -> Enum.any?(dates, &(Date.day_of_week(&1) == String.to_integer(weekday)))
      nil -> false
    end
  end

  defp usable_key?(key), do: is_binary(key) and String.trim(key) != ""

  # Only the three roster columns, in the shape `get_roster_settings/2` answers
  # with, so a caller never has to know the row also carries the Block rules and
  # the crew rules.
  defp roster_values(setting) do
    Map.new(BlockingSetting.roster_fields(), &{&1, Map.fetch!(setting, &1)})
  end

  # Scoped by organization and version like every other read here, and selecting
  # only the roster columns: a caller cannot learn a crew or Block rules value
  # through the roster reader, and those readers cannot learn a roster value.
  defp roster_query(organization_id, gtfs_version_id) do
    from(s in BlockingSetting,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      select: %{
        min_rest_minutes: s.min_rest_minutes,
        weekly_hours_warn_above: s.weekly_hours_warn_above,
        roster_day_types: s.roster_day_types
      }
    )
  end
end
