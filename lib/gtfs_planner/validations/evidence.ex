defmodule GtfsPlanner.Validations.Evidence do
  @moduledoc """
  Bounded, digest-bound reads of one scoped completed validation report.

  `findings/2` resolves the run inside the scope's organization and version
  before any report JSON is read (`GtfsPlanner.Validations.fetch_scoped_run/3`),
  so a foreign, absent, malformed or wrong-version run is one `:unavailable`
  result and no other organization's report is ever deserialized (INV-1, AC-1).
  A membership that is no longer an active editor's stops the read before the
  query.

  Only a `completed` `mobility_data`/`mobility_data_flex` run whose engine is nil
  or `"mobility_data"` and whose result schema version is nil or 1 can be read.
  Still running, failed, another engine, another schema or a report without a
  recognizable `notices` shape is `:unavailable` rather than a guess.

  Three stored shapes are recognized, and none of them is rewritten:

    * the canonical groups step 2 writes, with `total_notices` and `notices`;
    * a historical wrapper group whose `notices` hold the upstream NoticeReport
      (`totalNotices`/`sampleNotices`). The embedded `totalNotices` is the true
      count and outranks the wrapper's own total or its length, and an embedded
      report without a count leaves the total unknown rather than inferring it
      from the retained samples;
    * a flat notice list, where each stored entry is one instance.

  A group keeps the stored total, the retained sample count and whether those
  samples are all of it. An unknown severity stays counted under its own key, so
  `totals_by_severity` and `total_instances` stay exact (AC-4).

  The `digest` is a SHA-256 over the canonical full source groups, the run's
  checked-input provenance and its scope. Paging and filtering are applied after
  it, so every page of one report carries the same digest. Cursors are opaque
  version-1 base64 JSON naming the digest, the filter, the group key and the
  instance offset. A cursor that is malformed, oversized, filtered differently or
  pointed outside the report is refused as `:invalid_arguments`; one whose digest
  no longer matches the stored report is `:stale`.

  Instance references are `digest/group/index` positions, never CSV row
  identities: the index is the position in the group's own sample order, so the
  same instance keeps the same reference on every page.

  Retained context is sanitized to the file's basename, its row numbers, its
  field name and the natural ids `stopId`, `routeId`, `tripId`, `serviceId` and
  `pathwayId`. Every other key of a sample is dropped and the dropped names are
  disclosed to the caller. A retained value longer than 128 bytes is refused as
  `:too_large` rather than silently shortened, and so is a result that cannot fit
  32 KiB; both ask the caller to narrow the page instead.
  """

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @run_types ["mobility_data", "mobility_data_flex"]
  @engines [nil, "mobility_data"]
  @schema_versions [nil, 1]
  @known_severities ["ERROR", "WARNING", "INFO"]

  @default_group_limit 20
  @max_group_limit 50
  @default_instance_limit 50
  @max_instance_limit 100
  @max_cursor_bytes 1024
  @cursor_version 1
  @max_result_bytes 32_768
  @max_value_bytes 128

  @row_keys ~w(csvRowNumber rowNumber)
  @id_keys ~w(stopId routeId tripId serviceId pathwayId)
  @allowed_context_keys ["filename" | @row_keys ++ ["fieldName"] ++ @id_keys]

  @typedoc "One bounded page of a scoped completed validation report."
  @type report :: %{
          digest: String.t(),
          groups: [group()],
          totals_by_severity: %{optional(String.t()) => non_neg_integer()},
          total_instances: non_neg_integer(),
          retained_instances: non_neg_integer(),
          completeness: String.t(),
          exclusions: [%{reason: String.t(), count: non_neg_integer()}],
          next_cursor: String.t() | nil
        }

  @typedoc "One code/severity group with the instances returned on this page."
  @type group :: %{
          key: String.t(),
          code: String.t(),
          severity: String.t(),
          total_instances: non_neg_integer() | nil,
          retained_instances: non_neg_integer(),
          instance_offset: non_neg_integer(),
          completeness: String.t(),
          instances: [instance()]
        }

  @typedoc "One retained sample, addressed by its stable position in the report."
  @type instance :: %{
          ref: String.t(),
          context: %{optional(String.t()) => String.t() | integer()},
          excluded_keys: [String.t()]
        }

  @doc """
  Returns one bounded page of a scoped completed validation report.

  `args` accepts `run_id` (required), `code`, `severity`, `limit`, `cursor` and
  `digest`. Without a `code` the page walks groups (limit 20, maximum 50); with
  one it walks that code's retained instances (limit 50, maximum 100). A
  continuation must present the `digest` the first page returned.
  """
  @spec findings(Scope.t(), map()) :: {:ok, report()} | {:error, atom()}
  def findings(%Scope{} = scope, args) when is_map(args) do
    with :ok <- authorize(scope),
         {:ok, request} <- parse_request(args),
         {:ok, run} <- fetch_run(scope, request),
         {:ok, source} <- read_source(run) do
      paginate(source, request)
    end
  end

  def findings(_scope, _args), do: {:error, :invalid_arguments}

  # A membership withdrawn mid-conversation is not a different answer, so a
  # refused membership and an unknown run are one indistinguishable result.
  defp authorize(%Scope{} = scope) do
    case Scope.authorize(scope) do
      :ok -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp fetch_run(%Scope{} = scope, request) do
    Validations.fetch_scoped_run(
      scope.organization_id,
      scope.gtfs_version_id,
      request.run_id
    )
  end

  # -- the stored report ------------------------------------------------------

  defp read_source(%ValidationRun{} = run) do
    with :ok <- supported_run(run),
         {:ok, groups} <- normalize(run.result_json) do
      {:ok, %{digest: digest(run, groups), groups: groups}}
    end
  end

  defp supported_run(%ValidationRun{} = run) do
    if run.run_type in @run_types and run.status == "completed" and
         run.engine in @engines and run.result_schema_version in @schema_versions do
      :ok
    else
      {:error, :unavailable}
    end
  end

  defp normalize(%{"notices" => notices}) when is_list(notices) do
    notices
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case stored_group(entry) do
        {:ok, group} -> {:cont, {:ok, [group | acc]}}
        {:error, _reason} -> {:halt, {:error, :unavailable}}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> merge_groups() |> index_instances()}
      {:error, _reason} = error -> error
    end
  end

  defp normalize(_result_json), do: {:error, :unavailable}

  # One stored group, whichever of the three shapes it was written in.
  defp stored_group(entry) when is_map(entry) do
    with {:ok, code} <- stored_code(entry),
         {:ok, severity} <- stored_severity(entry) do
      group_from(entry, code, severity)
    end
  end

  defp stored_group(_entry), do: {:error, :unavailable}

  defp group_from(entry, code, severity) do
    case Map.get(entry, "notices") do
      notices when is_list(notices) ->
        if wrapper?(notices) do
          embedded_group(notices, code, severity)
        else
          canonical_group(entry, notices, code, severity)
        end

      _other ->
        # The flat form stores one notice per entry, so the entry itself is the
        # only instance the report holds.
        build_group(code, severity, 1, [entry])
    end
  end

  # A wrapper holds the validator's own NoticeReport, which carries the true
  # count; the wrapper's own total and its length are its own bookkeeping.
  defp wrapper?([]), do: false

  defp wrapper?(notices) do
    Enum.all?(notices, fn notice ->
      is_map(notice) and
        (Map.has_key?(notice, "totalNotices") or Map.has_key?(notice, "sampleNotices"))
    end)
  end

  defp embedded_group(notices, code, severity) do
    Enum.reduce_while(notices, {:ok, {0, []}}, fn
      %{} = notice, {:ok, {total, samples}} ->
        found = embedded_samples(notice)

        if Enum.all?(found, &is_map/1) do
          {:cont, {:ok, {add_total(total, embedded_total(notice)), samples ++ found}}}
        else
          {:halt, {:error, :unavailable}}
        end

      _notice, {:error, _reason} = error ->
        {:halt, error}
    end)
    |> case do
      {:ok, {total, samples}} -> build_group(code, severity, total, samples)
      {:error, _reason} = error -> error
    end
  end

  defp canonical_group(entry, notices, code, severity) do
    if Enum.all?(notices, &is_map/1) do
      case stored_total(entry) do
        {:ok, total} -> build_group(code, severity, total, notices)
        {:error, :not_counted} -> build_group(code, severity, nil, notices)
      end
    else
      {:error, :unavailable}
    end
  end

  defp add_total(_acc, {:error, :not_counted}), do: nil
  defp add_total(nil, {:ok, total}), do: total
  defp add_total(acc, {:ok, total}), do: acc + total

  defp stored_total(%{"total_notices" => total}) when is_integer(total) and total >= 0,
    do: {:ok, total}

  defp stored_total(_entry), do: {:error, :not_counted}

  defp embedded_total(%{"totalNotices" => total}) when is_integer(total) and total >= 0,
    do: {:ok, total}

  defp embedded_total(_notice), do: {:error, :not_counted}

  defp embedded_samples(%{"sampleNotices" => samples}) when is_list(samples), do: samples
  defp embedded_samples(_notice), do: []

  defp stored_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp stored_code(_entry), do: {:error, :unavailable}

  defp stored_severity(%{"severity" => severity}) when is_binary(severity), do: {:ok, severity}
  defp stored_severity(_entry), do: {:error, :unavailable}

  # A retained count above its own stored total is an unreadable report, not a
  # clean one; neither number is adjusted to make it fit. An embedded report
  # without a count leaves the total unknown, because the samples never stand in
  # for the number they were cut from.
  defp build_group(code, severity, total, samples) when is_integer(total) do
    if total >= length(samples) do
      {:ok, counted_group(code, severity, total, samples)}
    else
      {:error, {:retained_exceeds_total, code, severity}}
    end
  end

  defp build_group(code, severity, nil, samples),
    do: {:ok, counted_group(code, severity, nil, samples)}

  defp counted_group(code, severity, total, samples) do
    %{
      key: group_key(code, severity),
      code: code,
      severity: severity,
      total: total,
      retained: length(samples),
      completeness: group_completeness(total, length(samples)),
      raw: samples
    }
  end

  defp group_completeness(nil, _retained), do: "unknown"
  defp group_completeness(total, retained) when retained == total, do: "complete"
  defp group_completeness(_total, _retained), do: "sampled"

  # Repeated groups of one code and severity describe one group: the totals add
  # and the samples keep their stored order, exactly as the parser left them.
  defp merge_groups(groups) do
    groups
    |> Enum.reduce(%{}, fn group, acc ->
      Map.update(acc, group.key, group, fn existing ->
        total = add_known(existing.total, group.total)
        retained = existing.retained + group.retained

        existing
        |> Map.put(:total, total)
        |> Map.put(:raw, existing.raw ++ group.raw)
        |> Map.put(:retained, retained)
        |> Map.put(:completeness, group_completeness(total, retained))
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.code, &1.severity})
  end

  defp add_known(nil, _total), do: nil
  defp add_known(_total, nil), do: nil
  defp add_known(left, right), do: left + right

  # The instance index is the position in the group's own sample order, so it is
  # the same reference on every page of the same report.
  defp index_instances(groups) do
    Enum.map(groups, fn group ->
      instances =
        group.raw
        |> Enum.with_index()
        |> Enum.map(fn {raw, index} ->
          %{ref: "#{group.key}/#{index}", raw: raw, index: index}
        end)

      Map.put(group, :instances, instances)
    end)
  end

  defp group_key(code, severity), do: "#{code}|#{severity}"

  # -- digest -----------------------------------------------------------------

  # The digest identifies the content and provenance this report was read from,
  # never a chronology or a revision. Paging and filtering are applied after it.
  defp digest(%ValidationRun{} = run, groups) do
    %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      run_id: run.id,
      run_type: run.run_type,
      checked_zip_sha256: run.checked_zip_sha256,
      checked_export_profile: run.checked_export_profile,
      validator_version: run.validator_version,
      groups: Enum.map(groups, &digest_group/1)
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp digest_group(group) do
    [group.code, group.severity, group.total, Enum.map(group.instances, & &1.raw)]
  end

  # -- paging -----------------------------------------------------------------

  defp paginate(%{digest: digest, groups: groups}, request) do
    selected = filter_groups(groups, request)

    with {:ok, position} <- start_position(selected, digest, request) do
      {page, rest} = take_page(selected, position, request)

      with {:ok, presented} <- present_page(page, digest) do
        bounded(build_report(groups, presented, digest, rest, request))
      end
    end
  end

  # Without a code filter the page walks groups; with one it walks that code's
  # retained instances, so a group of 170 findings returns its stored samples
  # rather than instances the validator never recorded.
  defp entries(selected, %{code: nil}), do: selected

  defp entries(selected, _request) do
    Enum.flat_map(selected, fn group -> Enum.map(group.instances, &{group, &1}) end)
  end

  defp start_position(selected, digest, request) do
    case request.cursor do
      nil -> first_position(selected, digest, request)
      cursor -> resume_position(selected, digest, request, cursor)
    end
  end

  # A presented digest that no longer matches the stored report is stale rather
  # than a silent restart at the beginning.
  defp first_position(_selected, digest, request) do
    case request.digest do
      nil -> {:ok, 0}
      ^digest -> {:ok, 0}
      _other -> {:error, :stale}
    end
  end

  # A continuation names the report it continues, so the caller must present
  # that digest and the same filter; a cursor from another report or another
  # filter cannot be applied to this one.
  defp resume_position(selected, digest, request, cursor) do
    cond do
      is_nil(request.digest) -> {:error, :invalid_arguments}
      request.digest != cursor.digest -> {:error, :invalid_arguments}
      cursor.filter != request.filter -> {:error, :invalid_arguments}
      cursor.digest != digest -> {:error, :stale}
      true -> cursor_position(selected, cursor, request)
    end
  end

  # The cursor names the group it resumes inside. In group mode that group is the
  # first group of the next page and no instance offset applies; in instance
  # mode the offset says how far into that group's own samples to start. An
  # offset past the retained samples is refused.
  defp cursor_position(selected, %{group: key, offset: offset}, request) do
    {preceding, found} = walk_groups(selected, key, 0)

    case found do
      nil ->
        {:error, :invalid_arguments}

      group ->
        position = if request.code, do: preceding + offset, else: preceding

        cond do
          request.code && offset > group.retained -> {:error, :invalid_arguments}
          is_nil(request.code) && offset != 0 -> {:error, :invalid_arguments}
          true -> {:ok, position}
        end
    end
  end

  defp walk_groups([], _key, preceding), do: {preceding, nil}

  defp walk_groups([group | rest], key, preceding) do
    if group.key == key do
      {preceding, group}
    else
      walk_groups(rest, key, preceding + group.retained)
    end
  end

  defp take_page(selected, position, request) do
    all = entries(selected, request)
    limit = request.limit

    {Enum.slice(all, position, limit), Enum.drop(all, position + limit)}
  end

  defp build_report(groups, presented, digest, rest, request) do
    totals = totals(groups)

    %{
      digest: digest,
      groups: presented,
      totals_by_severity: totals.totals_by_severity,
      total_instances: totals.total_instances,
      retained_instances: totals.retained_instances,
      completeness: completeness(groups),
      exclusions: exclusions(totals, rest, request),
      next_cursor: next_cursor(rest, digest, request)
    }
  end

  # Totals are exact for every group whose stored count could be read. A group
  # whose count is unknown is disclosed rather than counted as zero.
  defp totals(groups) do
    counted = Enum.filter(groups, &is_integer(&1.total))

    %{
      totals_by_severity: severity_totals(counted),
      total_instances: counted |> Enum.map(& &1.total) |> Enum.sum(),
      retained_instances: groups |> Enum.map(& &1.retained) |> Enum.sum(),
      sampled: Enum.count(counted, &(&1.completeness == "sampled")),
      unknown_total: length(groups) - length(counted),
      unknown_severity:
        Enum.count(counted, &(String.upcase(&1.severity) not in @known_severities))
    }
  end

  # A group is counted under the severity the validator gave it, so an unknown
  # severity stays visible and exact instead of being folded into another total.
  defp severity_totals(groups) do
    Enum.reduce(groups, %{}, fn group, acc ->
      Map.update(acc, group.severity, group.total, &(&1 + group.total))
    end)
  end

  # Completeness describes what the validator stored, not what this transport
  # page delivered: a sampled group or an unknown total is incomplete even when
  # every page has been read.
  defp completeness([]), do: "complete"

  defp completeness(groups) do
    if Enum.all?(groups, &(&1.completeness == "complete")), do: "complete", else: "incomplete"
  end

  defp exclusions(totals, rest, request) do
    []
    |> exclude("sampled_instance_groups", totals.sampled)
    |> exclude("groups_without_stored_total", totals.unknown_total)
    |> exclude("unknown_severity_groups", totals.unknown_severity)
    |> exclude(unread_reason(request), length(rest))
  end

  # A next cursor is the honest statement that more of the report exists, so the
  # unread remainder is disclosed by name rather than left to be guessed.
  defp unread_reason(%{code: nil}), do: "groups_not_on_this_page"
  defp unread_reason(_request), do: "instances_not_on_this_page"

  defp exclude(exclusions, _reason, count) when count <= 0, do: exclusions

  defp exclude(exclusions, reason, count),
    do: exclusions ++ [%{reason: reason, count: count}]

  # -- the page ---------------------------------------------------------------

  # In group mode each entry is a whole group; in instance mode it is one
  # retained sample, which is why a page carries at most one group per entry.
  defp present_page([], _digest), do: {:ok, []}

  defp present_page(entries, digest) do
    entries
    |> Enum.group_by(&entry_key/1)
    |> Enum.sort_by(fn {key, _values} -> key end)
    |> Enum.reduce_while({:ok, []}, fn {_key, values}, {:ok, acc} ->
      case present_group(values, digest) do
        {:ok, group} -> {:cont, {:ok, acc ++ [group]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp entry_key(group) when is_map(group), do: {group.code, group.severity}
  defp entry_key({group, _instance}), do: {group.code, group.severity}

  defp present_group([group], digest) when is_map(group) do
    with {:ok, instances} <- present_instances(group.instances, digest) do
      {:ok,
       %{
         key: group.key,
         code: group.code,
         severity: group.severity,
         total_instances: group.total,
         retained_instances: group.retained,
         instance_offset: 0,
         completeness: group.completeness,
         instances: instances
       }}
    end
  end

  defp present_group(entries, digest) do
    [{group, first} | rest] = entries

    with {:ok, instances} <- present_instances([first | Enum.map(rest, &elem(&1, 1))], digest) do
      {:ok,
       %{
         key: group.key,
         code: group.code,
         severity: group.severity,
         total_instances: group.total,
         retained_instances: group.retained,
         instance_offset: first.index,
         completeness: group.completeness,
         instances: instances
       }}
    end
  end

  defp present_instances([], _digest), do: {:ok, []}

  defp present_instances([instance | rest], digest) do
    with {:ok, context, excluded} <- sanitize(instance.raw),
         {:ok, presented} <- present_instances(rest, digest) do
      {:ok,
       [
         %{
           ref: "#{digest}/#{instance.ref}",
           context: context,
           excluded_keys: excluded
         }
         | presented
       ]}
    end
  end

  # The next cursor resumes at the first entry this page did not return, so it is
  # exactly the position after the page rather than a re-read of its last group.
  defp next_cursor([], _digest, _request), do: nil

  defp next_cursor([entry | _rest], digest, request) do
    fields =
      case entry do
        group when is_map(group) -> %{group: group.key, offset: 0}
        {group, instance} -> %{group: group.key, offset: instance.index}
      end

    encode_cursor(fields, digest, request.filter)
  end

  defp encode_cursor(fields, digest, filter) do
    payload = %{
      "v" => @cursor_version,
      "digest" => digest,
      "filter" => filter,
      "group" => fields.group,
      "offset" => fields.offset
    }

    payload |> Jason.encode!() |> Base.url_encode64()
  end

  # -- filters ----------------------------------------------------------------

  defp filter_groups(groups, request) do
    Enum.filter(groups, fn group ->
      matches_code?(group.code, request.code) and
        matches_severity?(group.severity, request.severity)
    end)
  end

  defp matches_code?(_code, nil), do: true
  defp matches_code?(code, code), do: true
  defp matches_code?(_code, _wanted), do: false

  # ERROR/WARNING/INFO match in either case. Any other value is compared
  # exactly, so an unknown severity is filterable without being remapped.
  defp matches_severity?(_severity, nil), do: true

  defp matches_severity?(severity, wanted) do
    upcased = String.upcase(wanted)

    if upcased in @known_severities do
      String.upcase(severity) == upcased
    else
      severity == wanted
    end
  end

  # -- sanitization -----------------------------------------------------------

  # Only the file's basename, its rows, its field and the named natural ids
  # leave this module. Everything else a sample carries - messages, internal
  # context, host paths - is dropped, and the dropped names are disclosed.
  defp sanitize(raw) when is_map(raw) do
    {kept, oversized} =
      Enum.reduce(@allowed_context_keys, {%{}, nil}, fn key, {kept, oversized} ->
        case sanitize_value(key, Map.get(raw, key)) do
          {:ok, value} -> {Map.put(kept, key, value), oversized}
          {:error, :too_large} -> {kept, key}
          :omit -> {kept, oversized}
        end
      end)

    case oversized do
      nil -> {:ok, kept, unknown_keys(raw)}
      _key -> {:error, :too_large}
    end
  end

  defp sanitize(_raw), do: {:error, :too_large}

  defp sanitize_value("filename", value) when is_binary(value),
    do: bounded_value(Path.basename(value))

  defp sanitize_value(key, value) when key in @row_keys and is_integer(value), do: {:ok, value}

  defp sanitize_value(key, value) when key in ["fieldName" | @id_keys] and is_binary(value),
    do: bounded_value(value)

  defp sanitize_value(_key, _value), do: :omit

  # A retained value longer than the bound is refused rather than shortened: a
  # truncated identifier is not the identifier the validator reported.
  defp bounded_value(value) do
    if byte_size(value) > @max_value_bytes, do: {:error, :too_large}, else: {:ok, value}
  end

  defp unknown_keys(raw) do
    raw |> Map.keys() |> Enum.reject(&(&1 in @allowed_context_keys)) |> Enum.sort()
  end

  # -- arguments --------------------------------------------------------------

  defp parse_request(args) do
    with {:ok, run_id} <- required_string(args, :run_id),
         {:ok, code} <- optional_string(args, :code),
         {:ok, severity} <- optional_string(args, :severity),
         {:ok, limit} <- optional_limit(args, code),
         {:ok, digest} <- optional_string(args, :digest),
         {:ok, cursor} <- decode_cursor(args) do
      {:ok,
       %{
         run_id: run_id,
         code: code,
         severity: severity,
         limit: limit,
         digest: digest,
         cursor: cursor,
         filter: %{"code" => code, "severity" => severity}
       }}
    end
  end

  defp required_string(args, key) do
    case string_arg(args, key) do
      {:ok, value} -> {:ok, value}
      :omit -> {:error, :invalid_arguments}
    end
  end

  defp optional_string(args, key) do
    case string_arg(args, key) do
      {:ok, value} -> {:ok, value}
      :omit -> {:ok, nil}
    end
  end

  defp string_arg(args, key) do
    case Map.get(args, key) || Map.get(args, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> :omit
      _other -> {:error, :invalid_arguments}
    end
  end

  defp optional_limit(args, code) do
    case Map.get(args, :limit) || Map.get(args, "limit") do
      nil ->
        {:ok, default_limit(code)}

      limit when is_integer(limit) and limit > 0 ->
        if limit <= max_limit(code), do: {:ok, limit}, else: {:error, :invalid_arguments}

      _other ->
        {:error, :invalid_arguments}
    end
  end

  defp default_limit(nil), do: @default_group_limit
  defp default_limit(_code), do: @default_instance_limit

  defp max_limit(nil), do: @max_group_limit
  defp max_limit(_code), do: @max_instance_limit

  defp decode_cursor(args) do
    case Map.get(args, :cursor) || Map.get(args, "cursor") do
      nil -> {:ok, nil}
      cursor when is_binary(cursor) -> parse_cursor(cursor)
      _other -> {:error, :invalid_arguments}
    end
  end

  defp parse_cursor(cursor) when byte_size(cursor) > @max_cursor_bytes,
    do: {:error, :invalid_arguments}

  defp parse_cursor(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, payload} <- Jason.decode(json),
         {:ok, decoded} <- cursor_payload(payload) do
      {:ok, decoded}
    else
      _other -> {:error, :invalid_arguments}
    end
  end

  defp cursor_payload(%{
         "v" => @cursor_version,
         "digest" => digest,
         "filter" => %{"code" => code, "severity" => severity},
         "group" => group,
         "offset" => offset
       })
       when is_binary(digest) and is_binary(group) and is_integer(offset) and offset >= 0 and
              (is_nil(code) or is_binary(code)) and (is_nil(severity) or is_binary(severity)) do
    {:ok,
     %{
       digest: digest,
       filter: %{"code" => code, "severity" => severity},
       group: group,
       offset: offset
     }}
  end

  defp cursor_payload(_payload), do: {:error, :invalid_arguments}

  # -- bounds -----------------------------------------------------------------

  defp bounded(report) do
    case Jason.encode(report) do
      {:ok, json} ->
        if byte_size(json) > @max_result_bytes, do: {:error, :too_large}, else: {:ok, report}

      {:error, _reason} ->
        {:error, :too_large}
    end
  end
end
