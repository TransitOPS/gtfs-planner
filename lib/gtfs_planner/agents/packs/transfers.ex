defmodule GtfsPlanner.Agents.Packs.Transfers do
  @moduledoc """
  The Transfers helper pack: what the general policy says in one supplied direction,
  what it would say after a change, and the change prepared for the person's own
  confirmation.

  Nothing here names a stop, route, trip, type or minimum time. Every one of those
  comes from the `transfer_policy` source snapshot the host admitted, so a tool
  argument can only choose *which* approved selection to look at or prepare and can
  never state an identity, reorder a direction, or restate a unit (FH-4, INV-1,
  INV-2). `authorize_context/1` refuses a conversation with no such snapshot, so the
  reads and the preparation are unreachable before the page has admitted one.

  The direction is the selection's own order, from its `from` side to its `to` side,
  and the pack never constructs, offers or describes the reverse. A selection whose
  intent is incomplete — a side that is absent, blank or the same stop twice, or a
  minimum time whose unit is neither seconds nor minutes — is asked about once and
  prepared never; the refusal names the selection and the one thing missing.

  Minimum times are converted here, in server code: a finite whole number of minutes
  is multiplied by 60 and a whole number of seconds is taken as it stands, and a
  negative, fractional or too-large value is refused rather than rounded. Types 4 and
  5 are in-seat rules, which this pack does not own, and a general type above 3 is
  refused before the review.

  `inspect_transfer_policy/3` reads the general rules the version already holds in
  that exact direction, reporting a stored reverse rule's count separately so a
  one-way rule is never described as two-way. `inspect_transfer_competition/3` runs
  `GtfsPlanner.Gtfs.Transfers.review_policy_change/3` — the same read-only review the
  preparation runs — and returns the stored rule, the rule that would be written, the
  protected exceptions and any equal-best witness the change would cause.
  `prepare_transfer_policy/3` runs that review once per selected item and returns the
  sequence of reviewed commands the Transfers page confirms one at a time. There is no
  apply tool: the pack prepares, the person's page writes, through step 2's reviewed
  apply.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Transfers

  @source_kind "transfer_policy"
  @schema_version 1
  @source_ref "gtfs_transfers"
  @max_selection_id_length 64
  @max_reference_length 200
  @max_sequence 50
  @max_min_time_seconds 2_147_483_647
  @general_types [0, 1, 2, 3]
  @in_seat_message "Types 4 and 5 are in-seat rules, which are not available here."

  @skill_path Path.expand("../../../../priv/agents/packs/transfers/SKILL.md", __DIR__)
  @external_resource @skill_path

  @skill @skill_path
         |> File.read!()
         |> String.split("\n")
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.join("\n")
         |> String.trim()

  @impl true
  def id, do: "transfers"

  @impl true
  def title, do: "Transfer helper"

  @impl true
  def intro do
    "I can explain the general transfer rules in this service version and prepare the ones you select for your own review. I can't change trips, calendars, stops or routes, and I can't set in-seat rules."
  end

  @impl true
  def examples do
    [
      "What transfer rule covers Central Station to Harbor Yards?",
      "Give that transfer five minutes"
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "inspect_transfer_policy",
        description:
          "Read the general transfer rules this service version already holds in one selected pair's own direction, with each rule's type, minimum time in seconds and protected exception. A stored rule in the reverse direction is reported as a separate count and is never described as this one. Selections come from this page, so name one of the ids you were given.",
        activity: "Checked the transfer rule",
        parameters: selection_parameter()
      },
      %{
        name: "inspect_transfer_competition",
        description:
          "Review one selected pair without preparing it: the stored rule, the rule the selection would write, the protected exceptions it keeps, and any equal-best disagreement it would cause. Use this before prepare_transfer_policy when a broad rule or an exception is involved.",
        activity: "Reviewed the transfer change",
        parameters: selection_parameter()
      },
      %{
        name: "prepare_transfer_policy",
        description:
          "Prepare the selected pairs for the person to review and apply on this page, at most #{@max_sequence} at a time. Each pair is prepared in the direction the page selected, with its minimum time converted to seconds by the server. It saves nothing; the person confirms and applies each rule themselves.",
        activity: "Prepared transfer rules",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "selection_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string", "maxLength" => @max_selection_id_length},
              "minItems" => 1,
              "maxItems" => @max_sequence
            }
          },
          "required" => ["selection_ids"],
          "additionalProperties" => false
        }
      }
    ]
  end

  defp selection_parameter do
    %{
      "type" => "object",
      "properties" => %{
        "selection_id" => %{"type" => "string", "maxLength" => @max_selection_id_length}
      },
      "required" => ["selection_id"],
      "additionalProperties" => false
    }
  end

  # A conversation with no admitted `transfer_policy` source has nothing this pack
  # may read, so it is refused here as well as in each tool. Only the envelope is
  # checked: a selection's own content is reported back to the model as a message it
  # can act on, rather than collapsing an over-large or foreign selection into the
  # one refusal that also means "another version's page".
  @impl true
  def authorize_context(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{
        kind: @source_kind,
        payload: %{"schema_version" => @schema_version, "selections" => selections}
      }
      when is_list(selections) ->
        :ok

      _other ->
        {:error, :unavailable}
    end
  end

  @impl true
  def call("inspect_transfer_policy", args, %Scope{} = scope),
    do: inspect_transfer_policy(args["selection_id"], scope)

  def call("inspect_transfer_competition", args, %Scope{} = scope),
    do: inspect_transfer_competition(args["selection_id"], scope)

  def call("prepare_transfer_policy", args, %Scope{} = scope),
    do: prepare_transfer_policy(args["selection_ids"], scope)

  # -- reads -----------------------------------------------------------------

  defp inspect_transfer_policy(selection_id, scope) do
    with {:ok, selection} <- selection(selection_id, scope) do
      stored = stored_rules(selection, scope)
      result = policy_result(selection, stored, scope)

      {:ok, result, policy_evidence(selection, stored, scope, result)}
    end
  end

  # The review is the only honest answer to "what would this do": it builds the
  # prospective rule through the editor's own changeset and evaluates it against the
  # real overlap witnesses, so an equal-best disagreement is refused here exactly as
  # it would be at preparation rather than described as acceptable.
  defp inspect_transfer_competition(selection_id, scope) do
    with {:ok, selection} <- selection(selection_id, scope),
         {:ok, command} <- command(selection, scope),
         {:ok, review} <- review(command, scope) do
      result = review_result(selection, review, scope)

      {:ok, result, review_evidence(selection, review, scope, result)}
    end
  end

  # -- preparation -----------------------------------------------------------

  defp prepare_transfer_policy(selection_ids, scope) when is_list(selection_ids) do
    with {:ok, selections} <- selections(selection_ids, scope),
         {:ok, commands} <- commands(selections, scope) do
      prepared_commands =
        Enum.map(commands, fn {selection, _command, review} ->
          %{selection: selection, command: review.command, review: review}
        end)

      result = sequence_result(prepared_commands, scope)

      {:prepared,
       %{
         summary: sequence_summary(prepared_commands, scope),
         command: %{
           kind: :transfer_policy_sequence,
           items: Enum.map(prepared_commands, & &1.command),
           source_digest: source_digest(scope)
         }
       }, result, sequence_evidence(prepared_commands, scope, result)}
    end
  end

  defp prepare_transfer_policy(_selection_ids, _scope),
    do: {:error, "Name the selections to prepare."}

  # One item is refused whole rather than prepared beside a failed neighbour: a
  # sequence the page would apply item by item is only truthful if every item is the
  # reviewed command, and a partially prepared sequence would leave the person
  # confirming a list whose order they never saw.
  defp commands(selections, scope) do
    Enum.reduce_while(selections, {:ok, []}, fn selection, {:ok, acc} ->
      case reviewed_item(selection, scope) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp reviewed_item(selection, scope) do
    with {:ok, command} <- command(selection, scope),
         {:ok, review} <- review(command, scope) do
      {:ok, {selection, command, review}}
    end
  end

  # -- the admitted selections ---------------------------------------------

  defp selections(selection_ids, scope) do
    available = selection_index(scope)

    with :ok <- check_sequence(selection_ids) do
      resolve_selections(selection_ids, available, [])
    end
  end

  defp resolve_selections([id | rest], available, acc) do
    case Map.fetch(available, id) do
      {:ok, selection} -> resolve_selections(rest, available, acc ++ [selection])
      :error -> {:error, unknown_selection(id)}
    end
  end

  defp resolve_selections([], _available, acc), do: {:ok, acc}

  defp selection(selection_id, scope) when is_binary(selection_id) do
    case Map.fetch(selection_index(scope), selection_id) do
      {:ok, selection} -> {:ok, selection}
      :error -> {:error, unknown_selection(selection_id)}
    end
  end

  defp selection(_selection_id, _scope) do
    {:error, "Name one of the transfer selections on this page."}
  end

  defp unknown_selection(id),
    do: "The selection " <> inspect(id) <> " is not one of the selections on this page."

  defp check_sequence(selection_ids) do
    cond do
      selection_ids == [] ->
        {:error, "Name the selections to prepare."}

      length(selection_ids) > @max_sequence ->
        {:error, "Prepare at most #{@max_sequence} selections at a time."}

      not Enum.all?(
        selection_ids,
        &(is_binary(&1) and String.length(&1) <= @max_selection_id_length)
      ) ->
        {:error, "A selection id is not one of the selections on this page."}

      true ->
        :ok
    end
  end

  # A selection that is not the documented shape is not described at all: the pack
  # answers the selections it can read and refuses the rest, so no model text can
  # turn a malformed entry into an identity.
  defp selection_index(scope) do
    %{"selections" => selections} = Scope.source_snapshot(scope).payload

    Map.new(selections, fn selection ->
      case normalize_selection(selection) do
        {:ok, normalized} -> {normalized.id, normalized}
        :error -> {nil, nil}
      end
    end)
    |> Map.delete(nil)
  end

  defp normalize_selection(selection) do
    with {:ok, id} <- selection_id(selection["id"]),
         {:ok, from} <- side(selection["from"]),
         {:ok, to} <- side(selection["to"]) do
      {:ok,
       %{
         id: id,
         from: from,
         to: to,
         transfer_type: selection["transfer_type"],
         min_time: selection["min_time"],
         protected_ids: selection["protected_ids"] || []
       }}
    else
      _other -> :error
    end
  end

  defp selection_id(id) when is_binary(id) and byte_size(id) > 0,
    do: if(String.length(id) <= @max_selection_id_length, do: {:ok, id}, else: :error)

  defp selection_id(_id), do: :error

  defp side(%{} = side) do
    case {reference(side["stop_id"]), reference(side["route_id"]), reference(side["trip_id"])} do
      {{:ok, stop_id}, {:ok, route_id}, {:ok, trip_id}} ->
        {:ok, %{stop_id: stop_id, route_id: route_id, trip_id: trip_id}}

      _other ->
        :error
    end
  end

  defp side(_side), do: :error

  defp reference(nil), do: {:ok, nil}

  defp reference(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or String.length(trimmed) > @max_reference_length do
      :error
    else
      {:ok, trimmed}
    end
  end

  defp reference(_value), do: :error

  # -- the reviewed command -------------------------------------------------

  defp command(selection, _scope) do
    with :ok <- check_direction(selection),
         {:ok, transfer_type} <- transfer_type(selection),
         {:ok, min_transfer_time} <- min_transfer_time(selection, transfer_type) do
      {:ok,
       %{
         action: :create,
         target_id: nil,
         expected_updated_at: nil,
         attrs: %{
           from_stop_id: selection.from.stop_id,
           to_stop_id: selection.to.stop_id,
           from_route_id: selection.from.route_id,
           to_route_id: selection.to.route_id,
           from_trip_id: selection.from.trip_id,
           to_trip_id: selection.to.trip_id,
           transfer_type: transfer_type,
           min_transfer_time: min_transfer_time
         },
         protected_ids: selection.protected_ids
       }}
    end
  end

  # The direction is the selection's own order, so a selection is either
  # unambiguous or refused. There is no default and no reciprocal: the pack never
  # answers a question the page did not ask.
  defp check_direction(selection) do
    from = selection.from
    to = selection.to

    cond do
      is_nil(from.stop_id) ->
        {:error,
         "Which side is the transfer from? I have not prepared anything for #{selection.id}."}

      is_nil(to.stop_id) ->
        {:error,
         "Which side is the transfer to? I have not prepared anything for #{selection.id}."}

      from.stop_id == to.stop_id ->
        {:error,
         "The two sides of #{selection.id} are the same stop. Which one is the transfer from?"}

      true ->
        :ok
    end
  end

  defp transfer_type(%{transfer_type: type}) when type in @general_types, do: {:ok, type}
  defp transfer_type(%{transfer_type: 4}), do: {:error, @in_seat_message}
  defp transfer_type(%{transfer_type: 5}), do: {:error, @in_seat_message}

  defp transfer_type(%{transfer_type: type}) when is_integer(type),
    do: {:error, transfer_type_message(type)}

  defp transfer_type(%{transfer_type: _other}),
    do: {:error, "This selection has no general transfer type."}

  # The only conversion of a unit into a stored value happens here, on a finite
  # whole number, so 5 minutes is 300 seconds and 4.5 minutes or -60 is refused
  # rather than rounded into a rule nobody reviewed.
  # A minimum time is only stored by a type 2 rule, and a type 2 rule only has one
  # when the page stated a whole number of seconds or minutes. Everything else is
  # refused here rather than rounded, and a minimum on another type is refused
  # rather than silently dropped.
  defp min_transfer_time(%{min_time: nil}, 2),
    do: {:error, "A type 2 rule needs a minimum time in seconds or minutes."}

  defp min_transfer_time(%{min_time: %{"value" => value, "unit" => unit}}, 2),
    do: seconds(value, unit)

  defp min_transfer_time(%{min_time: %{"value" => _value, "unit" => _unit}}, _type),
    do: {:error, "Only a type 2 rule stores a minimum time."}

  defp min_transfer_time(%{min_time: _other}, 2),
    do: {:error, min_time_message(nil)}

  defp min_transfer_time(%{min_time: nil}, _transfer_type), do: {:ok, nil}

  defp min_transfer_time(%{min_time: _other}, _transfer_type),
    do: {:error, "Only a type 2 rule stores a minimum time."}

  defp seconds(value, "seconds") when is_integer(value) and value >= 0,
    do: bounded_seconds(value, value)

  defp seconds(value, "minutes") when is_integer(value) and value >= 0,
    do: bounded_seconds(value * 60, value)

  defp seconds(value, "seconds") when is_integer(value),
    do: {:error, negative_min_time_message(value)}

  defp seconds(value, "minutes") when is_integer(value),
    do: {:error, negative_min_time_message(value)}

  defp seconds(_value, unit) when unit in ["seconds", "minutes"],
    do: {:error, min_time_message(unit)}

  defp seconds(_value, _unit), do: {:error, min_time_message(nil)}

  defp bounded_seconds(seconds, _given)
       when is_integer(seconds) and seconds >= 0 and seconds <= @max_min_time_seconds,
       do: {:ok, seconds}

  defp bounded_seconds(_seconds, _given), do: {:error, "That minimum time is too large to store."}

  defp review(command, scope) do
    audit = Scope.audit_context(scope)

    policy_scope = %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id
    }

    case Transfers.review_policy_change(policy_scope, command, audit) do
      {:ok, review} -> {:ok, review}
      {:error, reason} -> {:error, review_message(reason)}
    end
  end

  # -- stored rules ---------------------------------------------------------

  defp stored_rules(selection, scope) do
    Transfers.load_catalog(scope.organization_id, scope.gtfs_version_id,
      view: :general,
      per_page: @max_sequence
    ).rows
    |> Enum.filter(&rule_matches?(&1.transfer, selection))
  end

  # The stored pair is the selection's pair in the selection's order. A rule stored
  # the other way round is a different rule and is counted, never returned here.
  defp rule_matches?(transfer, selection) do
    transfer.from_stop_id == selection.from.stop_id and
      transfer.to_stop_id == selection.to.stop_id and
      transfer.from_route_id == selection.from.route_id and
      transfer.to_route_id == selection.to.route_id and
      transfer.from_trip_id == selection.from.trip_id and
      transfer.to_trip_id == selection.to.trip_id
  end

  defp reverse_count(selection, scope) do
    Transfers.load_catalog(scope.organization_id, scope.gtfs_version_id,
      view: :general,
      per_page: @max_sequence
    ).rows
    |> Enum.count(fn row ->
      row.transfer.from_stop_id == selection.to.stop_id and
        row.transfer.to_stop_id == selection.from.stop_id
    end)
  end

  # -- results --------------------------------------------------------------

  defp policy_result(selection, stored, scope) do
    %{
      "selection_id" => selection.id,
      "from_stop_id" => selection.from.stop_id,
      "to_stop_id" => selection.to.stop_id,
      "direction" => direction_label(selection),
      "rules" => Enum.map(stored, &rule_row/1),
      "total" => length(stored),
      "reverse_direction_rules" => reverse_count(selection, scope),
      "stored_minimum_seconds" => stored_minimum(stored)
    }
  end

  defp stored_minimum([]), do: nil
  defp stored_minimum(stored), do: Enum.find_value(stored, & &1.transfer.min_transfer_time)

  defp rule_row(row) do
    %{
      "id" => row.id,
      "transfer_type" => row.transfer.transfer_type,
      "min_transfer_time" => row.transfer.min_transfer_time,
      "rank" => row.rank,
      "competitor_ids" => row.competitor_ids
    }
  end

  defp review_result(selection, review, scope) do
    %{
      "selection_id" => selection.id,
      "from_stop_id" => selection.from.stop_id,
      "to_stop_id" => selection.to.stop_id,
      "direction" => direction_label(selection),
      "before" => review.before,
      "after" => review.after,
      "protected" => review.protected,
      "protected_count" => length(review.protected),
      "conflicts" => Enum.map(review.conflicts, &conflict_row/1),
      "conflict_count" => length(review.conflicts),
      "dependencies_digest" => review.dependencies_digest,
      "source_digest" => source_digest(scope)
    }
  end

  defp conflict_row(conflict),
    do: Map.new(conflict, fn {key, value} -> {to_string(key), value} end)

  defp sequence_result(items, scope) do
    %{
      "selections" => Enum.map(items, &item_result/1),
      "total" => length(items),
      "source_digest" => source_digest(scope),
      "dependencies_digest" => List.first(items) |> review_digest()
    }
  end

  defp item_result(%{selection: selection, review: review}) do
    %{
      "selection_id" => selection.id,
      "from_stop_id" => selection.from.stop_id,
      "to_stop_id" => selection.to.stop_id,
      "direction" => direction_label(selection),
      "after" => review.after,
      "protected_count" => length(review.protected),
      "conflict_count" => length(review.conflicts)
    }
  end

  defp review_digest(nil), do: nil
  defp review_digest(%{review: review}), do: review.dependencies_digest

  # -- summaries ------------------------------------------------------------

  defp sequence_summary(items, scope) do
    %{
      title: "Prepare #{count_label(length(items), "transfer rule", "transfer rules")}",
      detail:
        Enum.map_join(items, ", ", fn %{selection: selection} ->
          direction_label(selection) <> minimum_label(selection)
        end),
      lines: [
        "Selected on this page · nothing is saved",
        "Exceptions kept · #{Enum.sum(Enum.map(items, &length(&1.review.protected)))}",
        "Source digest · #{String.slice(source_digest(scope), 0, 12)}"
      ]
    }
  end

  defp minimum_label(selection) do
    case selection.min_time && seconds(selection.min_time["value"], selection.min_time["unit"]) do
      {:ok, seconds} -> " · #{seconds} seconds"
      _other -> ""
    end
  end

  defp count_label(1, one, _many), do: "1 #{one}"
  defp count_label(count, _one, many), do: "#{count} #{many}"

  defp direction_label(selection),
    do: "#{selection.from.stop_id} to #{selection.to.stop_id}"

  # -- evidence -------------------------------------------------------------

  defp policy_evidence(selection, stored, scope, result) do
    evidence(
      "transfer_policy",
      "General rule #{direction_label(selection)}",
      length(stored),
      "stored general rules",
      scope,
      result,
      [
        %{label: "Direction", value: direction_label(selection)},
        %{label: "Stored minimum", value: stored_minimum_label(stored)},
        %{
          label: "Reverse direction rules",
          value: Integer.to_string(result["reverse_direction_rules"])
        }
      ]
    )
  end

  defp stored_minimum_label([]), do: "None stored"
  defp stored_minimum_label(stored), do: seconds_label(stored_minimum(stored))

  defp seconds_label(nil), do: "None stored"
  defp seconds_label(seconds), do: "#{seconds} seconds"

  defp review_evidence(selection, review, scope, result) do
    evidence(
      "transfer_policy_review",
      "Review of #{direction_label(selection)}",
      1,
      "reviewed selection",
      scope,
      result,
      [
        %{label: "Direction", value: direction_label(selection)},
        %{label: "Protected exceptions", value: Integer.to_string(length(review.protected))},
        %{label: "Equal-best disagreements", value: Integer.to_string(length(review.conflicts))},
        %{label: "Would store", value: minimum_label(selection)}
      ]
    )
  end

  defp sequence_evidence(items, scope, result) do
    evidence(
      "transfer_policy_sequence",
      count_label(length(items), "prepared transfer rule", "prepared transfer rules"),
      length(items),
      "prepared rules",
      scope,
      result,
      [
        %{label: "Directions prepared", value: Integer.to_string(length(items))},
        %{
          label: "Exceptions kept",
          value: Integer.to_string(Enum.sum(Enum.map(items, &length(&1.review.protected))))
        },
        %{
          label: "Equal-best disagreements",
          value: Integer.to_string(Enum.sum(Enum.map(items, &length(&1.review.conflicts))))
        }
      ]
    )
  end

  # The card's count is the server's count over the rows the answer describes, the
  # digest is the admitted source the answer was read against, and no reference
  # outside this version is named (INV-2).
  defp evidence(kind, title, total, total_label, scope, result, facts) do
    %{
      kind: kind,
      title: title,
      total: total,
      total_label: total_label,
      completeness: :complete,
      completeness_reason: nil,
      facts: facts,
      source_ref: @source_ref,
      digest: source_digest(scope),
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: [],
      resources:
        Enum.map(result_references(result), fn {id, label} ->
          %{kind: "transfer_selection", id: id, label: label}
        end)
    }
  end

  # The only reference a card carries is the admitted selection it answers, in the
  # direction that selection states. A read, a review and a sequence each name
  # their selections differently, so the pairs are collected from whichever key the
  # result used rather than duplicated per builder.
  defp result_references(result) do
    case result["selections"] do
      selections when is_list(selections) ->
        Enum.map(selections, &{&1["selection_id"], &1["direction"]})

      _single ->
        case result["selection_id"] do
          id when is_binary(id) -> [{id, result["direction"]}]
          _none -> []
        end
    end
  end

  defp identity_label(scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  defp source_digest(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{digest: digest} -> digest
      nil -> "none"
    end
  end

  # -- refusals -------------------------------------------------------------

  defp transfer_type_message(type),
    do: "#{type} is not a general transfer type. Use 0, 1, 2 or 3."

  defp min_time_message(_unit),
    do: "A minimum time is a whole number of seconds or minutes."

  defp negative_min_time_message(value),
    do: "#{value} is not a time. A minimum time is zero or more seconds or minutes."

  defp review_message(:forbidden), do: "Access to transfers changed."
  defp review_message(:not_found), do: "That transfer is not in this service version."
  defp review_message(:stale), do: "These transfer rules changed in another session. Try again."

  defp review_message(:protected),
    do: "That rule is a protected exception and was left unchanged."

  defp review_message(:invalid_input), do: "That selection cannot be prepared as asked."

  defp review_message({:conflict, witnesses}) do
    "Two equally specific rules would disagree: " <>
      Enum.map_join(List.wrap(witnesses), "; ", &conflict_label/1) <>
      ". Change one of the commands yourself before this can be prepared."
  end

  # The reference checks run inside the review, against this organization and
  # version only, so their own editor message is the one the model reads. It names
  # a field of the selection, never a row in another version.
  defp review_message(%Ecto.Changeset{} = changeset) do
    messages =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> Enum.map_join(" ", fn {field, [message | _rest]} -> "#{field} #{message}" end)

    if messages == "", do: "That transfer rule could not be prepared.", else: messages
  end

  defp review_message(_reason), do: "That transfer rule could not be prepared."

  defp conflict_label(witness) do
    inspect(Map.get(witness, :from, nil)) <> " and " <> inspect(Map.get(witness, :to, nil))
  end
end
