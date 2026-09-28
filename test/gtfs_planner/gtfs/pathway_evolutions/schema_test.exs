defmodule GtfsPlanner.Gtfs.PathwayEvolutionSchemaTest do
  @moduledoc """
  Closure persistence boundary: service-time parsing, the changeset rules and the
  database constraints reached through the production write path
  (`PathwayEvolution.changeset/2` then `Repo.insert/1`).
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query

  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Repo

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @max_seconds 2_147_483_647

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    entrance = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "ENT_1"})
    platform = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "PLAT_1"})

    pathway =
      pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_1"
      })

    calendar = calendar_fixture(organization.id, gtfs_version.id, %{service_id: "SVC_1"})

    %{
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id,
      pathway_id: pathway.pathway_id,
      service_id: calendar.service_id
    }
  end

  describe "parse_service_time/1" do
    test "accepts H:MM, HH:MM and H:MM:SS as service-day seconds" do
      for {input, seconds} <- [
            {"9:30", 34_200},
            {"09:30", 34_200},
            {"9:30:15", 34_215},
            {"09:30:15", 34_215},
            {"23:00", 82_800},
            {"24:00:00", 86_400},
            {"26:00", 93_600},
            {"0:00", 0},
            {" 23:00", 82_800},
            {"26:00 ", 93_600}
          ] do
        assert PathwayEvolution.parse_service_time(input) == {:ok, seconds},
               "expected #{input} to parse to #{seconds}"
      end
    end

    test "accepts values that are already integer seconds" do
      assert PathwayEvolution.parse_service_time(0) == {:ok, 0}
      assert PathwayEvolution.parse_service_time(82_800) == {:ok, 82_800}
      assert PathwayEvolution.parse_service_time(@max_seconds) == {:ok, @max_seconds}
    end

    test "refuses malformed, negative and oversized values" do
      for input <- [
            "",
            "23",
            "2:3:4",
            "23:60",
            "23:00:60",
            "23:00:0X",
            "-1:00",
            "999999:00:00",
            "2 3:00"
          ] do
        assert PathwayEvolution.parse_service_time(input) == {:error, :invalid_time},
               "expected #{inspect(input)} to be refused"
      end

      for input <- [-1, -3600, @max_seconds + 1, nil, :clock, ~T[23:00:00]] do
        assert PathwayEvolution.parse_service_time(input) == {:error, :invalid_time},
               "expected #{inspect(input)} to be refused"
      end
    end
  end

  describe "changeset/2 with Repo.insert/1" do
    test "stores an overnight window as integer seconds and reloads identically", context do
      assert {:ok, evolution} =
               context
               |> closure_changeset(%{
                 pathway_id: "PW_1",
                 service_id: "SVC_1",
                 start_time: "23:00",
                 end_time: "26:00",
                 note: "Overnight engineering"
               })
               |> Repo.insert()

      assert evolution.start_time == 82_800
      assert evolution.end_time == 93_600

      reloaded = Repo.one(from(e in PathwayEvolution, where: e.id == ^evolution.id))
      assert reloaded.start_time == 82_800
      assert reloaded.end_time == 93_600
      assert reloaded.note == "Overnight engineering"
      assert reloaded.organization_id == evolution.organization_id
      assert reloaded.gtfs_version_id == evolution.gtfs_version_id
    end

    test "accepts integer seconds and rejects a wrapped window", context do
      assert {:ok, evolution} =
               context
               |> closure_changeset(%{
                 pathway_id: "PW_1",
                 service_id: "SVC_1",
                 start_time: 82_800,
                 end_time: 93_600
               })
               |> Repo.insert()

      assert {evolution.start_time, evolution.end_time} == {82_800, 93_600}

      changeset =
        closure_changeset(context, %{
          pathway_id: "PW_1",
          service_id: "SVC_1",
          start_time: "23:00",
          end_time: "02:00"
        })

      refute changeset.valid?
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :end_time)
      assert Enum.any?(errors.end_time, &String.contains?(&1, "24:00"))

      changeset_equal =
        closure_changeset(context, %{
          pathway_id: "PW_1",
          service_id: "SVC_1",
          start_time: "23:00",
          end_time: "23:00"
        })

      refute changeset_equal.valid?
      assert Map.has_key?(errors_on(changeset_equal), :end_time)
    end

    test "refuses blank identifiers, oversized and malformed times, and long notes", context do
      base = %{pathway_id: "PW_1", service_id: "SVC_1", start_time: "23:00", end_time: "26:00"}

      blank_pathway = closure_changeset(context, Map.put(base, :pathway_id, "   "))
      refute blank_pathway.valid?
      assert Map.has_key?(errors_on(blank_pathway), :pathway_id)

      blank_service = closure_changeset(context, Map.put(base, :service_id, ""))
      refute blank_service.valid?
      assert Map.has_key?(errors_on(blank_service), :service_id)

      malformed = closure_changeset(context, Map.put(base, :start_time, "23:0"))
      refute malformed.valid?
      assert Map.has_key?(errors_on(malformed), :start_time)

      oversized =
        closure_changeset(context, Map.put(base, :end_time, "#{@max_seconds + 3_600}:00:00"))

      refute oversized.valid?
      assert Map.has_key?(errors_on(oversized), :end_time)

      long_note = closure_changeset(context, Map.put(base, :note, String.duplicate("a", 501)))
      refute long_note.valid?
      assert Map.has_key?(errors_on(long_note), :note)

      boundary_note = closure_changeset(context, Map.put(base, :note, String.duplicate("a", 500)))
      assert boundary_note.valid?
    end

    test "keeps an identifier with internal spaces distinct from its trimmed neighbour",
         context do
      spacey =
        pathway_fixture(
          context.organization_id,
          context.gtfs_version_id,
          "ENT_1",
          "PLAT_1",
          %{pathway_id: "PW 1"}
        )

      assert spacey.pathway_id == "PW 1"

      assert {:ok, first} =
               context
               |> closure_changeset(%{
                 pathway_id: " PW 1 ",
                 service_id: "SVC_1",
                 start_time: "23:00",
                 end_time: "26:00"
               })
               |> Repo.insert()

      assert {:ok, second} =
               context
               |> closure_changeset(%{
                 pathway_id: "PW_1",
                 service_id: "SVC_1",
                 start_time: "23:00",
                 end_time: "26:00"
               })
               |> Repo.insert()

      # Surrounding whitespace is trimmed to the stored identifier, while the
      # internal space survives: "PW 1" and "PW_1" are two different pathways.
      assert first.pathway_id == "PW 1"
      assert second.pathway_id == "PW_1"
      assert first.pathway_id != second.pathway_id
    end

    test "scope is assigned on the struct and never taken from parameters", context do
      foreign = organization_fixture()

      changeset =
        closure_changeset(context, %{
          pathway_id: "PW_1",
          service_id: "SVC_1",
          start_time: "23:00",
          end_time: "26:00",
          organization_id: foreign.id,
          gtfs_version_id: Ecto.UUID.generate()
        })

      refute Map.has_key?(changeset.changes, :organization_id)
      refute Map.has_key?(changeset.changes, :gtfs_version_id)

      # Without an assigned scope the same parameters cannot borrow the foreign
      # organization: the row has no scope at all and the database refuses it.
      assert_raise Postgrex.Error, fn ->
        %PathwayEvolution{}
        |> PathwayEvolution.changeset(%{
          pathway_id: "PW_1",
          service_id: "SVC_1",
          start_time: "23:00",
          end_time: "26:00",
          organization_id: foreign.id
        })
        |> Repo.insert!()
      end
    end

    test "the default insert path refuses a pathway outside the closure scope", context do
      other_version = gtfs_version_fixture(context.organization_id)

      # Same organization, same identifier string, but no pathway row in the
      # version the closure claims.
      assert {:error, changeset} =
               %{context | gtfs_version_id: other_version.id}
               |> closure_changeset(%{
                 pathway_id: "PW_1",
                 service_id: "SVC_1",
                 start_time: "23:00",
                 end_time: "26:00"
               })
               |> Repo.insert()

      assert Map.has_key?(errors_on(changeset), :pathway_id)

      # Once the pathway exists in that version, the identical tuple is accepted:
      # the reference is scoped, not global.
      pathway_fixture(
        context.organization_id,
        other_version.id,
        "ENT_1",
        "PLAT_1",
        %{pathway_id: "PW_1"}
      )

      assert {:ok, scoped} =
               %{context | gtfs_version_id: other_version.id}
               |> closure_changeset(%{
                 pathway_id: "PW_1",
                 service_id: "SVC_1",
                 start_time: "23:00",
                 end_time: "26:00"
               })
               |> Repo.insert()

      assert scoped.gtfs_version_id == other_version.id
    end

    test "the default insert path refuses an exact duplicate tuple", context do
      attrs = %{
        pathway_id: "PW_1",
        service_id: "SVC_1",
        start_time: "23:00",
        end_time: "26:00"
      }

      assert {:ok, _first} = context |> closure_changeset(attrs) |> Repo.insert()

      assert {:error, duplicate} = context |> closure_changeset(attrs) |> Repo.insert()
      assert duplicate.valid? == false
      assert errors_on(duplicate) != %{}

      # A neighbouring window on the same pathway and service is not a duplicate.
      assert {:ok, _second} =
               context
               |> closure_changeset(Map.put(attrs, :start_time, "20:00"))
               |> Repo.insert()
    end
  end

  # --- helpers -------------------------------------------------------------

  defp closure_changeset(context, attrs) do
    %PathwayEvolution{
      organization_id: context.organization_id,
      gtfs_version_id: context.gtfs_version_id
    }
    |> PathwayEvolution.changeset(attrs)
  end
end
