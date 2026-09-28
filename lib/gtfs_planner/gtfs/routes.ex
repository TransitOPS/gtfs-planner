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
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Repo

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
end
