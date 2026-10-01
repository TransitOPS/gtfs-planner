defmodule GtfsPlanner.Agents.Packs.Alerts do
  @moduledoc """
  The Alerts helper pack: bounded reads about one alert's own schedule, and one
  prepared change the editor applies itself.

  Every call resolves the subject alert through `Alerts.get_alert/2` with the
  scope's own audit context, so an alert of another tenant, another version or
  another record is a message, not data (R1, FH-27). Every read after that is
  built from the loaded row's own organization and version, never from the
  version the person happens to have selected in the navigation, so an alert is
  always read against the schedule it was written against (CR-4). The identity
  of the organization, version, actor and alert comes from the scope alone: no
  tool declares an identity argument, so `GtfsPlanner.Agents.Dispatch` refuses
  one before this module runs (R11).

  Nothing here writes. `propose_changes` validates its arguments with
  `Alert.draft_changeset/2` - the same changeset the editor autosaves and saves
  through - and returns `{:alert_changes, params}` with a summary for the editor
  to apply through `Alerts.save_draft/4` (CR-6, INV-1). This module never calls
  a write command, and the tool list has no write tool.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Completion
  alias GtfsPlanner.Alerts.Message
  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.Gtfs.AuditContext

  @skill_path Path.expand("../../../../priv/agents/packs/alerts/SKILL.md", __DIR__)
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

  # The fields `Alert.draft_changeset/2` casts, in the order the editor asks
  # them. The three answers are objects the changeset validates field by field,
  # so a nested key this pack never read is ignored there rather than stored.
  @change_properties %{
    "urgency" => %{"type" => "string", "enum" => ["now", "planned"]},
    "situation" => %{
      "type" => "string",
      "enum" => Enum.map(Alert.situations(), &Atom.to_string/1)
    },
    "service_change_kind" => %{
      "type" => "string",
      "enum" => ["fewer_trips", "extra_service", "information"]
    },
    "cause" => %{
      "type" => "string",
      "enum" => [
        "unknown_cause",
        "other_cause",
        "technical_problem",
        "strike",
        "demonstration",
        "accident",
        "holiday",
        "weather",
        "maintenance",
        "construction",
        "police_activity",
        "medical_emergency",
        "special_event"
      ]
    },
    "cause_detail" => %{"type" => "string", "maxLength" => 200},
    "scope" => %{"type" => "object"},
    "timing" => %{"type" => "object"},
    "message" => %{"type" => "object"}
  }

  # Panel copy for each answer `propose_changes` can carry, in step order.
  @change_labels [
    {:urgency, "Now or planned"},
    {:situation, "Situation"},
    {:service_change_kind, "Service change"},
    {:cause, "Cause"},
    {:cause_detail, "Cause detail"},
    {:scope, "Who it is about"},
    {:timing, "When it applies"},
    {:message, "Rider message"}
  ]

  @impl true
  def id, do: "alerts"

  @impl true
  def title, do: "Alert assistant"

  @impl true
  def intro do
    "I can read this alert's routes, stops and departures and prepare answers for you to review. I can't save or publish anything."
  end

  @impl true
  def examples,
    do: ["Route 12 is detouring between Elm and 3rd", "Draft the rider message for this alert"]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "get_draft",
        description:
          "Read the answers this alert already has, with the routes, stops and trips it names.",
        activity: "Read the draft",
        parameters: no_arguments()
      },
      %{
        name: "search_routes",
        description:
          "Find routes in this alert's service version by short name, long name or route id. Returns the first 25 matches; ask the person to narrow the text when none fit.",
        activity: "Searched routes",
        parameters: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string", "maxLength" => 100}},
          "required" => ["query"],
          "additionalProperties" => false
        }
      },
      %{
        name: "search_stops",
        description:
          "Find stops in this alert's service version by name or stop id. Returns the first 25 matches. The preferred and excluded ids are this alert's own route and stop answers, so a narrowed search does not repeat what the draft already names.",
        activity: "Searched stops",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "maxLength" => 100},
            "prefer_route_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "maxItems" => 200
            },
            "exclude_stop_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "maxItems" => 200
            }
          },
          "required" => ["query"],
          "additionalProperties" => false
        }
      },
      %{
        name: "route_stops",
        description:
          "List the stops one route of this alert's version serves, in the order its trips serve them.",
        activity: "Listed a route's stops",
        parameters: %{
          "type" => "object",
          "properties" => %{"route_id" => %{"type" => "string"}},
          "required" => ["route_id"],
          "additionalProperties" => false
        }
      },
      %{
        name: "departures_on",
        description:
          "List one route's departures on a date, earliest first. Only trips the schedule actually runs that day are listed, so a cancelled trip is never offered for a day it does not run.",
        activity: "Listed departures",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "route_id" => %{"type" => "string"},
            "date" => %{"type" => "string"},
            "direction_id" => %{"type" => "integer", "minimum" => 0}
          },
          "required" => ["route_id", "date"],
          "additionalProperties" => false
        }
      },
      %{
        name: "list_scripts",
        description:
          "List this organization's message scripts and the built-in ones, with the situation each is written for and the placeholders its templates accept.",
        activity: "Listed message scripts",
        parameters: no_arguments()
      },
      %{
        name: "get_guidelines",
        description:
          "Read this organization's writing guidelines for rider messages and the revision they are at.",
        activity: "Read the writing guidelines",
        parameters: no_arguments()
      },
      %{
        name: "check_draft",
        description:
          "Read what this alert is still missing: the questions it has not answered, the effect its situation implies, and what to fix in the rider message. Writes nothing.",
        activity: "Checked the draft",
        parameters: no_arguments()
      },
      %{
        name: "propose_changes",
        description:
          "Prepare answers for this alert to review and apply. Takes only the answers themselves, never an identity, and saves nothing.",
        activity: "Prepared alert answers",
        parameters: %{
          "type" => "object",
          "properties" => @change_properties,
          "required" => [],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def call(name, args, %Scope{} = scope) do
    with {:ok, context, alert} <- subject(scope) do
      run(name, args, context, alert)
    end
  end

  # The subject alert is resolved once per call, before any tool runs, so no
  # tool can read an alert the scope does not name.
  defp subject(%Scope{subject_id: nil}),
    do: {:error, "Open the assistant from an alert to use it."}

  defp subject(%Scope{} = scope) do
    case Alerts.get_alert(Scope.audit_context(scope), scope.subject_id) do
      {:ok, alert} -> {:ok, alert_context(Scope.audit_context(scope), alert), alert}
      {:error, :forbidden} -> {:error, "Access to this alert changed."}
      {:error, :not_found} -> {:error, "This alert is not in this service version."}
    end
  end

  # The reads below take the alert's own organization and version, so a target
  # lookup can never follow the version the person selected in the navigation
  # (R1, CR-4).
  defp alert_context(%AuditContext{} = audit_context, %Alert{} = alert) do
    %{
      audit_context
      | organization_id: alert.organization_id,
        gtfs_version_id: alert.gtfs_version_id
    }
  end

  defp run("get_draft", _args, context, alert) do
    labels = Alerts.labels_for(context, alert)

    {:ok, draft_row(alert) |> Map.put("labels", label_row(labels))}
  end

  defp run("search_routes", args, context, _alert) do
    {:ok, %{"routes" => context |> Alerts.search_routes(args["query"]) |> route_rows()}}
  end

  defp run("search_stops", args, context, _alert) do
    stops =
      Alerts.search_stops(context, args["query"],
        prefer_route_ids: args["prefer_route_ids"] || [],
        exclude_stop_ids: args["exclude_stop_ids"] || []
      )

    {:ok, %{"stops" => stop_rows(stops)}}
  end

  defp run("route_stops", args, context, _alert) do
    {:ok, %{"stops" => context |> Alerts.route_stops(args["route_id"]) |> stop_rows()}}
  end

  defp run("departures_on", args, context, _alert) do
    with {:ok, date} <- parse_date(args["date"]),
         {:ok, direction_id} <- parse_direction(args["direction_id"]) do
      departures = Alerts.departures_on(context, args["route_id"], direction_id, date)

      {:ok, %{"departures" => Enum.map(departures, &departure_row/1)}}
    end
  end

  defp run("list_scripts", _args, context, _alert) do
    {:ok, %{"scripts" => context |> Alerts.list_scripts() |> Enum.map(&script_row/1)}}
  end

  defp run("get_guidelines", _args, context, _alert) do
    guidelines = Alerts.get_guidelines(context)

    {:ok, %{"guidelines" => guidelines.text, "revision" => guidelines.revision}}
  end

  defp run("check_draft", _args, context, alert) do
    facts = Message.facts(alert, Alerts.labels_for(context, alert))

    {:ok,
     %{
       "complete" => Completion.complete?(alert),
       "effect" => atom_string(Completion.effect_for(alert)),
       "timing" => Recurrence.summary(alert.timing),
       "outstanding" => Enum.map(Completion.errors(alert), &outstanding_row/1),
       "message_checks" =>
         (alert.message || %MessageAnswer{})
         |> Message.checks(facts)
         |> Enum.map(&message_check_row/1)
     }}
  end

  # The command carries the arguments the model chose, so the editor applies
  # exactly what the person was shown. Validation is the same changeset the
  # editor saves through, and it never casts identity, revision, completeness
  # or the derived effect (CR-2).
  defp run("propose_changes", args, _context, alert) do
    changeset = Alert.draft_changeset(alert, args)

    cond do
      map_size(args) == 0 ->
        {:error, "Provide at least one answer to change."}

      not changeset.valid? ->
        {:error, changeset_message(changeset)}

      true ->
        {:prepared, summary(alert, changeset), %{"status" => "prepared"}}
    end
  end

  defp run(name, _args, _context, _alert),
    do: {:error, "Unknown tool: " <> name}

  # -- Prepared change ------------------------------------------------------

  defp summary(alert, changeset) do
    %{
      title: "Update this alert",
      detail: detail(alert, changeset),
      lines: changed_lines(changeset)
    }
  end

  defp detail(alert, changeset) do
    "Revision #{alert.revision} · #{situation_label(changeset)}"
  end

  defp situation_label(changeset) do
    case Ecto.Changeset.get_field(changeset, :situation) do
      nil -> "situation not chosen yet"
      situation -> humanize(situation)
    end
  end

  # One line per answer the proposal carries, in the order the editor asks them,
  # so the review reads as the next step rather than as a diff.
  defp changed_lines(changeset) do
    changes = Ecto.Changeset.apply_changes(changeset)

    Enum.flat_map(@change_labels, fn {field, label} ->
      case Map.fetch(changes, field) do
        :error -> []
        {:ok, value} -> [label <> " · " <> describe(field, value)]
      end
    end)
  end

  defp describe(:scope, %ScopeAnswer{} = scope), do: shape_label(scope.shape)
  defp describe(:timing, %TimingAnswer{} = timing), do: timing_label(timing)
  defp describe(:message, %MessageAnswer{} = message), do: message_label(message)
  defp describe(_field, true), do: "yes"
  defp describe(_field, false), do: "no"
  defp describe(_field, value) when is_binary(value), do: value
  defp describe(_field, value) when is_integer(value), do: to_string(value)
  defp describe(_field, value) when is_atom(value) and not is_nil(value), do: humanize(value)
  defp describe(_field, nil), do: "not set"

  defp shape_label(nil), do: "not set"
  defp shape_label(shape), do: humanize(shape)

  defp timing_label(timing) do
    case Recurrence.summary(timing) do
      "" -> "not set"
      summary -> summary
    end
  end

  defp message_label(%MessageAnswer{header: header}) when is_binary(header) and header != "",
    do: header

  defp message_label(_message), do: "not set"

  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.replace(~r/\A./, &String.capitalize/1)

  # The changeset speaks in field names; the model is told the same words the
  # editor uses, in one sentence.
  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map(fn {field, messages} ->
      "#{humanize(field)}: #{Enum.join(messages, ", ")}"
    end)
    |> Enum.sort()
    |> Enum.join(" ")
  end

  # -- Results --------------------------------------------------------------

  defp draft_row(alert) do
    %{
      "revision" => alert.revision,
      "urgency" => atom_string(alert.urgency),
      "situation" => atom_string(alert.situation),
      "service_change_kind" => atom_string(alert.service_change_kind),
      "cause" => atom_string(alert.cause),
      "cause_detail" => alert.cause_detail,
      "effect" => atom_string(alert.effect),
      "complete" => alert.complete,
      "first_date" => civil(alert.first_date),
      "last_date" => civil(alert.last_date),
      "scope" => scope_row(alert.scope),
      "timing" => timing_row(alert.timing),
      "message" => message_row(alert.message)
    }
  end

  defp scope_row(nil), do: %{}

  defp scope_row(%ScopeAnswer{} = scope) do
    %{
      "shape" => atom_string(scope.shape),
      "mode_route_type" => scope.mode_route_type,
      "route_ids" => scope.route_ids || [],
      "stop_ids" => scope.stop_ids || [],
      "route_stop_pairs" =>
        Enum.map(scope.route_stop_pairs, &%{"route_id" => &1.route_id, "stop_id" => &1.stop_id}),
      "trips" =>
        Enum.map(
          scope.trips,
          &%{"trip_id" => &1.trip_id, "service_date" => civil(&1.service_date)}
        ),
      "direction_id" => scope.direction_id,
      "all_routes_at_stops" => scope.all_routes_at_stops,
      "stretch_from_stop_id" => scope.stretch_from_stop_id,
      "stretch_to_stop_id" => scope.stretch_to_stop_id,
      "alternative_stop_id" => scope.alternative_stop_id,
      "alternative_directions" => scope.alternative_directions,
      "facility" => scope.facility
    }
  end

  defp timing_row(nil), do: %{}

  defp timing_row(%TimingAnswer{} = timing) do
    %{
      "start_date" => civil(timing.start_date),
      "start_time" => civil(timing.start_time),
      "end_kind" => atom_string(timing.end_kind),
      "end_date" => civil(timing.end_date),
      "end_time" => civil(timing.end_time),
      "check_in_at" => civil(timing.check_in_at),
      "pattern" => atom_string(timing.pattern),
      "first_date" => civil(timing.first_date),
      "weeks" => timing.weeks,
      "weekdays" => timing.weekdays,
      "all_day" => timing.all_day,
      "last_date" => civil(timing.last_date),
      "added_dates" => civil(timing.added_dates),
      "removed_dates" => civil(timing.removed_dates),
      "notice_on" => civil(timing.notice_on),
      "time_zone" => timing.time_zone,
      "delay_minutes" => timing.delay_minutes
    }
  end

  defp message_row(nil), do: %{}

  defp message_row(%MessageAnswer{} = message) do
    %{
      "header" => message.header,
      "description" => message.description,
      "url" => message.url,
      "script_key" => message.script_key,
      "customized" => message.customized
    }
  end

  defp label_row(labels) do
    %{
      "routes" => labels.routes,
      "stops" => labels.stops,
      "trips" => labels.trips
    }
  end

  defp route_rows(options) do
    Enum.map(options, fn option ->
      %{
        "id" => option.id,
        "label" => option.label,
        "route_id" => option.route_id,
        "short_name" => option.short_name,
        "long_name" => option.long_name
      }
    end)
  end

  defp stop_rows(options) do
    Enum.map(options, fn option ->
      %{
        "id" => option.id,
        "label" => option.label,
        "stop_id" => option.stop_id,
        "stop_name" => option.stop_name,
        "platform_code" => option.platform_code
      }
    end)
  end

  defp departure_row(departure) do
    %{
      "trip_id" => departure.trip_id,
      "label" => departure.label,
      "first_departure_seconds" => departure.first_departure_seconds
    }
  end

  defp script_row(script) do
    %{
      "key" => script.key,
      "name" => script.name,
      "situation" => atom_string(script.situation),
      "header_template" => script.header_template,
      "description_template" => script.description_template,
      "built_in" => script.built_in?,
      "id" => script.id
    }
  end

  defp outstanding_row({step, field, message}) do
    %{"step" => to_string(step), "field" => to_string(field), "message" => message}
  end

  defp message_check_row(check) do
    %{"key" => to_string(check.key), "ok" => check.ok?, "text" => check.text}
  end

  # -- Argument parsing -----------------------------------------------------

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, date}

      {:error, _reason} ->
        {:error, "Invalid date: #{value}. Use a date like 2026-10-12."}
    end
  end

  defp parse_direction(nil), do: {:ok, nil}
  defp parse_direction(direction_id) when direction_id in [0, 1], do: {:ok, direction_id}
  defp parse_direction(direction_id), do: {:error, "Invalid direction: #{direction_id}."}

  # -- Shared shapes --------------------------------------------------------

  defp no_arguments do
    %{"type" => "object", "properties" => %{}, "required" => [], "additionalProperties" => false}
  end

  # Civil values cross the model boundary as text: nothing here converts a time
  # between zones (CR-7).
  defp civil(values) when is_list(values), do: Enum.map(values, &civil/1)
  defp civil(%Date{} = value), do: Date.to_iso8601(value)
  defp civil(%Time{} = value), do: Time.to_iso8601(value)
  defp civil(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp civil(value), do: value

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: value
end
