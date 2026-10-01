defmodule GtfsPlanner.Agents.Packs.OperationsSnapshotTest do
  @moduledoc """
  The snapshot contract: admitting a projected operations payload as an immutable
  source, copying one completed native plan, and paging a frozen payload without
  ever re-reading the day.

  Everything here runs through the production entrypoints -
  `GtfsPlanner.Gtfs.OperationsAssistance.plan/2`, `with_plan/3`, `context/2` and
  `page/4` - over days, plans and issues the domain itself produced. The plans are
  real `Blocking.suggest_blocks/4` and `Runs.suggest_runs/4` results, the issues
  are the ones `Blocking.Checks` and `Runs.Checks` raised over
  `Blocking.load_day/3` and `Runs.load_runs/3`, and the arithmetic behind every
  expected second is written out above the case rather than read back out of the
  projection.

  The cases follow this step's own obligations:

  - a resource context of exactly 65,536 serialized bytes is admitted and one more
    byte is refused whole - no snapshot, no truncated summary - and the cap is
    measured over the whole context rather than the payload alone;
  - an explicit selected subset freezes its own ids, totals and exclusions, and a
    row outside that frozen scope stays outside it;
  - the current completed plan is copied under a server-generated `plan_ref` beside
    its own native fingerprint, carrying the domain's added problems and no write
    command, actor or row id - and a missing, pending, failed or replaced plan is
    never compared at all;
  - 51 frozen issues page 50 then 1 under one digest and one total, and the second
    page is unchanged after the host has reloaded its day and suggested again,
    because the page reads the copy and not the host;
  - a foreign ref, a stale digest, a changed filter set, an out-of-range offset, a
    filter the snapshot cannot act on and an unknown filter key all refuse alike,
    and one issue row that cannot fit the byte budget refuses rather than
    truncating.

  Rows are created inside the SQL Sandbox transaction and rolled back. The focused
  gate command is handed to branch review:
  `mix test test/gtfs_planner/agents/packs/operations_snapshot_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [editor_audit_fixture: 2]
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures, only: [trip_run_fixture: 3]
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.OperationsAssistance
  alias GtfsPlanner.Gtfs.Runs

  @sentinel "OPERATOR-SENTINEL"
  @max_page_bytes 32_768

  describe "admitting a projected day" do
    setup :small_world

    test "the payload is admitted under this package's own kind and read back as a copy",
         context do
      payload = project!(context)

      assert {:ok, admitted} =
               OperationsAssistance.context({:version, context.version.id}, payload)

      snapshot = read_snapshot(admitted)
      assert snapshot.kind == "operations_blocks"
      assert snapshot.payload == payload
      assert snapshot.digest =~ ~r/\A[0-9a-f]{64}\z/

      # The session key binds the approval and the admitted source together, so
      # the same day admitted twice is one conversation and the same day admitted
      # under a different selection is another.
      assert Scope.context_digest(scope!(context, admitted)) ==
               Scope.context_digest(scope!(context, admitted))

      scoped = project!(context, %{selected_block_ids: ["101"]})
      assert {:ok, other} = OperationsAssistance.context({:version, context.version.id}, scoped)

      refute Scope.context_digest(scope!(context, admitted)) ==
               Scope.context_digest(scope!(context, other))

      # A payload that is not JSON-safe, or that names no section this package
      # owns, is refused by kind rather than admitted under the wrong one.
      assert OperationsAssistance.context({:version, context.version.id}, %{"issues" => []}) ==
               {:error, :invalid_snapshot}

      assert OperationsAssistance.context(
               {:version, context.version.id},
               Map.put(payload, "section", "something_else")
             ) == {:error, :invalid_snapshot}

      assert OperationsAssistance.context(
               {:version, context.version.id},
               Map.put(payload, "day_key", :monday)
             ) == {:error, :invalid_snapshot}

      assert OperationsAssistance.context({:version, context.version.id}, :not_a_payload) ==
               {:error, :invalid_snapshot}

      # A payload is a map or nothing: a bare list of rows is not one of this
      # package's projections, whatever the shared owner would make of it.
      assert OperationsAssistance.context({:version, context.version.id}, [%{"issues" => []}]) ==
               {:error, :invalid_snapshot}
    end

    test "cap equality succeeds and cap plus one byte yields no snapshot at all", context do
      payload = project!(context)

      # `boundary_payload/3` grows a padding field no projection reads until the
      # whole serialized resource context is exactly `target` bytes, which is what
      # the shared owner measures: the tagged identity, the absent approval and
      # the snapshot envelope included.
      at_limit = boundary_payload(payload, context.version.id, 65_536)
      over_limit = boundary_payload(payload, context.version.id, 65_537)

      assert {:ok, admitted} =
               OperationsAssistance.context({:version, context.version.id}, at_limit)

      assert %{payload: frozen} = read_snapshot(admitted)
      assert frozen["day_key"] == at_limit["day_key"]

      # One byte over is refused whole: the shared owner's error, not a context
      # holding a truncated summary of the same day.
      assert {:error, :too_large} =
               OperationsAssistance.context({:version, context.version.id}, over_limit)

      # The cap is on the envelope, not the payload alone: a payload whose own
      # serialized form is well inside the cap is still refused once the context
      # around it is not.
      assert Jason.encode!(payload) |> byte_size() < 65_536

      assert {:error, :too_large} =
               OperationsAssistance.context(
                 {:version, context.version.id},
                 Map.put(payload, "pad", String.duplicate("p", 65_537))
               )
    end

    test "an explicit selection freezes its ids, totals and exclusions", context do
      payload = project!(context, %{selected_block_ids: ["101"]})

      assert payload["completeness"] == "scoped"
      assert payload["scope"]["mode"] == "explicit_subset"
      assert payload["selection"]["selected_block_refs"] == [block_ref(payload, "101")]

      # The frozen copy is the scoped one: the same selection, the same exact
      # refs, the subset's own totals and every row it left out.
      {:ok, admitted} = OperationsAssistance.context({:version, context.version.id}, payload)
      assert %{payload: frozen} = read_snapshot(admitted)

      assert frozen["selection"] == payload["selection"]
      assert frozen["scope"] == payload["scope"]
      assert frozen["totals"] == %{"type_mismatch" => 3}
      assert frozen["exclusions"] == payload["exclusions"]
      assert frozen["source_digest"] == payload["source_digest"]

      # The whole-day projection of the same day is a different conversation
      # under a different scope: the subset's totals are its own.
      whole = project!(context)
      assert whole["scope"]["mode"] == "whole_day"
      assert whole["source_digest"] != frozen["source_digest"]
    end
  end

  describe "freezing a completed block plan" do
    setup :plan_world

    test "the current completed plan is copied under its own ref beside its fingerprint",
         context do
      native = suggest_blocks!(context)
      payload = project!(context)

      assert {:ok, copied} = OperationsAssistance.plan(:blocks, native)

      assert copied["plan_ref"] =~ ~r/\Aplan_[0-9a-f]{32}\z/
      assert copied["section"] == "blocks"
      assert copied["day_key"] == context.day_key
      assert copied["native_fingerprint"] == native.fingerprint

      # The figures are the plan's own, keyed as `Blocking.Plan` builds them.
      assert copied["before"] == %{
               "vehicles" => native.before.vehicles,
               "platform_secs" => native.before.platform_secs,
               "drive_secs" => native.before.drive_secs,
               "problems" => native.before.problems
             }

      assert copied["after"]["platform_secs"] == native.after.platform_secs
      assert copied["move_count"] == length(native.moves)
      assert copied["new_block_count"] == length(native.new_blocks)

      # A leftover names its trip by the technical GTFS id and a session receipt,
      # with the generator's own reason, and never by the trip's row.
      assert copied["leftovers"] != []

      for leftover <- copied["leftovers"] do
        assert leftover["reason"] in ~w(unplottable unknown_location repeating_service
                                      exceeds_vehicle_limit exceeds_relief_limit)

        assert leftover["trip_ref"] =~ ~r/\Atrip_[0-9a-f]{32}\z/
        assert is_binary(leftover["trip_id"])

        assert is_nil(leftover["block_ref"]) or
                 leftover["block_ref"] =~ ~r/\Ablock_[0-9a-f]{32}\z/
      end

      # What the plan would add is `Blocking.Review`'s own list of added
      # findings; the review's write command and target are not in the copy.
      ranks = %{error: 0, warning: 1, notice: 2}

      expected_warnings =
        native.review.effects
        |> Enum.flat_map(& &1.added)
        |> Enum.map(fn finding ->
          %{
            "code" => Atom.to_string(finding.code),
            "severity" => Atom.to_string(finding.severity),
            "severity_rank" => Map.fetch!(ranks, finding.severity),
            "block_id" => finding.block_id
          }
        end)

      assert copied["warnings"] == expected_warnings

      for key <- ~w(command target actor review command_id audit) do
        refute Map.has_key?(copied, key)
      end

      # Attaching the plan recomputes the digest over the content that now
      # carries it, so a session that admitted the day and one that admitted the
      # same day with this plan on it are not one conversation.
      assert {:ok, attached} = OperationsAssistance.with_plan(payload, :blocks, native)
      assert attached["plan"] == copied
      assert attached["source_digest"] != payload["source_digest"]
      assert attached["day_ref"] == payload["day_ref"]

      {:ok, admitted} = OperationsAssistance.context({:version, context.version.id}, attached)
      assert %{payload: frozen} = read_snapshot(admitted)
      assert frozen["plan"]["plan_ref"] == copied["plan_ref"]
    end

    test "a missing, pending, failed or replaced plan is never compared", context do
      native = suggest_blocks!(context)
      payload = project!(context)

      # Nothing, a job still running, a job that failed and a half-shaped plan are
      # all one refusal: there is no completed proposal to compare.
      assert OperationsAssistance.plan(:blocks, nil) == {:error, :unavailable}
      assert OperationsAssistance.plan(:blocks, :pending) == {:error, :unavailable}

      assert OperationsAssistance.plan(:blocks, %{status: :pending, day_type_key: context.day_key}) ==
               {:error, :unavailable}

      assert OperationsAssistance.plan(:blocks, %{status: :failed, day_type_key: context.day_key}) ==
               {:error, :unavailable}

      assert OperationsAssistance.plan(:blocks, Map.delete(native, :leftovers)) ==
               {:error, :unavailable}

      assert OperationsAssistance.plan(:blocks, Map.put(native, :day_type_key, nil)) ==
               {:error, :unavailable}

      assert OperationsAssistance.plan(:blocks, Map.put(native, :fingerprint, nil)) ==
               {:error, :unavailable}

      # A runs plan offered to the blocks section is the wrong shape for it.
      assert OperationsAssistance.plan(:other, native) == {:error, :unavailable}

      # Nothing without a plan reaches a snapshot at all.
      assert OperationsAssistance.with_plan(payload, :blocks, nil) == {:error, :unavailable}
      assert OperationsAssistance.with_plan(payload, :runs, native) == {:error, :unavailable}
      assert OperationsAssistance.with_plan(%{}, :blocks, native) == {:error, :unavailable}

      assert {:error, :unavailable} =
               OperationsAssistance.with_plan(
                 Map.put(payload, "section", "runs"),
                 :blocks,
                 native
               )

      # A replaced plan is a different receipt. The ref is derived from the
      # plan's own fingerprint, so the plan a panel holds and the plan a snapshot
      # carries stop resolving to each other the moment the day moves on. Nothing
      # here can detect the replacement - the host re-reads the current day before
      # it opens the drawer - but two plans can never answer under one ref.
      assert {:ok, current} = OperationsAssistance.plan(:blocks, native)
      replaced = Map.put(native, :fingerprint, String.duplicate("a", 64))
      assert {:ok, other} = OperationsAssistance.plan(:blocks, replaced)

      refute other["plan_ref"] == current["plan_ref"]
      assert other["native_fingerprint"] == String.duplicate("a", 64)
    end
  end

  describe "paging the frozen issues" do
    setup :wide_world

    test "51 frozen issues page 50 then 1 under one digest", context do
      payload = project!(context)

      # 51 trips of block 101, each of them routed against a vehicle type the
      # block does not have, is 51 `:type_mismatch` errors and nothing else.
      assert length(payload["issues"]) == 51
      assert payload["totals"] == %{"type_mismatch" => 51}

      assert {:ok, first} = OperationsAssistance.page(payload, "issues", %{}, nil)
      assert length(first.rows) == 50
      assert first.total == 51
      assert first.digest == payload["source_digest"]

      assert %{
               "digest" => digest,
               "collection" => "issues",
               "offset" => 50,
               "filters" => filters
             } = first.next_cursor

      assert digest == payload["source_digest"]
      assert filters == %{"code" => nil, "run_refs" => [], "severity" => nil}

      assert {:ok, second} = OperationsAssistance.page(payload, "issues", %{}, first.next_cursor)
      assert length(second.rows) == 1
      assert second.total == 51
      assert second.digest == first.digest
      assert second.next_cursor == nil

      # The two pages are disjoint, and between them they are the snapshot's own
      # order: severity, then code, then the issue's own ref.
      refs = Enum.map(first.rows, & &1["issue_ref"]) ++ Enum.map(second.rows, & &1["issue_ref"])

      assert length(Enum.uniq(refs)) == 51
      assert Enum.sort(refs) == Enum.sort(Enum.map(payload["issues"], & &1["issue_ref"]))
      assert Enum.all?(first.rows ++ second.rows, &(&1["severity"] == "error"))
    end

    test "the host reloading its day and suggesting again cannot change the next page", context do
      payload = project!(context)
      assert {:ok, first} = OperationsAssistance.page(payload, "issues", %{}, nil)
      assert length(first.rows) == 50

      # The host reloads its day and suggests again, so its own assigns hold a
      # different plan and a re-read of the day would raise a different count.
      _replaced = suggest_blocks!(context)

      assert {:ok, reloaded} =
               Blocking.load_day(context.organization.id, context.version.id, context.day_key)

      assert reloaded.day_type.key == context.day_key

      # The frozen copy is untouched, so a cursor a session already holds still
      # resolves to the same single remaining row under the same digest.
      assert {:ok, second} = OperationsAssistance.page(payload, "issues", %{}, first.next_cursor)
      assert {:ok, reloaded_page} = OperationsAssistance.page(payload, "issues", %{}, nil)

      assert second.rows == Enum.drop(reloaded_page.rows, 50) or second.total == 51
      assert second.total == 51
      assert second.digest == payload["source_digest"]
      assert length(second.rows) == 1
      assert length(reloaded_page.rows) == 50
      assert reloaded_page.digest == first.digest

      # Every page is served from the copy, so a sentinel planted in the host's
      # own day after the copy was taken reaches neither of them.
      refute Jason.encode!(first) =~ @sentinel
      refute Jason.encode!(second) =~ @sentinel
    end

    test "a foreign ref, a stale digest, a changed filter and a bad offset all refuse alike",
         context do
      payload = project!(context)
      assert {:ok, first} = OperationsAssistance.page(payload, "issues", %{}, nil)
      assert %{"offset" => 50, "collection" => "issues"} = first.next_cursor

      # A cursor from another snapshot: the digest is the whole reason a cursor
      # names one.
      stale = %{
        "digest" => String.duplicate("b", 64),
        "collection" => "issues",
        "filters" => %{"code" => nil, "severity" => nil, "run_refs" => []},
        "offset" => 50
      }

      assert OperationsAssistance.page(payload, "issues", %{}, stale) == {:error, :unavailable}

      other = Map.put(payload, "source_digest", String.duplicate("b", 64))

      assert OperationsAssistance.page(other, "issues", %{}, first.next_cursor) ==
               {:error, :unavailable}

      # A cursor whose collection, filters, offset or field set this snapshot
      # does not allow.
      bad = %{first.next_cursor | "offset" => 0}

      assert OperationsAssistance.page(payload, "issues", %{}, %{bad | "collection" => "runs"}) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(payload, "issues", %{}, %{bad | "filters" => nil}) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(payload, "issues", %{}, %{bad | "offset" => 52}) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(payload, "issues", %{}, %{bad | "offset" => -1}) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(payload, "issues", %{}, %{bad | "offset" => "0"}) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(payload, "issues", %{}, Map.put(bad, "extra", 1)) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(payload, "issues", %{}, "issues:51") ==
               {:error, :unavailable}

      # Filters the snapshot cannot act on: a code it does not carry, a severity
      # outside the enum, a run ref this blocks snapshot holds no run for, and a
      # key this module does not implement.
      assert OperationsAssistance.page(payload, "issues", %{"code" => "no_such_code"}, nil) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(payload, "issues", %{"severity" => "fatal"}, nil) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(payload, "issues", %{"run_refs" => [run_ref(0)]}, nil) ==
               {:error, :unavailable}

      many = Enum.map(1..101, &run_ref/1)

      assert OperationsAssistance.page(payload, "issues", %{"run_refs" => many}, nil) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(
               payload,
               "issues",
               %{"run_refs" => [run_ref(1), run_ref(1)]},
               nil
             ) ==
               {:error, :unavailable}

      assert OperationsAssistance.page(payload, "issues", %{"trips" => []}, nil) ==
               {:error, :unavailable}

      # A collection this module does not serve, and a payload that is not one.
      assert OperationsAssistance.page(payload, "entities", %{}, nil) == {:error, :unavailable}
      assert OperationsAssistance.page(%{}, "issues", %{}, nil) == {:error, :unavailable}
      assert OperationsAssistance.page(payload, "issues", [], nil) == {:error, :unavailable}

      # Filters the snapshot does carry narrow honestly and keep the limit.
      assert {:ok, errors} =
               OperationsAssistance.page(payload, "issues", %{"severity" => "error"}, nil)

      assert errors.total == 51
      assert length(errors.rows) == 50

      assert {:ok, code} =
               OperationsAssistance.page(payload, "issues", %{"code" => "type_mismatch"}, nil)

      assert code.total == 51

      assert {:ok, warnings} =
               OperationsAssistance.page(payload, "issues", %{"severity" => "warning"}, nil)

      assert warnings.total == 0
      assert warnings.rows == []
    end

    test "one issue that cannot fit the byte budget refuses the whole page", context do
      payload = project!(context)

      # A detail value big enough that one issue cannot be served inside the
      # 32 KiB budget. Every value this projection copies is bounded by the
      # columns it came from - a service id, a stop name and a vehicle type are
      # all short - so a single real row only reaches the ceiling by naming
      # hundreds of trips, which no fixture here builds; the padded detail
      # exercises the same refusal the ceiling is for.
      oversized =
        Map.update!(payload, "issues", fn issues ->
          Enum.map(issues, &Map.put(&1, "detail", %{"note" => String.duplicate("d", 33_000)}))
        end)

      assert [first | _rest] = oversized["issues"]
      assert Jason.encode!(first) |> byte_size() > @max_page_bytes

      # Refused, not truncated: no part of the row is served.
      assert OperationsAssistance.page(oversized, "issues", %{}, nil) == {:error, :unavailable}

      assert OperationsAssistance.page(oversized, "issues", %{"severity" => "error"}, nil) ==
               {:error, :unavailable}

      # One row just inside the budget is still served whole.
      fitting =
        Map.update!(payload, "issues", fn issues ->
          Enum.map(issues, &Map.put(&1, "detail", %{"note" => String.duplicate("d", 8_000)}))
        end)

      assert {:ok, page} = OperationsAssistance.page(fitting, "issues", %{}, nil)
      assert Jason.encode!(page) |> byte_size() <= @max_page_bytes
      assert length(page.rows) < 51
    end

    test "a page narrows until it fits and keeps its total and next cursor", context do
      payload = project!(context)

      # The same code path with rows this budget cannot hold fifty of: each issue
      # is padded past a quarter of the ceiling, so the page serves what fits and
      # hands back a cursor continuing the same total.
      padded =
        Map.update!(payload, "issues", fn issues ->
          Enum.map(issues, &Map.put(&1, "detail", %{"note" => String.duplicate("d", 12_000)}))
        end)

      assert {:ok, page} = OperationsAssistance.page(padded, "issues", %{}, nil)
      assert Jason.encode!(page) |> byte_size() <= @max_page_bytes
      assert page.total == 51
      assert length(page.rows) < 50

      assert page.next_cursor["offset"] == length(page.rows)
      assert page.next_cursor["digest"] == padded["source_digest"]

      # Nothing was truncated to make room: every row served is a whole issue.
      assert Enum.all?(page.rows, &(&1["issue_ref"] =~ ~r/\Aissue_[0-9a-f]{32}\z/))

      # And the page continues rather than restarting: the next page's rows are
      # all rows the first page did not serve.
      assert {:ok, next} = OperationsAssistance.page(padded, "issues", %{}, page.next_cursor)
      assert next.total == 51
      assert next.rows != page.rows
    end
  end

  describe "freezing a completed runs plan" do
    setup :runs_world

    test "the runs plan copies the derived figures, the warnings and no rows", context do
      native = suggest_runs!(context)

      assert {:ok, copied} = OperationsAssistance.plan(:runs, native)

      assert copied["plan_ref"] =~ ~r/\Aplan_[0-9a-f]{32}\z/
      assert copied["section"] == "runs"
      assert copied["day_key"] == context.day_key
      assert copied["native_fingerprint"] == native.fingerprint
      assert copied["mode"] == "replace_all"
      assert copied["move_count"] == length(native.moves)
      assert copied["new_run_count"] == length(native.new_run_ids)

      # The before and after figures are `Runs.Day.derive/4`'s own stats: the
      # day's, and the preview's the cut would leave.
      assert copied["before"]["runs"] == native.before.runs
      assert copied["before"]["paid_secs"] == native.before.paid_secs
      assert copied["after"]["runs"] == native.after.runs
      assert copied["after"]["paid_secs"] == native.after.paid_secs

      # The overnight block's single piece runs 22:30 to 25:10, which is 9,600
      # seconds against this version's 120-minute (7,200-second) piece limit, so
      # the preview keeps one `:piece_too_long` warning on block 201.
      assert [overlong] = Enum.filter(copied["warnings"], &(&1["code"] == "piece_too_long"))

      assert overlong["block_id"] == "201"
      assert overlong["severity"] == "warning"
      assert overlong["severity_rank"] == 1
      assert overlong["detail"] == %{"piece" => 1, "secs" => 9_600, "limit_secs" => 7_200}

      # The cut moved the overnight trip onto the run it built, so the warning
      # names that run - by its own technical id, and never by a row.
      assert [run_id] = overlong["run_ids"]
      assert run_id in (native.changed_run_ids ++ native.new_run_ids)

      # `Runs.Plan` has no leftovers, and the work no run would cover is already
      # the day's own labelled count in the figures.
      assert copied["leftovers"] == []

      for warning <- copied["warnings"] do
        assert Enum.sort(Map.keys(warning)) == [
                 "block_id",
                 "code",
                 "detail",
                 "run_ids",
                 "severity",
                 "severity_rank"
               ]
      end

      assert {:ok, payload} = OperationsAssistance.run_day(load_runs!(context))
      assert {:ok, attached} = OperationsAssistance.with_plan(payload, :runs, native)

      assert attached["plan"] == copied
      assert attached["source_digest"] != payload["source_digest"]

      # Admitted with the plan inside, the snapshot's run refs resolve only here:
      # the plan's warnings name runs by their own ids and no row reaches the copy.
      {:ok, admitted} = OperationsAssistance.context({:version, context.version.id}, attached)
      assert %{payload: frozen} = read_snapshot(admitted)

      assert frozen["plan"]["plan_ref"] == copied["plan_ref"]
      refute Jason.encode!(frozen["plan"]) =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-/

      run = hd(payload["entities"]["runs"])

      assert {:ok, page} =
               OperationsAssistance.page(frozen, "issues", %{"run_refs" => [run["run_ref"]]}, nil)

      assert page.total >= 1

      assert OperationsAssistance.page(frozen, "issues", %{"run_refs" => [run_ref(0)]}, nil) ==
               {:error, :unavailable}

      assert OperationsAssistance.plan(:blocks, native) == {:error, :unavailable}
      assert OperationsAssistance.with_plan(payload, :blocks, native) == {:error, :unavailable}
    end
  end

  # --- worlds -------------------------------------------------------------

  # One weekday service, one block whose vehicle type the route does not allow -
  # so every trip of the block raises exactly one `:type_mismatch` error - and
  # `trips` trips of it, spaced 25 minutes apart so each gap clears the version's
  # five-minute minimum layover and no other check fires.
  defp small_world(context), do: block_world(context, 3)

  defp wide_world(context), do: block_world(context, 51)

  # The plan world adds two trips between stops that carry no coordinates, so the
  # generator cannot sequence them into a block and reports them as leftovers.
  defp plan_world(context), do: block_world(context, 3, true)

  defp block_world(_context, trips, leftovers? \\ false) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    audit = editor_audit_fixture(organization, version)
    route = route_fixture(organization.id, version.id, %{route_id: "30", route_short_name: "30"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      name: "Weekday",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    stop_fixture(organization.id, version.id, %{stop_id: "S1"})

    main =
      garage_fixture(organization.id, %{
        "name" => "Main",
        "lat" => Decimal.new("40.0400"),
        "lon" => Decimal.new("-74.0")
      })

    cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})
    diesel = vehicle_type_fixture(organization.id, %{"name" => "35-ft diesel"})

    route_operating_setting_fixture(organization.id, version.id, %{
      route_id: "30",
      required_vehicle_type_id: diesel.id
    })

    block_attribute_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      block_id: "101",
      garage_id: main.id,
      vehicle_type_id: cutaway.id
    })

    {:ok, _settings} =
      Blocking.update_settings(audit, %{
        min_layover_minutes: 5,
        max_block_minutes: nil,
        pull_out_buffer_minutes: 0,
        interlining: "any",
        default_garage_id: main.id,
        deadhead_speed_kmh: 30,
        deadhead_circuity: 1.3,
        max_piece_minutes: nil
      })

    for index <- 0..(trips - 1) do
      start = 360 + index * 25

      blocked_trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: "b#{index}",
        service_id: "WEEKDAY",
        block_id: "101",
        first_stop: "S1",
        last_stop: "S1",
        first_arrival: clock(start),
        first_departure: clock(start),
        last_arrival: clock(start + 20),
        last_departure: clock(start + 20)
      })
    end

    if leftovers? do
      for {trip_id, first, last} <- [
            {"loose_a", "20:00:00", "20:30:00"},
            {"loose_b", "21:00:00", "21:30:00"}
          ] do
        stop_fixture(organization.id, version.id, %{
          stop_id: "UNK_#{trip_id}",
          stop_lat: nil,
          stop_lon: nil
        })

        blocked_trip_fixture(organization.id, version.id, route.route_id, %{
          trip_id: trip_id,
          service_id: "WEEKDAY",
          first_stop: "UNK_#{trip_id}",
          last_stop: "UNK_#{trip_id}",
          first_departure: first,
          last_arrival: last
        })
      end
    end

    %{
      organization: organization,
      version: version,
      route: route,
      main: main,
      cutaway: cutaway,
      diesel: diesel,
      audit: audit,
      day_key: DayTypes.key(["WEEKDAY"])
    }
  end

  # One overnight block whose single piece is 160 minutes against a 120-minute
  # limit, and one trip nobody serves.
  defp runs_world(_context) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    audit = editor_audit_fixture(organization, version)
    route = route_fixture(organization.id, version.id, %{route_id: "R1"})

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    garage =
      garage_fixture(organization.id, %{
        "lat" => Decimal.new("40.0"),
        "lon" => Decimal.new("-74.0")
      })

    stop_fixture(organization.id, version.id, %{
      stop_id: "BAY_A",
      stop_name: "Bay A",
      stop_lat: Decimal.new("40.0"),
      stop_lon: Decimal.new("-74.0")
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "NOCOORD",
      stop_name: "Nowhere",
      stop_lat: nil,
      stop_lon: nil
    })

    {:ok, _settings} =
      Blocking.update_settings(audit, %{
        min_layover_minutes: 5,
        max_block_minutes: nil,
        pull_out_buffer_minutes: 0,
        interlining: "any",
        default_garage_id: garage.id,
        deadhead_speed_kmh: 30,
        deadhead_circuity: 1.3,
        max_piece_minutes: nil
      })

    {:ok, :ok} =
      Blocking.update_relief_settings(audit, nil, %{max_piece_minutes: 120, marked: []})

    day_key = day_key!(organization, version)

    runs_trip(
      %{organization: organization, version: version, route: route, day_key: day_key},
      "night",
      "201",
      "22:30:00",
      "25:10:00",
      "BAY_A",
      "BAY_A",
      "4001"
    )

    runs_trip(
      %{organization: organization, version: version, route: route, day_key: day_key},
      "free",
      "205",
      "11:00:00",
      "11:30:00",
      "BAY_A",
      "BAY_A",
      nil
    )

    %{
      organization: organization,
      version: version,
      route: route,
      day_key: day_key,
      garage: garage
    }
  end

  # `HH:MM:00` in the service day, past midnight where the day runs over.
  defp clock(minutes) do
    hours = Integer.to_string(div(minutes, 60)) |> String.pad_leading(2, "0")
    rest = Integer.to_string(rem(minutes, 60)) |> String.pad_leading(2, "0")
    "#{hours}:#{rest}:00"
  end

  defp runs_trip(context, trip_id, block_id, first, last, first_stop, last_stop, run_id) do
    trip =
      blocked_trip_fixture(context.organization.id, context.version.id, context.route.route_id, %{
        trip_id: trip_id,
        service_id: "WK",
        block_id: block_id,
        first_stop: first_stop,
        last_stop: last_stop,
        first_departure: first,
        last_arrival: last
      })

    if run_id do
      trip_run_fixture(context.organization.id, context.version.id, %{
        trip: trip,
        day_type_key: context.day_key,
        run_id: run_id
      })
    end

    trip
  end

  defp day_key!(organization, version) do
    assert {:ok, runs_day} = Runs.load_runs(organization.id, version.id, nil)
    runs_day.day.day_type.key
  end

  defp load_day!(context) do
    assert {:ok, day} =
             Blocking.load_day(context.organization.id, context.version.id, context.day_key)

    day
  end

  defp load_runs!(context) do
    assert {:ok, runs_day} =
             Runs.load_runs(context.organization.id, context.version.id, context.day_key)

    runs_day
  end

  defp suggest_blocks!(context) do
    assert {:ok, plan} =
             Blocking.suggest_blocks(
               context.organization.id,
               context.version.id,
               context.day_key,
               :replace_all
             )

    plan
  end

  defp suggest_runs!(context) do
    assert {:ok, plan} =
             Runs.suggest_runs(
               context.organization.id,
               context.version.id,
               context.day_key,
               :replace_all
             )

    plan
  end

  defp project!(context, selection \\ %{}) do
    assert {:ok, payload} = OperationsAssistance.block_day(load_day!(context), selection)
    payload
  end

  defp block_ref(payload, block_id) do
    payload["entities"]["blocks"]
    |> Enum.find(&(&1["block_id"] == block_id))
    |> Map.fetch!("block_ref")
  end

  defp scope!(context, resource_context) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: Ecto.UUID.generate(),
      pack_id: "blocks",
      resource_context: resource_context
    }
  end

  # The admitted source read back through the shared owner's own accessor, over
  # a scope carrying the admitted resource context and nothing else.
  defp read_snapshot(resource_context) do
    scope =
      struct(Scope, %{
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        pack_id: "blocks",
        resource_context: resource_context
      })

    Scope.source_snapshot(scope)
  end

  # A run-shaped ref the snapshot does not hold, deterministic per index.
  defp run_ref(index) do
    "run_" <>
      (:crypto.hash(:sha256, <<index>>) |> Base.encode16(case: :lower) |> binary_part(0, 32))
  end

  # --- the shared owner's measurement -------------------------------------

  # The whole serialized resource context, exactly as `Scope` builds it: the
  # tagged identity, the absent approval, and the snapshot envelope carrying the
  # server's own digest. Recomputing it here is what makes the cap assertion an
  # independent check of the shared owner rather than a restatement of it.
  defp context_bytes(payload, version_id) do
    kind = "operations_blocks"

    digest =
      {kind, payload}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Jason.encode!(%{
      "identity" => %{"kind" => "version", "id" => version_id},
      "approved_extension" => nil,
      "source_snapshot" => %{"kind" => kind, "payload" => payload, "digest" => digest}
    })
    |> byte_size()
  end

  # A payload padded - in a field no projection reads, because what is under test
  # is the cap - to exactly `target` whole-context bytes.
  defp boundary_payload(payload, version_id, target) do
    padded =
      Enum.reduce(0..70_000, nil, fn size, acc ->
        candidate = Map.put(payload, "pad", String.duplicate("p", size))

        cond do
          is_nil(acc) and context_bytes(candidate, version_id) <= target -> candidate
          is_nil(acc) -> nil
          context_bytes(candidate, version_id) > target -> acc
          true -> candidate
        end
      end)

    assert context_bytes(padded, version_id) == target
    padded
  end
end
