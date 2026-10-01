defmodule GtfsPlanner.Gtfs.DatedChangePlan do
  @moduledoc """
  Plan-only dated change planning: accepted intent first, computation later.

  This module is the date-bounded change planner (A36). It never writes a
  calendar, trip, time, block, transfer, run or audit row, and it exposes no
  apply, prepared command or execution token (INV-1, AC-10, AC-11). The
  computation steps `load/2`, `partition/2`, `project_times/3` and `prepare/2`
  belong to later work; this slice owns intent normalization and acceptance.

  ## Two server-owned steps

  `normalize_intent/2` turns submitted form fields plus the caller's own
  selection into a `draft`, or into focused `field_errors` the host renders on
  the same form. `accept_intent/2` re-reads the *current* server selection and
  produces the `accepted` source every later step reads.

  The split is the authority boundary (AC-1, AC-2):

    * Dates are explicit and inclusive. `first_date` and `last_date` are full
      `YYYY-MM-DD` values with a four-digit year, and `last_date` is not before
      `first_date`. A date without a year, a two-digit year, a non-ISO ordering
      or a reversed interval is refused with a message naming the field; no year
      is ever inferred from the current date.
    * The shift is a signed integer second count in `-86400..86400`, so `+300`
      moves the same service-day seconds five minutes later and never rolls into
      the next service date.
    * The approval note is the editor's own supplied provenance: nonblank and at
      most 2,000 characters. An optional source label is at most 200 characters.
    * A selection is 1 to 100 distinct trip UUIDs. A duplicate entry, a
      non-UUID entry, an empty selection and an over-cap selection are refused.
    * No route, organization, actor, version, pack, digest or accepted flag is
      ever read from submitted fields. Those keys are server-owned, and a
      request carrying one is refused rather than quietly dropping it, so a
      client cannot smuggle identity or a pre-baked acceptance.

  ## Acceptance binds the current selection

  `accept_intent/2` recomputes the digest itself and compares the draft's sorted
  trip UUIDs with the caller's current server selection. A selection that
  changed since normalization is `{:error, :selection_changed}`, which is how a
  host invalidates acceptance when a selection changes (AC-2). A draft carrying
  an unexpected key — a forged `input_digest`, `accepted` or identity field — is
  `{:error, :invalid_draft}`: acceptance is produced only from the exact
  normalized shape.

  `accepted` carries `schema_version`, the sorted `trip_ids`, `first_date`,
  `last_date`, `delta_seconds`, `approval_note`, `source_label` and a
  deterministic `input_digest` binding all of them. Two accepts of the same
  normalized intent produce the same digest; changing any bound value changes it
  (INV-2).

  Acceptance confirms the editor's interpretation of their own supplied dates,
  shift and approval text. It freezes that provenance as data; it is not a
  certification of operating approval and it authorizes no write.
  """

  @schema_version 1
  @max_selected_trips 100
  @max_delta_seconds 86_400
  @max_approval_note_length 2_000
  @max_source_label_length 200

  @iso_date_format ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
  @signed_integer_format ~r/\A[+-]?[0-9]+\z/

  # Client fields the server owns. Their presence refuses the request; the
  # value is never read.
  @server_owned_fields ~w(
    route_id route_uuid organization_id org_id user_id actor_id
    gtfs_version_id version_id pack_id schema_version
    input_digest digest dependency_digest accepted
  )

  @draft_fields [:first_date, :last_date, :delta_seconds, :approval_note, :source_label]
  @draft_keys Enum.sort(@draft_fields ++ [:trip_ids])

  @typedoc """
  A validated but unaccepted intent.

  `trip_ids` is the sorted selection the draft was normalized from. Every value
  is already normalized: `Date` structs, an integer `delta_seconds`, trimmed
  text, and no server-owned field.
  """
  @type draft :: %{
          first_date: Date.t(),
          last_date: Date.t(),
          delta_seconds: integer(),
          approval_note: String.t(),
          source_label: String.t() | nil,
          trip_ids: [String.t()]
        }

  @typedoc """
  The accepted intent source later steps read.

  `input_digest` is a lowercase hex SHA-256 over the canonical, explicitly
  ordered encoding of every other key, so it changes if any of them changes.
  """
  @type accepted :: %{
          schema_version: pos_integer(),
          trip_ids: [String.t()],
          first_date: Date.t(),
          last_date: Date.t(),
          delta_seconds: integer(),
          approval_note: String.t(),
          source_label: String.t() | nil,
          input_digest: String.t()
        }

  @typedoc "Field-keyed validation messages a host renders on the submitted form."
  @type field_errors :: %{optional(atom()) => [String.t()]}

  @doc """
  Normalizes submitted intent fields and the caller's own selection into a
  `draft`, or refuses with `field_errors`.

  `params` carries the submitted intent fields (`first_date`, `last_date`,
  `delta_seconds`, `approval_note`, `source_label`) under string or atom keys.
  `selected_trip_ids` is the caller's own current selection of 1 to 100
  distinct trip UUIDs, or a server map carrying them under `:trip_ids`.

  Refusal is field-scoped and additive: every invalid field is reported in one
  pass, and the host keeps its own form assigns, so a refusal never discards
  the draft the editor typed (AC-2).
  """
  @spec normalize_intent(map(), [String.t()] | term()) ::
          {:ok, draft()} | {:error, field_errors()}
  def normalize_intent(params, selected_trip_ids) when is_map(params) do
    with :ok <- reject_server_owned_fields(params) do
      errors =
        %{}
        |> put_errors(:first_date, date_error(params, :first_date))
        |> put_errors(:last_date, date_error(params, :last_date))
        |> put_delta_errors(params)
        |> put_errors(:approval_note, approval_note_error(params))
        |> put_errors(:source_label, source_label_error(params))
        |> put_selection_errors(selected_trip_ids)

      case errors do
        errors when map_size(errors) > 0 -> {:error, errors}
        _no_errors -> build_draft(params, selected_trip_ids)
      end
    end
  end

  def normalize_intent(_params, _selected_trip_ids),
    do: {:error, %{base: ["Submit the dated change intent form."]}}

  @doc """
  Accepts a normalized `draft` against the caller's current server selection.

  Returns the `accepted` source, `{:error, :invalid_draft}` when `draft` is not
  the exact normalized shape, and `{:error, :selection_changed}` when the
  current selection no longer matches the one the draft was normalized from.
  Selection and draft changes therefore cannot leave a stale acceptance behind
  (AC-2), and the digest is always recomputed here rather than trusted from the
  draft (AC-1).
  """
  @spec accept_intent(draft(), [String.t()] | map() | term()) ::
          {:ok, accepted()} | {:error, atom()}
  def accept_intent(draft, server_selection) when is_map(draft) do
    with :ok <- validate_draft(draft),
         {:ok, selection} <- normalize_selection(server_selection) do
      if selection == draft.trip_ids do
        {:ok, accept(draft)}
      else
        {:error, :selection_changed}
      end
    end
  end

  def accept_intent(_draft, _server_selection), do: {:error, :invalid_draft}

  @doc """
  Returns the lowercase hex SHA-256 `input_digest` binding an accepted source.

  The encoded value is an explicitly ordered JSON array of `[key, value]` pairs,
  so the digest depends on the values alone and never on map ordering.
  """
  @spec input_digest(map()) :: String.t()
  def input_digest(source) when is_map(source) do
    [
      ["schema_version", Map.fetch!(source, :schema_version)],
      ["trip_ids", Map.fetch!(source, :trip_ids)],
      ["first_date", source |> Map.fetch!(:first_date) |> encode_date()],
      ["last_date", source |> Map.fetch!(:last_date) |> encode_date()],
      ["delta_seconds", Map.fetch!(source, :delta_seconds)],
      ["approval_note", Map.fetch!(source, :approval_note)],
      ["source_label", Map.fetch!(source, :source_label)]
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # -- normalization ---------------------------------------------------------

  defp reject_server_owned_fields(params) do
    case params
         |> Map.keys()
         |> Enum.map(&to_string/1)
         |> Enum.filter(&(&1 in @server_owned_fields)) do
      [] -> :ok
      found -> {:error, %{base: [server_owned_message(found)]}}
    end
  end

  defp server_owned_message([field]),
    do: "#{field} is set by the server and cannot be submitted."

  defp server_owned_message(fields),
    do: "#{Enum.join(Enum.sort(fields), ", ")} are set by the server and cannot be submitted."

  defp date_error(params, field) do
    case fetch(params, field) do
      {:ok, %Date{} = date} ->
        {:ok, date}

      {:ok, value} when is_binary(value) ->
        parse_iso_date(value, field)

      _absent ->
        {:error, date_message(field)}
    end
  end

  defp parse_iso_date(value, field) do
    if Regex.match?(@iso_date_format, value) do
      value |> Date.from_iso8601() |> normalize_date_result(field)
    else
      {:error, date_message(field)}
    end
  end

  defp normalize_date_result({:ok, date}, _field), do: {:ok, date}

  defp normalize_date_result({:error, _reason}, field),
    do: {:error, "Enter #{date_label(field)} as a real calendar date."}

  defp date_message(field), do: "Enter #{date_label(field)} as YYYY-MM-DD with a four-digit year."

  defp date_label(:first_date), do: "the first date"
  defp date_label(:last_date), do: "the last date"

  defp delta_error(params) do
    case fetch(params, :delta_seconds) do
      {:ok, value} when is_integer(value) ->
        check_delta(value)

      {:ok, value} when is_binary(value) ->
        parse_delta(value)

      _absent ->
        {:error, delta_message()}
    end
  end

  defp parse_delta(value) do
    if Regex.match?(@signed_integer_format, String.trim(value)) do
      case Integer.parse(String.trim(value)) do
        {seconds, ""} -> check_delta(seconds)
        _unparsed -> {:error, delta_message()}
      end
    else
      {:error, delta_message()}
    end
  end

  defp check_delta(seconds) when seconds >= -@max_delta_seconds and seconds <= @max_delta_seconds,
    do: {:ok, seconds}

  defp check_delta(_seconds), do: {:error, delta_message()}

  defp delta_message,
    do:
      "Enter a whole-second shift between -#{@max_delta_seconds} and #{@max_delta_seconds}; use a minus sign for earlier."

  defp approval_note_error(params) do
    case fetch(params, :approval_note) do
      {:ok, value} when is_binary(value) ->
        note = String.trim(value)

        cond do
          note == "" -> {:error, "Enter the approval note you supplied for this change."}
          String.length(note) > @max_approval_note_length -> {:error, approval_note_message()}
          true -> {:ok, note}
        end

      _absent ->
        {:error, "Enter the approval note you supplied for this change."}
    end
  end

  defp approval_note_message,
    do: "Keep the approval note to #{@max_approval_note_length} characters or fewer."

  defp source_label_error(params) do
    case fetch(params, :source_label) do
      {:ok, value} when is_binary(value) ->
        source_label_value(value)

      {:ok, nil} ->
        {:ok, nil}

      _absent ->
        {:ok, nil}
    end
  end

  defp source_label_value(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      label -> check_source_label(label)
    end
  end

  defp check_source_label(label) do
    if String.length(label) > @max_source_label_length do
      {:error, source_label_message()}
    else
      {:ok, label}
    end
  end

  defp source_label_message,
    do: "Keep the source label to #{@max_source_label_length} characters or fewer."

  # Sorted and deduplicated comparisons: two callers that selected the same
  # trips in a different order produce the same draft and the same acceptance.
  # The current selection is a list of trip UUIDs, or a server map carrying them
  # under `:trip_ids`, so a host can pass the value it already holds.
  defp normalize_selection(%{trip_ids: ids}), do: normalize_selection(ids)

  defp normalize_selection(ids) when is_list(ids) do
    cond do
      not Enum.all?(ids, &is_binary/1) -> {:error, :invalid_selection}
      not Enum.all?(ids, &(Ecto.UUID.cast(&1) == {:ok, &1})) -> {:error, :invalid_selection}
      ids != Enum.uniq(ids) -> {:error, :invalid_selection}
      true -> {:ok, Enum.sort(ids)}
    end
  end

  defp normalize_selection(_selected_trip_ids), do: {:error, :invalid_selection}

  defp selection_error(selected_trip_ids) do
    case normalize_selection(selected_trip_ids) do
      {:ok, []} ->
        {:error, "Select at least one trip."}

      {:ok, ids} when length(ids) > @max_selected_trips ->
        {:error, "Select at most #{@max_selected_trips} trips."}

      {:ok, ids} ->
        {:ok, ids}

      {:error, :invalid_selection} ->
        {:error, "Select trips by their identifiers, without repeats."}
    end
  end

  defp put_errors(errors, field, result) do
    case result do
      {:ok, _value} -> errors
      {:error, message} -> Map.put(errors, field, [message])
    end
  end

  # Both dates are validated before they are compared, so a reversed interval
  # over otherwise valid dates is the only additional message it produces.
  defp put_delta_errors(errors, params) do
    errors = put_errors(errors, :delta_seconds, delta_error(params))

    with {:ok, first_date} <- date_error(params, :first_date),
         {:ok, last_date} <- date_error(params, :last_date),
         :lt <- Date.compare(last_date, first_date) do
      Map.put(errors, :last_date, ["The last date must not be before the first date."])
    else
      _valid_or_unreadable_dates -> errors
    end
  end

  defp put_selection_errors(errors, selected_trip_ids) do
    put_errors(errors, :selected_trip_ids, selection_error(selected_trip_ids))
  end

  defp build_draft(params, selected_trip_ids) do
    {:ok, first_date} = date_error(params, :first_date)
    {:ok, last_date} = date_error(params, :last_date)
    {:ok, delta_seconds} = delta_error(params)
    {:ok, approval_note} = approval_note_error(params)
    {:ok, source_label} = source_label_error(params)
    {:ok, trip_ids} = selection_error(selected_trip_ids)

    {:ok,
     %{
       first_date: first_date,
       last_date: last_date,
       delta_seconds: delta_seconds,
       approval_note: approval_note,
       source_label: source_label,
       trip_ids: trip_ids
     }}
  end

  defp fetch(params, field) do
    case Map.fetch(params, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(params, Atom.to_string(field))
    end
  end

  # -- acceptance ------------------------------------------------------------

  defp validate_draft(draft) do
    cond do
      draft |> Map.keys() |> Enum.sort() != @draft_keys -> {:error, :invalid_draft}
      Enum.any?(@draft_fields, &(not valid_draft_value?(draft, &1))) -> {:error, :invalid_draft}
      not valid_draft_selection?(draft.trip_ids) -> {:error, :invalid_draft}
      true -> :ok
    end
  end

  defp valid_draft_selection?(ids) do
    match?({:ok, _sorted}, normalize_selection(ids)) and ids == Enum.sort(ids)
  end

  defp valid_draft_value?(draft, :first_date), do: match?(%Date{}, draft.first_date)
  defp valid_draft_value?(draft, :last_date), do: match?(%Date{}, draft.last_date)

  defp valid_draft_value?(draft, :delta_seconds),
    do: is_integer(draft.delta_seconds) and abs(draft.delta_seconds) <= @max_delta_seconds

  defp valid_draft_value?(draft, :approval_note),
    do:
      is_binary(draft.approval_note) and draft.approval_note != "" and
        String.length(draft.approval_note) <= @max_approval_note_length

  defp valid_draft_value?(draft, :source_label) do
    case draft.source_label do
      nil -> true
      label -> is_binary(label) and String.length(label) <= @max_source_label_length
    end
  end

  defp accept(draft) do
    bound = %{
      schema_version: @schema_version,
      trip_ids: draft.trip_ids,
      first_date: draft.first_date,
      last_date: draft.last_date,
      delta_seconds: draft.delta_seconds,
      approval_note: draft.approval_note,
      source_label: draft.source_label
    }

    Map.put(bound, :input_digest, input_digest(bound))
  end

  defp encode_date(%Date{} = date), do: Date.to_iso8601(date)
  defp encode_date(value) when is_binary(value), do: value
end
