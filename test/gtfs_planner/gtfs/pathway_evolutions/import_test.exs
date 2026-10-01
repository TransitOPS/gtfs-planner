defmodule GtfsPlanner.Gtfs.PathwayEvolutions.ImportTest do
  @moduledoc """
  Scheduled-closure interchange through the registered import composition.

  Every expectation is hand-authored from AC-25, AC-26 and AC-27; no production
  function computes an expected value. The tests drive the real registered path
  (`ImportRuns` target and claim, `Publication.run/4`, `ImportRuns.claim_cleanup/3`,
  `Recovery.discard_claimed/3`) with authored CSV files, so the manifest entry,
  the reference pass and the recovery ordering are exercised through production
  wiring rather than a private seam.

  Covered behaviour:

    * the supported subset imports one closure per row as integer seconds,
      including an overnight window above 24:00:00, with no application note;
    * every one of the eight fixed codes fails phase one with its own
      `failed_file`, CSV row and `reason_code`, zero closure rows and an
      unpublished version, and the bounded triple survives on the durable run;
    * a repeated tuple across batch and file boundaries, or against a row already
      in the target version, is reported against the repeating row's own source
      row rather than as a database constraint error;
    * a later `stop_times.txt` phase failure keeps the version unpublished, and
      ordinary discard recovery removes the failed version's closures before its
      pathways while another version's closures survive.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Failure, Publication, Recovery, Run}
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @closure_header "pathway_id,service_id,start_time,end_time,is_closed\n"
  @closure_header_with_direction "pathway_id,service_id,start_time,end_time,is_closed,direction\n"

  @levels "level_id,level_index,level_name\nL1,0,Street\n"

  @stops """
  stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station,level_id
  S1,Main,40.7,-74.0,1,,L1
  E1,Entrance,40.7,-74.001,2,S1,L1
  P1,Platform,40.7,-74.002,0,S1,L1
  """

  @pathways "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional\nPW1,E1,P1,1,1\n"

  @calendar """
  service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
  WK,1,1,1,1,1,0,0,20270101,20270131
  """

  @calendar_dates "service_id,date,exception_type\nHOLIDAY,20270314,2\n"

  @routes "route_id,route_type,route_short_name,route_long_name\nR1,3,1,Red\n"

  # One entry per AC-26 code. Each body is a complete authored file whose first
  # data row is supported and whose second data row is rejected, so every
  # recorded row is 3 and the accepted row before it must not persist either:
  # phase one fails as a whole. The `direction` code needs the optional sixth
  # column, because a five-column file cannot express a direction at all.
  @accepted_row "PW1,WK,09:00:00,15:00:00,1\n"

  @rejections [
    {"evolution_pathway_required", 3,
     @closure_header <> @accepted_row <> ",WK,09:00:00,15:00:00,1\n"},
    {"evolution_service_required", 3,
     @closure_header <> @accepted_row <> "PW1,,09:00:00,15:00:00,1\n"},
    {"evolution_opening_unsupported", 3,
     @closure_header <> @accepted_row <> "PW1,WK,09:00:00,15:00:00,0\n"},
    {"evolution_direction_unsupported", 3,
     @closure_header_with_direction <>
       "PW1,WK,09:00:00,15:00:00,1,\n" <>
       "PW1,WK,09:00:00,15:00:00,1,0\n"},
    {"evolution_time_invalid", 3,
     @closure_header <> @accepted_row <> "PW1,WK,23:00:00,02:00:00,1\n"},
    {"evolution_pathway_missing", 3,
     @closure_header <> @accepted_row <> "GHOST,WK,09:00:00,15:00:00,1\n"},
    {"evolution_service_missing", 3,
     @closure_header <> @accepted_row <> "PW1,METADATA_ONLY,09:00:00,15:00:00,1\n"},
    {"evolution_duplicate", 3, @closure_header <> @accepted_row <> @accepted_row}
  ]

  setup do
    organization = organization_fixture()
    # Creating a target and publishing reauthorize the actor, so the actor is an active editor.
    actor = editor_fixture(organization)

    %{organization: organization, actor: actor}
  end

  describe "accepted supported subset" do
    test "a durable import stores one closure per row as integer seconds", %{
      organization: organization,
      actor: actor
    } do
      {run, token} = claimed_run(organization, actor, "Closure Feed")

      body =
        @closure_header_with_direction <>
          "PW1,WK,09:00:00,15:00:00,1,\n" <>
          "PW1,WK,23:00:00,26:00:00,1,\n" <>
          "PW1,WK,0:30:00,01:00:00,1,\n"

      assert {:ok, version, result} =
               Publication.run(
                 run,
                 token,
                 StagedImport.stage(feed() ++ [closures(body)]),
                 "import:closures"
               )

      assert version.publication_status == "published"
      assert Import.Result.publishable?(result)
      assert result.counts.pathway_evolutions == 3
      assert result.unrecognized_files == []

      assert closure_tuples(organization, version) == [
               {"PW1", "WK", 1_800, 3_600},
               {"PW1", "WK", 32_400, 54_000},
               {"PW1", "WK", 82_800, 93_600}
             ]

      # The interchange format carries no note, so the application-only column
      # is never filled from a file value.
      assert Repo.all(
               from(e in PathwayEvolution,
                 where:
                   e.organization_id == ^organization.id and e.gtfs_version_id == ^version.id,
                 select: e.note
               )
             ) == [nil, nil, nil]

      # The file is registered, and its count travels on the shared count-key
      # allowlist rather than through a separate status channel.
      assert "pathway_evolutions.txt" in Import.supported_filenames()
      assert :pathway_evolutions in Import.supported_count_keys()

      persisted = Repo.get!(Run, run.id)
      assert persisted.state == "published"
      assert persisted.committed_counts["pathway_evolutions"] == 3
      assert persisted.committed_counts["pathways"] == 1
    end

    test "a service with only calendar_dates rows is a valid closure reference", %{
      organization: organization,
      actor: actor
    } do
      {run, token} = claimed_run(organization, actor, "Dates Only Feed")

      files = [
        %{filename: "levels.txt", content: @levels},
        %{filename: "stops.txt", content: @stops},
        %{filename: "pathways.txt", content: @pathways},
        %{filename: "calendar_dates.txt", content: @calendar_dates},
        closures(@closure_header <> "PW1,HOLIDAY,09:00:00,15:00:00,1\n")
      ]

      assert {:ok, version, result} =
               Publication.run(run, token, StagedImport.stage(files), "import:dates-only")

      assert result.counts.pathway_evolutions == 1
      assert closure_tuples(organization, version) == [{"PW1", "HOLIDAY", 32_400, 54_000}]
    end

    test "an unknown file beside the closure file is still reported", %{
      organization: organization,
      actor: actor
    } do
      {run, token} = claimed_run(organization, actor, "Closure Feed With Extras")

      body = @closure_header <> "PW1,WK,09:00:00,15:00:00,1\n"

      files =
        feed() ++
          [
            closures(body),
            %{filename: "notes.txt", content: "operator notes\n"}
          ]

      assert {:ok, version, result} =
               Publication.run(run, token, StagedImport.stage(files), "import:extras")

      assert result.unrecognized_files == ["notes.txt"]
      assert result.counts.pathway_evolutions == 1
      assert length(closure_tuples(organization, version)) == 1
    end
  end

  describe "rejected rows fail phase one" do
    test "every fixed code persists its exact file, row and code with no published version", %{
      organization: organization,
      actor: actor
    } do
      for {code, row, body} <- @rejections do
        {run, token} = claimed_run(organization, actor, "Rejected #{code}")

        files =
          feed() ++
            [
              closures(body),
              # A metadata-only identity is not a native calendar row, so it must
              # not satisfy a closure's service reference (AC-26, AC-10).
              %{
                filename: "calendar_attributes.txt",
                content: "service_id,service_description\nMETADATA_ONLY,Weekend only\n"
              }
            ]

        assert {:error, _version, %Failure{} = failure} =
                 Publication.run(run, token, StagedImport.stage(files), "import:rejected-#{code}"),
               "expected #{code} to be refused"

        assert failure.phase == :phase_1, "wrong phase for #{code}"
        assert failure.outcome == :failed, "wrong outcome for #{code}"
        assert failure.failed_file == "pathway_evolutions.txt", "wrong file for #{code}"
        assert failure.failed_row == row, "wrong row for #{code}"
        assert failure.reason_code == code

        # Nothing from phase one is durable, including the accepted row that
        # preceded the rejection, and no other file survived either.
        assert closure_count(organization, run.gtfs_version_id) == 0,
               "closure row kept for #{code}"

        assert Repo.aggregate(
                 from(p in Gtfs.Pathway,
                   where:
                     p.organization_id == ^organization.id and
                       p.gtfs_version_id == ^run.gtfs_version_id
                 ),
                 :count
               ) == 0,
               "pathway row kept for #{code}"

        version = Repo.get!(GtfsVersion, run.gtfs_version_id)
        assert version.publication_status == "failed", "version published for #{code}"
        refute Versions.published_gtfs_version_for_org?(organization.id, version.id)

        persisted = Repo.get!(Run, run.id)
        assert persisted.state == "failed", "wrong run state for #{code}"
        assert persisted.phase == "phase_1", "wrong run phase for #{code}"
        assert persisted.failed_file == "pathway_evolutions.txt", "wrong run file for #{code}"
        assert persisted.failed_row == row, "wrong run row for #{code}"
        assert persisted.reason_code == code
        assert persisted.committed_counts["pathway_evolutions"] == 0
        assert persisted.counts_complete

        # The durable receipt is bounded: it names a file, a row and a code, and
        # carries no value from the rejected row and no directory component.
        refute inspect(persisted) =~ "09:00:00", "row text persisted for #{code}"
        refute inspect(persisted) =~ "PW1", "row value persisted for #{code}"
        refute persisted.failed_file =~ "/", "path persisted for #{code}"
      end
    end

    test "a structural CSV failure keeps its parser reason instead of a closure code", %{
      organization: organization,
      actor: actor
    } do
      {run, token} = claimed_run(organization, actor, "Bad Header")

      # Four columns declared but five supplied: the record cannot be read as a
      # closure row, so the parser's own bounded reason is reported.
      body = "pathway_id,service_id,start_time,end_time\nPW1,WK,09:00:00,15:00:00,1\n"

      assert {:error, _version, %Failure{} = failure} =
               Publication.run(
                 run,
                 token,
                 StagedImport.stage(feed() ++ [closures(body)]),
                 "import:bad-header"
               )

      assert failure.phase == :phase_1
      assert failure.failed_file == "pathway_evolutions.txt"
      assert failure.failed_row == 2
      assert failure.reason_code == "wrong_field_count"
    end

    test "a closure may not name another organization's pathway or service", %{
      organization: organization,
      actor: actor
    } do
      other = organization_fixture()
      other_version = gtfs_version_fixture(other.id)

      level_fixture(other.id, other_version.id, %{level_id: "OTHER_L", level_index: 0.0})

      other_stop =
        stop_fixture(other.id, other_version.id, %{stop_id: "OTHER_S", location_type: 0})

      other_to = stop_fixture(other.id, other_version.id, %{stop_id: "OTHER_T", location_type: 0})

      pathway_fixture(other.id, other_version.id, other_stop.stop_id, other_to.stop_id, %{
        pathway_id: "OTHER_PW"
      })

      calendar_fixture(other.id, other_version.id, %{service_id: "OTHER_WK"})

      # The foreign pathway does not exist in this scope, so the row is refused
      # on its own row with the pathway code.
      {pathway_run, pathway_token} = claimed_run(organization, actor, "Foreign Pathway")

      assert {:error, _version, %Failure{} = pathway_failure} =
               Publication.run(
                 pathway_run,
                 pathway_token,
                 StagedImport.stage(
                   feed() ++ [closures(@closure_header <> "OTHER_PW,WK,09:00:00,15:00:00,1\n")]
                 ),
                 "import:foreign-pathway"
               )

      assert pathway_failure.reason_code == "evolution_pathway_missing"
      assert pathway_failure.failed_row == 2

      # The foreign service exists only in another organization, so it is refused
      # as a missing native reference rather than as an unknown pathway.
      {service_run, service_token} = claimed_run(organization, actor, "Foreign Service")

      assert {:error, _version, %Failure{} = service_failure} =
               Publication.run(
                 service_run,
                 service_token,
                 StagedImport.stage(
                   feed() ++ [closures(@closure_header <> "PW1,OTHER_WK,09:00:00,15:00:00,1\n")]
                 ),
                 "import:foreign-service"
               )

      assert service_failure.reason_code == "evolution_service_missing"
      assert service_failure.failed_row == 2
    end
  end

  describe "duplicates across files, batches and stored rows" do
    test "a repeat in a later file is reported against the repeating row", %{
      organization: organization,
      actor: actor
    } do
      {run, token} = claimed_run(organization, actor, "Duplicate Across Files")

      first = @closure_header <> "PW1,WK,09:00:00,15:00:00,1\n"

      # The second file uses a different column order, so the repeat can only be
      # found from the parsed tuple, never from a shared column layout.
      second = "service_id,pathway_id,start_time,end_time,is_closed\nWK,PW1,09:00:00,15:00:00,1\n"

      files = feed() ++ [closures(first), closures(second)]

      assert {:error, _version, %Failure{} = failure} =
               Publication.run(run, token, StagedImport.stage(files), "import:duplicate-files")

      assert failure.phase == :phase_1
      assert failure.reason_code == "evolution_duplicate"
      assert failure.failed_file == "pathway_evolutions.txt"

      # Row 2 of the second file, not the row of the first occurrence: the
      # recorded row identifies the offender.
      assert failure.failed_row == 2
      assert closure_count(organization, run.gtfs_version_id) == 0
    end

    test "a repeat after a full batch boundary is reported, not raised by the index", %{
      organization: organization,
      actor: actor
    } do
      {run, token} = claimed_run(organization, actor, "Duplicate Across Batches")

      # The importer batches every `import_batch_size` rows. Filling one whole
      # batch and then repeating the first window proves the duplicate set is
      # carried across the batch boundary, not reset at each flush.
      batch_size = Application.get_env(:gtfs_planner, :import_batch_size, 1000)

      distinct =
        for index <- 0..(batch_size - 1) do
          start = index * 60
          "PW1,WK,#{service_time(start)},#{service_time(start + 30)},1\n"
        end

      body = @closure_header <> Enum.join(distinct) <> "PW1,WK,00:00:00,00:00:30,1\n"

      assert {:error, _version, %Failure{} = failure} =
               Publication.run(
                 run,
                 token,
                 StagedImport.stage(feed() ++ [closures(body)]),
                 "import:duplicate-batch"
               )

      assert failure.phase == :phase_1
      assert failure.reason_code == "evolution_duplicate"
      assert failure.failed_file == "pathway_evolutions.txt"
      assert failure.failed_row == batch_size + 2

      # A database error here would be the unique closure index firing; the
      # bounded code means the reference pass found it first.
      refute failure.reason_code in ["constraint_violation", "database_error"]
      assert closure_count(organization, run.gtfs_version_id) == 0
    end

    test "a tuple already stored in the target version is reported as a duplicate", %{
      organization: organization
    } do
      version = gtfs_version_fixture(organization.id)

      {_seeded_closure, _seeded_pathway} =
        seed_closure(organization, version, "PW1", "WK", 32_400, 54_000)

      body = @closure_header <> "PW1,WK,10:00:00,11:00:00,1\n"

      # Importing into one version that already holds a closure is the state where
      # a new row collides with the existing unique index. The reference pass
      # converts that collision into the bounded duplicate code, and the stored
      # closure is left alone.
      assert {:ok, first} =
               StagedImport.import_files(organization.id, version.id, [closures(body)])

      assert first.counts.pathway_evolutions == 1

      repeat = @closure_header <> "PW1,WK,12:00:00,13:00:00,1\nPW1,WK,09:00:00,15:00:00,1\n"

      assert {:error, %Failure{} = failure} =
               StagedImport.import_files(organization.id, version.id, [closures(repeat)])

      assert failure.phase == :phase_1
      assert failure.reason_code == "evolution_duplicate"
      assert failure.failed_file == "pathway_evolutions.txt"

      # Row 3 is the row that repeats the closure stored before this import.
      assert failure.failed_row == 3

      assert closure_tuples(organization, version) == [
               {"PW1", "WK", 32_400, 54_000},
               {"PW1", "WK", 36_000, 39_600}
             ]
    end
  end

  describe "later phase failure and recovery" do
    test "a stop_times phase failure stays unpublished and discard removes only its version", %{
      organization: organization,
      actor: actor
    } do
      # An unrelated version that owns the same natural ids must survive the
      # failed version's cleanup untouched.
      survivor_version = gtfs_version_fixture(organization.id)

      {survivor_closure, survivor_pathway} =
        seed_closure(organization, survivor_version, "PW1", "WK", 32_400, 54_000)

      {run, token} = claimed_run(organization, actor, "Phase Two Failure")

      good = @closure_header <> "PW1,WK,09:00:00,15:00:00,1\n"

      files =
        feed() ++
          [
            %{filename: "routes.txt", content: @routes},
            %{
              filename: "trips.txt",
              content: "trip_id,route_id,service_id,direction_id\nT1,R1,WK,0\n"
            },
            # A stop_times record with the wrong field count fails the later phase
            # after the closure rows are already durable.
            %{
              filename: "stop_times.txt",
              content:
                "trip_id,stop_id,stop_sequence,arrival_time,departure_time\nT1,P1,1,08:00:00\n"
            },
            closures(good)
          ]

      assert {:error, failed_version, %Failure{} = failure} =
               Publication.run(run, token, StagedImport.stage(files), "import:phase-two")

      assert failure.phase == :phase_2
      assert failed_version.publication_status == "failed"
      refute Versions.published_gtfs_version_for_org?(organization.id, failed_version.id)

      # Phase one committed before the later phase failed, so the run is a
      # partial outcome rather than a clean failure.
      persisted_run = Repo.get!(Run, run.id)
      assert persisted_run.state == "partial"
      assert persisted_run.phase == "phase_2"

      # The closures really are durable, so recovery has to delete them before it
      # can delete the pathways they reference.
      assert closure_count(organization, failed_version.id) == 1

      assert Repo.aggregate(
               from(p in Gtfs.Pathway,
                 where:
                   p.organization_id == ^organization.id and
                     p.gtfs_version_id == ^failed_version.id
               ),
               :count
             ) == 1

      # Cleanup ownership: the manifest is reversed, so the closures precede the
      # pathways they reference and the composite foreign key never blocks.
      schemas = Import.cleanup_schemas()

      assert Enum.find_index(schemas, &(&1 == PathwayEvolution)) <
               Enum.find_index(schemas, &(&1 == Gtfs.Pathway))

      {:ok, claimed_cleanup, cleanup_version, cleanup_token} =
        ImportRuns.claim_cleanup(organization.id, run.id, %{
          id: actor.id,
          email: actor.email
        })

      assert cleanup_version.id == failed_version.id

      assert {:ok, nil} =
               Recovery.discard_claimed(claimed_cleanup, cleanup_version, cleanup_token)

      assert is_nil(Repo.get(GtfsVersion, failed_version.id))
      assert closure_count(organization, failed_version.id) == 0

      assert Repo.aggregate(
               from(p in Gtfs.Pathway,
                 where:
                   p.organization_id == ^organization.id and
                     p.gtfs_version_id == ^failed_version.id
               ),
               :count
             ) == 0

      # The audit receipt outlives the version row it was created for.
      assert Repo.get!(Run, run.id).state == "cleaned"

      # The other version keeps both its closure and its pathway.
      assert Repo.get!(PathwayEvolution, survivor_closure.id)
      assert Repo.get!(Gtfs.Pathway, survivor_pathway.id)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp feed do
    [
      %{filename: "levels.txt", content: @levels},
      %{filename: "stops.txt", content: @stops},
      %{filename: "pathways.txt", content: @pathways},
      %{filename: "calendar.txt", content: @calendar}
    ]
  end

  defp closures(body) do
    %{filename: "pathway_evolutions.txt", content: body}
  end

  defp claimed_run(organization, actor, name) do
    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(
        organization.id,
        %{id: actor.id, email: actor.email},
        %{name: name}
      )

    {:ok, claimed, _version, token} =
      ImportRuns.claim_import(organization.id, run.id, run.lease_token)

    {claimed, token}
  end

  defp closure_count(organization, version_id) do
    Repo.aggregate(
      from(e in PathwayEvolution,
        where: e.organization_id == ^organization.id and e.gtfs_version_id == ^version_id
      ),
      :count
    )
  end

  defp closure_tuples(organization, version) do
    Repo.all(
      from(e in PathwayEvolution,
        where: e.organization_id == ^organization.id and e.gtfs_version_id == ^version.id,
        select: {e.pathway_id, e.service_id, e.start_time, e.end_time},
        order_by: e.start_time
      )
    )
  end

  defp seed_pathway(organization, version, pathway_id) do
    level_fixture(organization.id, version.id, %{
      level_id: "SEED_L_#{pathway_id}",
      level_index: 0.0
    })

    from_stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "SEED_FROM_#{pathway_id}",
        location_type: 0
      })

    to_stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "SEED_TO_#{pathway_id}",
        location_type: 0
      })

    pathway_fixture(organization.id, version.id, from_stop.stop_id, to_stop.stop_id, %{
      pathway_id: pathway_id
    })
  end

  defp seed_closure(organization, version, pathway_id, service_id, start_time, end_time) do
    pathway = seed_pathway(organization, version, pathway_id)
    calendar_fixture(organization.id, version.id, %{service_id: service_id})

    closure =
      %PathwayEvolution{
        organization_id: organization.id,
        gtfs_version_id: version.id
      }
      |> PathwayEvolution.changeset(%{
        pathway_id: pathway_id,
        service_id: service_id,
        start_time: start_time,
        end_time: end_time
      })
      |> Repo.insert!()

    {closure, pathway}
  end

  # Service-day seconds to the `H:MM:SS` form the interchange file uses.
  defp service_time(seconds) do
    "#{div(seconds, 3600)}:#{pad(rem(seconds, 3600) |> div(60))}:#{pad(rem(seconds, 60))}"
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
