defmodule GtfsPlanner.Gtfs.Flex.Assistant do
  @moduledoc """
  The scoped Flex policy workspace: the saved service a helper conversation is
  about, read once and frozen (AC-1, AC-3; CL-1).

  `workspace/2` is the host-only initial capture entrypoint. It authorizes the
  current editor, resolves the service UUID it is given through the existing
  `GtfsPlanner.Gtfs.Flex.get_service/3` in the scope's trusted organization and
  version, and reads the service, its areas and their geometry, the calendars
  its stored fields name, the readiness facts and the computed checks inside one
  PostgreSQL `REPEATABLE READ READ ONLY` transaction
  (`GtfsPlanner.Gtfs.Flex.Assistant.Snapshot`). Every part of the answer
  therefore describes one database state, and a controlled writer that commits
  between two of its reads is invisible to all of it. The transaction is closed
  before the caller makes any provider request, so no provider call is ever made
  while the snapshot is held.

  `workspace/1` is the same loader for a conversation: it reads the service ID
  from the accepted source snapshot and delegates. The `service_id` a workspace
  is loaded for always comes from the successfully loaded native page, never
  from a tool argument or model output.

  ## Authority and refusals

    * The organization and version come from the scope and are never cast from a
      caller's argument. A service of another organization or version, a deleted
      service and a malformed id are the single `{:error, :unavailable}`, so no
      foreign metadata is disclosed.
    * A membership that is no longer an active editor is `{:error, :forbidden}`,
      checked through `GtfsPlanner.Agents.Scope.authorized_context/1` before any
      service read.
    * Nothing here writes: no entity, audit or job row, and the read-only
      transaction makes an accidental write impossible rather than merely
      unlikely.

  ## Completeness

  A calendar a stored field of the service names — an hours row, a booking rule,
  a detour's `calendar_service_ids`, or the office calendar a business-day rule
  depends on — must exist in the scoped version for the workspace to be a
  complete review. A missing one is `{:error, {:incomplete, reason}}` naming the
  calendar; no supported-policy review is ever reported from a workspace whose
  inputs are missing. The whole provider projection plus its evidence shares the
  existing 32 KiB tool-result bound, and an over-limit workspace is explicitly
  `{:incomplete, :workspace_too_large}` rather than a truncated complete answer.

  ## What the workspace carries

  The `:dependencies` and `:facts` members are the complete exact inputs
  `GtfsPlanner.Gtfs.Flex.Checks.run/3` and
  `GtfsPlanner.Gtfs.Flex.Export.plan/5` need, plus the generated wording
  `GtfsPlanner.Gtfs.Flex.RiderText` produces. `:view` is the minimal projection
  the provider may see: the selected service's policy fields, its named areas by
  key, the relevant calendar rows and exceptions, the generated wording and the
  computed checks. Area geometry, the version's full facts and every other
  service's records are in the workspace for the server's own use and are never
  in the view.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Assistant.Snapshot
  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo

  # The existing tool-result bound shared by one result and its evidence
  # (`GtfsPlanner.Agents.Dispatch`). An over-limit workspace is refused whole.
  @max_projection_bytes 32_768

  @snapshot_kind "flex_policy"

  @source_ref "gtfs_flex_policy_workspace"

  @typedoc """
  The exact saved inputs one workspace froze.

  `service` carries its areas in position order, `areas` and `geojson` are the
  area rows and their stored geometry as `Export.plan/5` reads them, and
  `calendar_rows` holds the weekly row, exceptions and attributes of every
  calendar the service's stored fields name. `fingerprint/1` digests exactly
  this map, so a later transaction can re-read the same content and compare.
  """
  @type dependencies :: %{
          service: FlexService.t(),
          areas: [FlexArea.t()],
          geojson: %{optional(Ecto.UUID.t()) => map()},
          calendar_rows: %{optional(String.t()) => calendar_row()}
        }

  @typedoc "One referenced calendar's weekly row, exceptions and attributes."
  @type calendar_row :: %{
          service_id: String.t(),
          weekly: map() | nil,
          exceptions: [%{date: Date.t(), exception_type: integer()}],
          attributes: map() | nil
        }

  @typedoc """
  One complete workspace: the frozen dependencies, the exact native inputs and
  answers derived from them, and the bounded projection a provider may read.
  """
  @type workspace :: %{
          required(:service_id) => Ecto.UUID.t(),
          required(:dependencies) => dependencies(),
          required(:fingerprint) => String.t(),
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          required(:area_inputs) => [%{area: FlexArea.t(), geojson: map() | nil}],
          required(:calendars) => map(),
          required(:calendar_rows) => %{optional(String.t()) => calendar_row()},
          required(:facts) => Checks.facts(),
          required(:checks) => [Checks.check()],
          required(:check_status) => map(),
          required(:wording) => map(),
          required(:view) => map()
        }

  # --- entry points -----------------------------------------------------------

  @doc """
  Loads the workspace for the service named by this scope's accepted source.

  The service ID comes from the accepted `flex_policy` snapshot, never from a
  tool argument. A scope with no accepted snapshot, a snapshot of another kind
  and a snapshot without a service ID are the single `{:error, :unavailable}`.
  """
  @spec workspace(Scope.t()) ::
          {:ok, workspace(), Pack.evidence()} | {:error, workspace_error()}
  def workspace(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{kind: @snapshot_kind, payload: %{"service_id" => service_id}}
      when is_binary(service_id) ->
        workspace(scope, service_id)

      _other ->
        {:error, :unavailable}
    end
  end

  @doc """
  Loads the scoped Flex policy workspace for one service.

  `service_id` is the service the native page already loaded. Returns
  `{:ok, workspace, evidence}`, `{:error, :forbidden}` for a membership that is
  no longer an active editor, `{:error, :unavailable}` for a service this
  organization and version cannot resolve, and `{:error, {:incomplete, reason}}`
  when a calendar the service names is missing or the bounded projection does
  not fit one tool result.
  """
  @spec workspace(Scope.t(), Ecto.UUID.t() | String.t()) ::
          {:ok, workspace(), Pack.evidence()} | {:error, workspace_error()}
  def workspace(%Scope{} = scope, service_id) do
    with :ok <- Scope.authorized_context(scope) do
      organization_id = scope.organization_id
      version_id = scope.gtfs_version_id

      case in_snapshot(fn ->
             with {:ok, service} <- Flex.get_service(organization_id, version_id, service_id) do
               build(organization_id, version_id, service)
             end
           end) do
        {:ok, {:ok, workspace}} ->
          {:ok, workspace, evidence(workspace, scope)}

        {:ok, {:error, :not_found}} ->
          # A service of another organization or version, a deleted service and a
          # malformed id are the same answer, so no foreign metadata is disclosed.
          {:error, :unavailable}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  The canonical digest of one workspace's saved dependencies.

  It covers the exact stored content — the service's complete ordered fields
  with its `lock_version`, its hours and booking rules in order, its areas in
  position order with their stored geometry, and every referenced calendar's
  weekly row, exceptions and attributes — encoded deterministically, so two
  reads of the same content always agree and any committed change to any of
  them does not. `updated_at` alone is never the dependency, and nothing here
  reads the clock.
  """
  @spec fingerprint(dependencies()) :: String.t()
  def fingerprint(%{service: %FlexService{}} = dependencies) when is_map(dependencies) do
    %{
      scope: {dependencies.service.organization_id, dependencies.service.gtfs_version_id},
      service: service_snapshot(dependencies.service),
      areas: Enum.map(dependencies.areas, &area_snapshot(&1, dependencies.geojson)),
      calendars: dependencies.calendar_rows
    }
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @typedoc "One refusal or incompleteness reason from `workspace/2`."
  @type workspace_error :: :forbidden | :unavailable | {:incomplete, term()}

  # --- snapshot boundary ------------------------------------------------------

  # Every source read of one workspace happens inside this transaction and the
  # fingerprint is derived from the rows it returned. The transaction is closed
  # before the caller builds a model request, so no provider call is made while
  # the snapshot is held.
  defp in_snapshot(fun) when is_function(fun, 0) do
    Repo.transaction(
      fn ->
        snapshot_module().begin_read()
        fun.()
      end,
      timeout: :infinity
    )
  end

  defp snapshot_module do
    Application.get_env(:gtfs_planner, :gtfs_flex_assistant_snapshot, Snapshot.Repo)
  end

  # --- workspace parts --------------------------------------------------------

  # Every calendar the service's stored fields name, in a stable order: its
  # hours rows, its booking rules, a business-day rule's office calendar and a
  # detour's own calendars.
  defp referenced_calendar_ids(%FlexService{} = service) do
    hours_ids = Enum.map(service.hours, & &1.service_id)

    rule_ids =
      Enum.flat_map(service.booking_rules, fn rule ->
        [rule.service_id, office_service_id(rule)]
      end)

    (hours_ids ++ rule_ids ++ service.calendar_service_ids)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Only a business-day rule depends on an office calendar; the field is
  # otherwise inert, so an unset one is not a missing dependency.
  defp office_service_id(%{business_days: true, office_service_id: service_id})
       when is_binary(service_id) and service_id != "",
       do: service_id

  defp office_service_id(_rule), do: nil

  defp referenced_calendar_rows(organization_id, version_id, %FlexService{} = service) do
    service_ids = referenced_calendar_ids(service)

    weekly = calendar_rows(Calendar, organization_id, version_id, service_ids)
    attributes = attribute_rows(organization_id, version_id, service_ids)

    exceptions =
      exception_rows(organization_id, version_id, service_ids)
      |> Enum.group_by(& &1.service_id)

    Map.new(service_ids, fn service_id ->
      {service_id,
       %{
         service_id: service_id,
         weekly: Map.get(weekly, service_id),
         exceptions: Map.get(exceptions, service_id, []) |> Enum.sort_by(&exception_order/1),
         attributes: Map.get(attributes, service_id)
       }}
    end)
  end

  defp exception_order(%{date: %Date{} = date, exception_type: type}),
    do: {date, type}

  defp calendar_rows(schema, organization_id, version_id, service_ids) do
    from(row in schema,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id and
          row.service_id in ^service_ids,
      select: row
    )
    |> Repo.all()
    |> Map.new(&{&1.service_id, &1})
  end

  defp attribute_rows(organization_id, version_id, service_ids) do
    from(row in CalendarAttribute,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id and
          row.service_id in ^service_ids,
      select: row
    )
    |> Repo.all()
    |> Map.new(&{&1.service_id, &1})
  end

  defp exception_rows(organization_id, version_id, service_ids) do
    from(row in CalendarDate,
      where:
        row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id and
          row.service_id in ^service_ids,
      order_by: [asc: row.date, asc: row.exception_type],
      select: row
    )
    |> Repo.all()
  end

  # A calendar that has no weekly row, no exception and no attribute in this
  # organization and version does not exist here, whatever another organization
  # or version holds. The service names it, so the workspace is incomplete
  # rather than complete over a missing input.
  defp check_referenced_calendars(%FlexService{} = service, calendar_rows) do
    missing =
      service
      |> referenced_calendar_ids()
      |> Enum.filter(&(not calendar_present?(calendar_rows, &1)))

    case missing do
      [] -> :ok
      [service_id | _rest] -> Repo.rollback({:incomplete, {:missing_calendar, service_id}})
    end
  end

  defp calendar_present?(calendar_rows, service_id) do
    case Map.fetch(calendar_rows, service_id) do
      {:ok, %{weekly: nil, exceptions: [], attributes: nil}} -> false
      {:ok, _row} -> true
      :error -> false
    end
  end

  # --- the workspace ----------------------------------------------------------

  defp build(organization_id, version_id, %FlexService{} = service) do
    calendar_rows = referenced_calendar_rows(organization_id, version_id, service)

    with :ok <- check_referenced_calendars(service, calendar_rows) do
      dependencies = %{
        service: service,
        areas: service.areas,
        geojson: Geometry.get_geojson(Enum.map(service.areas, & &1.id)),
        calendar_rows: calendar_rows
      }

      build_workspace(organization_id, version_id, service, dependencies)
    end
  end

  defp build_workspace(organization_id, version_id, service, dependencies) do
    calendars = Flex.calendars_map(organization_id, version_id)
    facts = Checks.version_facts(organization_id, version_id)

    others =
      organization_id
      |> Flex.list_services(version_id)
      |> Enum.reject(&(&1.id == service.id))

    checks = Checks.run(service, facts, others)

    area_inputs =
      Enum.map(service.areas, fn area ->
        %{area: area, geojson: Map.get(dependencies.geojson, area.id)}
      end)

    workspace = %{
      service_id: service.id,
      dependencies: dependencies,
      fingerprint: fingerprint(dependencies),
      organization_id: organization_id,
      gtfs_version_id: version_id,
      area_inputs: area_inputs,
      calendars: calendars,
      calendar_rows: dependencies.calendar_rows,
      facts: facts,
      checks: checks,
      check_status: Checks.status(service, checks),
      wording: wording(service, calendars),
      view: nil
    }

    workspace = Map.put(workspace, :view, view(workspace))

    if bounded?(workspace) do
      {:ok, workspace}
    else
      Repo.rollback({:incomplete, :workspace_too_large})
    end
  end

  # The native generated wording for the saved service, computed here so the
  # review and the export read the same words the service page shows. A saved
  # service compared with itself has no unsaved changes.
  defp wording(%FlexService{} = service, calendars) do
    %{
      where_line: RiderText.where_line(service),
      hours_lines: RiderText.hours_lines(service, service.areas, calendars),
      deadline_lines: RiderText.deadline_lines(service, calendars),
      message: RiderText.message(service, calendars),
      rider_name: RiderText.rider_name(service),
      changes: RiderText.changes(service, service, calendars)
    }
  end

  defp bounded?(%{view: view}) do
    byte_size(Jason.encode!(view)) + byte_size(Jason.encode!(evidence_facts(view))) <=
      @max_projection_bytes
  end

  # --- the provider projection ------------------------------------------------

  defp view(workspace) do
    service = workspace.dependencies.service

    %{
      "service" => service_view(service),
      "areas" => Enum.map(workspace.area_inputs, &area_view/1),
      "hours" => Enum.map(service.hours, &hours_view/1),
      "booking_rules" => Enum.map(service.booking_rules, &rule_view/1),
      "calendars" => workspace.calendar_rows |> Map.values() |> Enum.map(&calendar_view/1),
      "rider_text" => %{
        "rider_name" => workspace.wording.rider_name,
        "where" => workspace.wording.where_line,
        "hours_lines" => workspace.wording.hours_lines,
        "deadline_lines" => workspace.wording.deadline_lines,
        "message" => workspace.wording.message,
        "changes" => workspace.wording.changes
      },
      "checks" => Enum.map(workspace.checks, &check_view/1),
      "check_status" => %{
        "tone" => Atom.to_string(workspace.check_status.tone),
        "label" => workspace.check_status.label,
        "errors" => workspace.check_status.errors,
        "warnings" => workspace.check_status.warnings
      },
      "fingerprint" => workspace.fingerprint
    }
  end

  # The selected service's own policy and contact fields. Nothing here is another
  # service's, and no geometry, calendar fact set or contact record of anything
  # else is included.
  defp service_view(%FlexService{} = service) do
    %{
      "id" => service.id,
      "key" => service.key,
      "name" => service.name,
      "kind" => Atom.to_string(service.kind),
      "active" => service.active,
      "riders" => Atom.to_string(service.riders),
      "eligibility" => service.eligibility,
      "include_registered" => service.include_registered,
      "phone" => service.phone,
      "phone_hours" => service.phone_hours,
      "booking_url" => service.booking_url,
      "info_url" => service.info_url,
      "note" => service.note,
      "route_id" => service.route_id,
      "distance_m" => service.distance_m,
      "wording" => service.wording,
      "measure" => Atom.to_string(service.measure),
      "first_stop_id" => service.first_stop_id,
      "last_stop_id" => service.last_stop_id,
      "dropoffs" => Atom.to_string(service.dropoffs),
      "ada_only" => service.ada_only,
      "band_start" => service.band_start,
      "band_end" => service.band_end,
      "calendar_service_ids" => service.calendar_service_ids,
      "hub_stop_ids" => service.hub_stop_ids,
      "lock_version" => service.lock_version
    }
  end

  # Area names and keys only. The stored polygon is the server's own input to
  # `Export.plan/5` and the overlap checks; it is not part of the projection.
  defp area_view(%{area: area}) do
    %{
      "key" => area.key,
      "position" => area.position,
      "name" => area.name,
      "source" => area.source && Atom.to_string(area.source),
      "route_ids" => area.route_ids,
      "distance_m" => area.distance_m
    }
  end

  defp hours_view(row) do
    %{
      "area_key" => row.area_key,
      "service_id" => row.service_id,
      "start" => row.start,
      "end" => row.end
    }
  end

  defp rule_view(rule) do
    %{
      "service_id" => rule.service_id,
      "when" => rule.when && Atom.to_string(rule.when),
      "minutes" => rule.minutes,
      "days" => rule.days,
      "by" => rule.by,
      "business_days" => rule.business_days,
      "office_service_id" => rule.office_service_id,
      "max_days" => rule.max_days
    }
  end

  defp calendar_view(%{service_id: service_id} = row) do
    %{
      "service_id" => service_id,
      "weekly" => weekly_view(row.weekly),
      "exceptions" =>
        Enum.map(row.exceptions, fn exception ->
          %{
            "date" => Date.to_iso8601(exception.date),
            "exception_type" => exception.exception_type
          }
        end),
      "attributes" => attributes_view(row.attributes)
    }
  end

  defp weekly_view(nil), do: nil

  defp weekly_view(weekly) do
    %{
      "monday" => weekly.monday,
      "tuesday" => weekly.tuesday,
      "wednesday" => weekly.wednesday,
      "thursday" => weekly.thursday,
      "friday" => weekly.friday,
      "saturday" => weekly.saturday,
      "sunday" => weekly.sunday,
      "start_date" => Date.to_iso8601(weekly.start_date),
      "end_date" => Date.to_iso8601(weekly.end_date)
    }
  end

  defp attributes_view(nil), do: nil

  defp attributes_view(attributes) do
    %{
      "service_schedule_name" => attributes.service_schedule_name,
      "service_description" => attributes.service_description,
      "service_schedule_type" => attributes.service_schedule_type,
      "service_schedule_typicality" => attributes.service_schedule_typicality
    }
  end

  defp check_view(check) do
    %{
      "level" => Atom.to_string(check.level),
      "section" => Atom.to_string(check.section),
      "field" => Atom.to_string(check.field),
      "text" => check.text
    }
  end

  # --- evidence ---------------------------------------------------------------

  # The evidence is built from the same rows the view describes, so its counts
  # cannot disagree with what the model read, and its digest covers the exact
  # view that was returned (INV-2). Nothing here is invented: the source
  # revision is the saved service's own `lock_version`.
  defp evidence(workspace, %Scope{} = scope) do
    service = workspace.dependencies.service

    %{
      kind: "flex_policy_workspace",
      title: service.name || "Flex service",
      total: length(workspace.checks),
      total_label: "readiness checks",
      completeness: :complete,
      completeness_reason: nil,
      facts: evidence_facts(workspace.view),
      source_ref: @source_ref,
      digest: digest(workspace.view),
      source_revision: Integer.to_string(service.lock_version),
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: [
        "Area geometry, other services and the version's other records are not part of this workspace."
      ],
      resources: [%{kind: "flex_service", id: service.id, label: service.name}]
    }
  end

  # The server-computed counts beside the answer, in the panel's own shape.
  # These are also the bytes the projection bound measures with the view, so an
  # over-limit workspace is refused before any provider sees a plausible but
  # short answer.
  defp evidence_facts(view) do
    [
      %{label: "Hours rows", value: Integer.to_string(length(view["hours"]))},
      %{label: "Booking rules", value: Integer.to_string(length(view["booking_rules"]))},
      %{label: "Areas", value: Integer.to_string(length(view["areas"]))},
      %{label: "Calendars", value: Integer.to_string(length(view["calendars"]))},
      %{label: "Readiness errors", value: Integer.to_string(view["check_status"]["errors"])},
      %{label: "Readiness warnings", value: Integer.to_string(view["check_status"]["warnings"])}
    ]
  end

  defp digest(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp identity_label(%Scope{} = scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  # --- canonical dependency content -------------------------------------------

  # The service's complete ordered fields with its `lock_version`, so a change
  # to any stored field changes the fingerprint.
  defp service_snapshot(%FlexService{} = service) do
    service
    |> Map.from_struct()
    |> Map.drop([:areas, :__struct__, :__meta__])
    |> canonical()
  end

  # One area's stored row plus its geometry, so an area-only change is visible.
  defp area_snapshot(%FlexArea{} = area, geojson) do
    %{
      row: area |> Map.from_struct() |> Map.drop([:__struct__, :__meta__]) |> canonical(),
      geojson: canonical(Map.get(geojson, area.id))
    }
  end

  defp canonical(%DateTime{} = value), do: {:datetime, DateTime.to_iso8601(value)}
  defp canonical(%Date{} = value), do: {:date, Date.to_iso8601(value)}
  defp canonical(%Decimal{} = value), do: {:decimal, Decimal.to_string(value, :normal)}

  defp canonical(%_{} = value),
    do: value |> Map.from_struct() |> Map.drop([:__meta__]) |> canonical()

  defp canonical(nil), do: nil
  defp canonical(value) when is_atom(value), do: {:atom, Atom.to_string(value)}

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, entry} -> {to_string(key), canonical(entry)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_tuple(value), do: value |> Tuple.to_list() |> canonical()
  defp canonical(value), do: value
end
