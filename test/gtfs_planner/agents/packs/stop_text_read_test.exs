defmodule GtfsPlanner.Agents.Packs.StopTextReadTest do
  @moduledoc """
  Merge evidence (EV-16) for the Stop text helper's admission and `read_stop_set`.

  The approved set is a 60-stop list built here: stop `A01` to `A60`, each with a
  name, code, description and URL derived from its number, so the expected values are
  hand-written literals. The set is admitted through the real
  `Scope.with_source_snapshot/2`; the provider fake must never be reached for a set
  the page could not have approved.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.StopHelperFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.StopText
  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop

  setup do
    Req.Test.set_req_test_to_shared()
    ScriptedProvider.track_sessions()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    stops =
      for number <- 1..60 do
        id = "A" <> String.pad_leading("#{number}", 2, "0")

        stop =
          stop_fixture(organization.id, version.id, %{
            stop_id: id,
            stop_name: "Stop #{id}",
            stop_desc: "Desc #{id}"
          })

        # The insert fixture does not cast code or URL; an import stores them directly.
        Repo.update_all(from(s in Stop, where: s.id == ^stop.id),
          set: [
            stop_code: "C#{String.pad_leading("#{number}", 2, "0")}",
            stop_url: "https://example.org/#{id}"
          ]
        )

        Repo.reload!(stop)
      end

    %{
      organization: organization,
      version: version,
      user: user,
      membership: membership,
      stops: stops
    }
  end

  describe "read_stop_set" do
    test "pages a 60-stop set 25, 25 and 10 in stop_id order with exact values", context do
      # Admit the set in reverse order: the page order is the stops', not the snapshot's.
      scope = scope(context, uuids(context.stops) |> Enum.reverse())

      pages =
        for offset <- [0, 25, 50] do
          assert {:ok, result, evidence} = read(scope, %{"offset" => offset})
          {result, evidence}
        end

      assert Enum.map(pages, fn {result, _} -> result["returned"] end) == [25, 25, 10]
      assert Enum.map(pages, fn {result, _} -> result["next_offset"] end) == [25, 50, nil]
      assert Enum.map(pages, fn {result, _} -> result["total"] end) == [60, 60, 60]

      assert Enum.map(pages, fn {_, evidence} -> evidence.completeness end) ==
               [:incomplete, :incomplete, :complete]

      assert {_, first} = hd(pages)
      assert first.completeness_reason == "Showing 25 of 60"

      assert {first.kind, first.total, first.total_label} ==
               {"stop_set", 60, "stops in the approved list"}

      rows = Enum.flat_map(pages, fn {result, _} -> result["stops"] end)

      assert Enum.map(rows, & &1["stop_id"]) ==
               for(n <- 1..60, do: "A" <> String.pad_leading("#{n}", 2, "0"))

      assert Enum.at(rows, 0) == %{
               "stop_id" => "A01",
               "stop_code" => "C01",
               "stop_name" => "Stop A01",
               "stop_desc" => "Desc A01",
               "stop_url" => "https://example.org/A01",
               "location_type" => 0,
               "parent_station" => nil,
               "truncated" => []
             }

      assert Enum.at(rows, 59)["stop_name"] == "Stop A60"
    end

    test "cuts a long field at 200 characters and names it", context do
      long = String.duplicate("d", 500)
      stop = hd(context.stops)
      Repo.update_all(from(s in Stop, where: s.id == ^stop.id), set: [stop_desc: long])

      scope = scope(context, uuids(context.stops))
      assert {:ok, result, _evidence} = read(scope, %{})

      assert [first | _] = result["stops"]
      assert first["stop_desc"] == String.duplicate("d", 200)
      assert first["truncated"] == ["stop_desc"]
      assert byte_size(Jason.encode!(result)) < 32_768
    end

    test "evidence names stops by GTFS ID under the version identity, and nothing is written",
         context do
      scope = scope(context, uuids(Enum.take(context.stops, 3)))
      before = stamps(context)

      assert {:ok, result, evidence} = read(scope, %{})
      assert result["total"] == 3

      assert evidence.scope == %{
               organization_id: context.organization.id,
               gtfs_version_id: context.version.id,
               identity: "version:#{context.version.id}"
             }

      assert evidence.resources == [
               %{kind: "stop", id: "A01", label: "Stop A01"},
               %{kind: "stop", id: "A02", label: "Stop A02"},
               %{kind: "stop", id: "A03", label: "Stop A03"}
             ]

      assert stamps(context) == before

      # Resources are bounded at ten however large the page is.
      full = scope(context, uuids(context.stops))
      assert {:ok, _result, big} = read(full, %{})
      assert length(big.resources) == 10
    end

    test "arguments cannot name a set, a stop or a scope", context do
      scope = scope(context, uuids(context.stops))

      for key <- ~w(stop_uuids stop_id organization_id gtfs_version_id) do
        assert {:tool_error, "Unexpected argument: " <> ^key} =
                 Dispatch.call(StopText, scope, "read_stop_set", ~s({"#{key}":"x"}))
      end

      for offset <- [-1, 100_001] do
        assert {:tool_error, message} =
                 Dispatch.call(StopText, scope, "read_stop_set", ~s({"offset":#{offset}}))

        assert message =~ "offset"
      end
    end
  end

  describe "admission" do
    test "a set the page could not have approved is unavailable before any provider request",
         context do
      other_version = gtfs_version_fixture(context.organization.id)
      elsewhere = stop_fixture(context.organization.id, other_version.id, %{stop_id: "A01"})
      gone = stop_fixture(context.organization.id, context.version.id, %{stop_id: "GONE"})
      Repo.delete!(gone)

      good = uuids(Enum.take(context.stops, 2))
      many = for _ <- 1..101, do: Ecto.UUID.generate()

      cases = [
        {"stop of another version", good ++ [elsewhere.id]},
        {"deleted stop", good ++ [gone.id]},
        {"duplicate UUID", good ++ [hd(good)]},
        {"non-UUID", good ++ ["not-a-uuid"]},
        {"empty set", []},
        {"101 stops", many}
      ]

      stub_provider()

      for {label, set} <- cases do
        scope = scope(context, set)
        assert StopText.authorize_context(scope) == {:error, :unavailable}, label
        assert Agents.open(scope) == {:error, :unavailable}, label

        assert Dispatch.call(StopText, scope, "read_stop_set", "{}") == {:error, :unavailable},
               label
      end

      no_snapshot =
        helper_scope("stop_text", context.organization, context.version, context.user, :none)

      assert Agents.open(no_snapshot) == {:error, :unavailable}

      version_two =
        helper_scope(
          "stop_text",
          context.organization,
          context.version,
          context.user,
          {"stop_set", %{"schema_version" => 2, "stop_uuids" => good}}
        )

      assert StopText.authorize_context(version_two) == {:error, :unavailable}
      refute_received :provider_called
    end

    test "a revoked membership refuses the next request, tool and delivered result", context do
      scope = scope(context, uuids(Enum.take(context.stops, 2)))
      assert {:ok, session, _snapshot} = Agents.open(scope)

      stub_provider()
      deactivate_membership_fixture(context.membership)

      assert Agents.send_message(session, "Show the list") == {:error, :forbidden}
      assert Dispatch.call(StopText, scope, "read_stop_set", "{}") == {:error, :forbidden}
      assert Agents.open(scope) == {:error, :forbidden}
      refute_received :provider_called
    end

    test "the registry ships a read-only pack" do
      assert Agents.packs()["stop_text"] == StopText
      assert {StopText.id(), StopText.title()} == {"stop_text", "Stop text helper"}
      assert "read_stop_set" in Enum.map(StopText.tools(), & &1.name)
      assert StopText.skill() =~ "read_stop_set"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp uuids(stops), do: Enum.map(stops, & &1.id)

  defp scope(context, uuids) do
    helper_scope(
      "stop_text",
      context.organization,
      context.version,
      context.user,
      {"stop_set", %{"schema_version" => 1, "stop_uuids" => uuids}}
    )
  end

  defp read(scope, args), do: Dispatch.call(StopText, scope, "read_stop_set", Jason.encode!(args))

  defp stamps(context) do
    {Repo.all(from(s in Stop, order_by: s.id, select: {s.id, s.updated_at, s.stop_name})),
     Repo.aggregate(
       from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
       :count
     )}
  end

  defp stub_provider do
    test = self()

    Req.Test.stub(GtfsPlanner.Agents.Model, fn conn ->
      send(test, :provider_called)
      Plug.Conn.send_resp(conn, 500, "unexpected provider request")
    end)
  end
end
